//
//  AppDelegate.swift
//  KelvinXDR
//

import Cocoa
import CoreAudio
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Absolute cap on the gamma boost: BrightIntosh's reference bonus gamma for Apple XDR
    /// panels is 0.59, and past 159% you are only clipping highlights.
    ///
    /// Deliberately not derived from the panel's reported headroom. This MacBook reports a
    /// *potential* 16.0, which is the EDR pipeline's theoretical ceiling rather than anything
    /// the backlight can hold — asking for it would just make macOS throttle. There is no
    /// public API for sustained full-screen nits, which is what actually bounds this, so a
    /// conservative constant beats a derived number that would be confidently wrong.
    private let boostCap: Float = 1.59

    /// The top of this machine's slider: 100% where the panel has no EDR headroom to spend,
    /// so a Mac without an XDR display gets a plain 0–100% brightness control instead of a
    /// range whose top third silently does nothing.
    ///
    /// `maximumPotential...` is the capability gate rather than the size: it reads 16.0 on the
    /// built-in XDR panel and exactly 1.0 on both external monitors, and stays put whether or
    /// not HDR is currently engaged. The `min` only matters for a hypothetical panel with less
    /// headroom than the cap.
    private var maxLevel: Float {
        guard let potential = builtInScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue,
              potential > 1.05 else { return 1.0 }
        return min(boostCap, Float(potential))
    }

    private var window: NSWindow!
    private var trigger: EDRTrigger!
    private var statusItem: NSStatusItem!

    private var hdrWait: Timer?
    private var trustPoll: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private var mediaKeys: MediaKeys!
    private let osd = OSD()
    private let systemOSD = SystemOSD()
    private let controller = DisplayController()
    private let spaces = SpaceLayoutManager()

    /// The click the volume keys make. Held rather than rebuilt per press — NSSound re-reads
    /// the file otherwise, and this one fires on every notch.
    private lazy var volumeClick: NSSound? = NSSound(
        contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
        byReference: true)

    private var displays: [ManagedDisplay] = []
    private var rows: [RowKey: (slider: NSSlider, label: NSTextField)] = [:]

    private enum Row: Int { case brightness, contrast, volume }

    // Empty by default: the 1x1 trigger cannot cover video, so there is nothing to step
    // aside from. Populate it to release the boost while a given app is frontmost.
    // A var, not a let: the settings window edits it and we re-read on change.
    private var excluded = Set(
        UserDefaults.standard.stringArray(forKey: "ExcludedBundleIDs") ?? []
    )

    private var shortcuts: Shortcuts!
    private var settingsController: SettingsWindowController?
    private var settings: SettingsWindowController {
        if let settingsController = settingsController { return settingsController }
        let controller = SettingsWindowController()
        controller.onChange = { [weak self] in self?.settingsChanged() }
        controller.isShortcutActive = { [weak self] in self?.shortcuts.isActive($0) ?? false }
        controller.values = { [weak self] in self?.editableValues() ?? [] }
        controller.spaceProfileCatalog = { [weak self] in
            self?.spaces.profileCatalog() ?? SpaceProfileCatalog(setups: [])
        }
        controller.captureProfile = { [weak self] name, done in
            self?.spaces.saveProfile(named: name, completion: done)
        }
        controller.applyProfile = { [weak self] name, setup in
            self?.spaces.restoreProfile(named: name, in: setup)
        }
        controller.selectProfile = { [weak self] name, setup, done in
            self?.spaces.selectProfile(name, in: setup, completion: done)
        }
        controller.renameProfileMutation = { [weak self] old, new, setup, done in
            self?.spaces.renameProfile(old, to: new, in: setup, completion: done)
        }
        controller.deleteProfileMutation = { [weak self] name, setup, done in
            self?.spaces.deleteProfile(name, in: setup, completion: done)
        }
        controller.layoutMutationsEnabled = { [weak self] in
            !(self?.spaces.isOperating ?? true)
        }
        settingsController = controller
        return controller
    }

    private func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    private var syncAll: Bool {
        get { flag("SyncAllDisplays", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "SyncAllDisplays") }
    }
    /// Fold contrast into the brightness control: the contrast row disappears and one slider
    /// drives both registers. Independent of syncAll, which is about *which displays* a change
    /// reaches rather than which registers it writes.
    private var mergeContrast: Bool {
        get { flag("MergeContrast", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "MergeContrast") }
    }
    /// Show a monitor's DDC volume row even when it is not the device playing audio. The keys
    /// stay out of it either way — see `ownsAudio`.
    private var showVolume: Bool {
        get { flag("ShowVolume", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "ShowVolume") }
    }
    private var smooth: Bool {
        get { flag("SmoothTransitions", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "SmoothTransitions"); controller.smooth = newValue }
    }
    /// Draw level changes in the stock macOS bezel instead of the compact HUD.
    ///
    /// Style only. We still own the value and still swallow the key either way — brightness
    /// has to stay intercepted for the range above 100% whatever the indicator looks like, so
    /// this is not a passthrough switch and cannot be made into one.
    private var useSystemHUD: Bool {
        get { flag("UseSystemHUD", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "UseSystemHUD") }
    }

    /// macOS's "Play feedback when volume is changed", from NSGlobalDomain.
    ///
    /// Unset means **off**: macOS only writes the key when the box is ticked. Reading absence
    /// as "on" made the click play on every single press — which is what the modifier is
    /// supposed to toggle, not the baseline. Checked against the live domain: the key does not
    /// exist here and this Mac is silent on a plain volume press.
    private var volumeFeedback: Bool {
        UserDefaults.standard.bool(forKey: "com.apple.sound.beep.feedback")
    }

    /// Gamma multiplier above SDR white: 1.0 is no boost, `maxLevel` the ceiling.
    ///
    /// Only this half of the slider is persisted. Below 100% the slider is the real backlight,
    /// which macOS already stores and which Control Center and the ambient light sensor move
    /// behind our back — so reading it live is the only value that stays true.
    private var xdrFactor: Float {
        get {
            guard UserDefaults.standard.object(forKey: "XDRGammaFactor") != nil else { return maxLevel }
            return min(max(UserDefaults.standard.float(forKey: "XDRGammaFactor"), 1.0), maxLevel)
        }
        // boostCap, not maxLevel: maxLevel reads 1.0 the moment the built-in screen is gone
        // (lid closing), and a Sync-All keypress landing in that window would persist 1.0 —
        // destroying the stored boost exactly the way migrateLegacyPrefs was fixed not to.
        // The getter clamps reads to live maxLevel, which is all the display-side cap needs.
        set { UserDefaults.standard.set(min(max(newValue, 1.0), boostCap), forKey: "XDRGammaFactor") }
    }

    /// The old scheme stored a 0.30...1.59 gamma factor in `Brightness` alongside an `Enabled`
    /// toggle. At or above 1.0 that number already means exactly what `XDRGammaFactor` means,
    /// so it carries straight over; below 1.0 it was gamma dimming, which the new scale has no
    /// state for. Deleting both inputs is what makes this safe to run unconditionally — the
    /// second run has nothing to find.
    private func migrateLegacyPrefs() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "Brightness") != nil
                || defaults.object(forKey: "Enabled") != nil else { return }

        if defaults.object(forKey: "XDRGammaFactor") == nil {
            let wasEnabled = defaults.object(forKey: "Enabled") as? Bool ?? true
            // boostCap, not maxLevel: migration reinterprets an old stored value, and must
            // not depend on which displays happen to be attached right now. Launching docked
            // in clamshell would otherwise see maxLevel == 1.0, clamp a stored 1.59 to 1.0,
            // and delete the inputs that could have recovered it.
            let old = defaults.object(forKey: "Brightness") != nil
                ? defaults.float(forKey: "Brightness") : boostCap
            defaults.set(wasEnabled ? min(max(old, 1.0), boostCap) : 1.0, forKey: "XDRGammaFactor")
        }
        defaults.removeObject(forKey: "Brightness")
        defaults.removeObject(forKey: "Enabled")
    }

    private var builtInDisplay: ManagedDisplay? { displays.first { $0.isBuiltIn } }

    /// How close to maximum the backlight has to be before the slider is considered to be at
    /// 100% and the XDR half takes over. Shared by the getter and `setLevel`: if only one of
    /// them knew about the dead band, a value inside it would report as a different number
    /// than was set.
    ///
    /// 0.995, deliberately narrower than any typeable percent: at 0.99 a typed "99" fell
    /// inside the band and silently became 100%. Every whole percent and every 1/64 detent
    /// now round-trips exactly; the band still absorbs sub-half-percent hardware jitter
    /// (DisplayServices reads back exact values on this panel — set 1.0, read 1.0).
    private let backlightMax: Double = 0.995

    /// The built-in panel's one control, 0...maxLevel. 1.0 is 100%: backlight at maximum, no
    /// boost. Below that it is the backlight; above it the backlight stays pinned and gamma
    /// spends the EDR headroom. Crossing 100% is what engages XDR.
    private var level: Float {
        guard let builtIn = builtInDisplay else { return xdrFactor }
        // Reads the cached value, which `refreshBuiltInBrightness` pulls back from the hardware
        // whenever something outside this app moves the backlight. Reading the hardware *here*
        // was worse: this getter runs in the same main-thread turn as `setLevel`, before the
        // queued write has reached the panel, so it returned the pre-press value and then
        // overwrote the freshly-set one with it.
        //
        // A backlight below maximum means something pulled it down, and a boost is meaningless
        // there — report the backlight and let applyState drop the gamma.
        return builtIn.brightness < backlightMax ? Float(builtIn.brightness) : xdrFactor
    }

    private func setLevel(_ value: Float) {
        guard let builtIn = builtInDisplay else { return }
        let target = min(max(value, 0), maxLevel)

        // `>= backlightMax`, not `>= 1.0`: a value inside the getter's dead band would
        // otherwise leave the backlight just short of maximum while the slider read 100%.
        if target >= Float(backlightMax) {
            xdrFactor = target
            // Gamma spends headroom above SDR white, so the panel has to already be at
            // maximum for any of it to show.
            if builtIn.brightness < 1.0 {
                controller.set(builtIn, brightness: 1.0, screen: builtInScreen, animated: false)
            }
        } else {
            xdrFactor = 1.0
            controller.set(builtIn, brightness: Double(target), screen: builtInScreen, animated: false)
        }
        applyState()
    }

    /// Display set as of the last configuration change, so we can tell a real hotplug from
    /// the many other things that post didChangeScreenParameters.
    private var knownDisplays: Set<CGDirectDisplayID> = []

    private var suspended = false
    /// The boost is live purely as a function of where the slider sits — there is no separate
    /// on/off state now that crossing 100% is the switch.
    private var boosting: Bool { level > 1.0 && !suspended }

    /// The built-in panel: the only display with EDR headroom, and the only one the XDR gamma
    /// boost applies to. Deliberately not NSScreen.main, which follows keyboard focus and so
    /// resolves to an external monitor whenever one has the active window.
    private var builtInScreen: NSScreen? {
        NSScreen.screens.first {
            guard let id = $0.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// Park the 1x1 EDR trigger in a corner. It has to stay on screen — the window server
    /// only honours the EDR request while the layer is actually composited — so it cannot be
    /// moved off-display, only somewhere you won't look.
    private func positionTrigger(on screen: NSScreen) {
        let f = screen.frame
        let origin: CGPoint
        switch UserDefaults.standard.string(forKey: "TriggerCorner") ?? "topRight" {
        case "topLeft":     origin = CGPoint(x: f.minX, y: f.maxY - 1)
        case "bottomLeft":  origin = CGPoint(x: f.minX, y: f.minY)
        case "bottomRight": origin = CGPoint(x: f.maxX - 1, y: f.minY)
        default:            origin = CGPoint(x: f.maxX - 1, y: f.maxY - 1)   // topRight
        }
        window.setFrameOrigin(origin)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        migrateLegacyPrefs()

        // Observers first, before the screen check below. Launching with no screens yet — a
        // headless boot, or launch-at-login racing display enumeration — otherwise leaves a
        // process with no observers and no signal handlers, which can never recover.
        installTerminationHandlers()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reapply),
            name: NSWorkspace.didWakeNotification, object: nil)
        // Waking the displays alone (our own Turn Display Off hotkey does exactly this) never
        // posts didWake, so the boost would sit unapplied until something else nudged it.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reapply),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // No screen yet: everything below needs one, so defer it. `displaysChanged` calls this
        // again once a display appears. Registering the observers above but leaving these nil
        // would be worse than the old behaviour, not better — the notifications would fire
        // into a half-built delegate and dereference nil.
        guard let screen = builtInScreen ?? NSScreen.main else { return }
        finishLaunch(on: screen)
    }

    /// True once the deferred setup has run. Everything that a notification can reach has to
    /// check this, because a notification can arrive before a screen ever does.
    private var isReady: Bool { window != nil }

    private func finishLaunch(on screen: NSScreen) {
        guard window == nil else { return }
        controller.smooth = smooth

        // A 1x1 window in the top-left corner. Size is the entire point: it cannot overlap
        // video, so it cannot show a white box over protected HDR playback.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        // Top-right corner by default. It reads as a dead pixel anywhere you can see it, and on
        // this panel the extreme corner falls inside the display's rounded-corner mask, so it
        // is hidden outright — and up here it also sits in the menu bar strip rather than over
        // document content. Changeable in Settings, or:
        //   defaults write com.kelvin.KelvinXDR TriggerCorner -string bottomRight
        positionTrigger(on: screen)

        trigger = EDRTrigger()
        window.contentView = trigger

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // The initial read-only capability inventory can complete immediately and its
        // onChange callback rebuilds the menu, so register now and start after all menu
        // dependencies below are initialized.
        spaces.onChange = { [weak self] in
            self?.rebuildMenu()
            if self?.settingsController?.window?.isVisible == true {
                self?.settingsController?.reload()
            }
        }

        mediaKeys = MediaKeys { [weak self] key, screen, modifiers in
            self?.handleMediaKey(key, on: screen, modifiers: modifiers) ?? false
        }
        shortcuts = Shortcuts { [weak self] action in self?.perform(action) }
        shortcuts.reload()

        mediaKeys.start()
        // Written so the state is checkable from outside without rebuilding the app.
        UserDefaults.standard.set(mediaKeys.isRunning, forKey: "MediaKeysActive")
        pollForTrust()

        // Seed the built-in before the first applyState. The full scan below is async and can
        // take seconds on a busy I2C bus; with the list empty, `level` falls through to the
        // persisted boost factor and the panel would run gamma-boosted over whatever the real
        // backlight is — crushed whites at 40% backlight until the scan lands. The native
        // brightness read is local and immediate, so the first applyState can see the truth.
        if let builtIn = builtInScreen, let id = builtIn.displayID {
            displays = [ManagedDisplay(id: id, name: builtIn.localizedName, isBuiltIn: true,
                                       hardware: .appleNative, softwareFraction: 0,
                                       brightness: Double(AppleBrightness.get(id) ?? 1))]
        }

        suspended = excluded.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        rebuildMenu()
        applyState()
        refreshDisplays()
        spaces.start()

        // One breadcrumb per launch, so field debugging can first prove the app's logs
        // reach the unified log at all — during the HUD-zombie hunt an empty `log show`
        // could not distinguish "nothing happened" from "logs not captured".
        NSLog("KelvinXDR: launched, %d display(s)", NSScreen.screens.count)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        controller.clearAll()
    }

    /// `killall` sends SIGTERM, which kills a Cocoa app before applicationWillTerminate runs
    /// and would leave gamma tables scaled until logout.
    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            // Not .main: an open NSMenu runs a modal tracking loop that starves the main
            // queue, so a kill while the menu is open would skip the restore entirely.
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                // Not restoreAll: this runs on a global queue while the main thread may be
                // part-way through an apply. prepareForTermination takes the same lock and
                // latches a flag, so an apply already in flight completes first and any that
                // arrives afterwards is refused — the restore is always the last write.
                GammaBoost.prepareForTermination()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Displays

    /// Bumped per refresh so a superseded scan cannot commit. Scans run concurrently and a
    /// scan stalled on a just-unplugged DDC service (its reads retry for seconds) reliably
    /// finishes *after* a newer, correct scan — last-writer-wins would resurrect the ghost
    /// display and regress knownDisplays, triggering a spurious gamma invalidate.
    private var refreshGeneration = 0

    private func refreshDisplays() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let screens: [(CGDirectDisplayID, String)] = NSScreen.screens.compactMap {
            guard let id = $0.displayID else { return nil }
            return (id, $0.localizedName)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let services = DDC.services()
            var found: [ManagedDisplay] = []

            for (id, name) in screens {
                let isBuiltIn = CGDisplayIsBuiltin(id) != 0
                let service = isBuiltIn ? nil : services[Int64(CGDisplaySerialNumber(id))]

                if let service = service {
                    let b = DDC.read(service, DDC.brightness)
                    let c = DDC.read(service, DDC.contrast)
                    let v = DDC.read(service, DDC.volume)
                    let m = DDC.read(service, DDC.mute)
                    let bMax = max(b?.max ?? 100, 1)
                    found.append(ManagedDisplay(
                        id: id, name: name, isBuiltIn: false, hardware: .ddc(service),
                        ddcBrightnessMax: bMax, ddcVolumeMax: max(v?.max ?? 100, 1),
                        ddcContrastMax: max(c?.max ?? 100, 1), hasAudio: v != nil,
                        brightness: Double(b?.current ?? bMax) / Double(bMax),
                        volume: Double(v?.current ?? 0) / Double(max(v?.max ?? 100, 1)),
                        contrast: Double(c?.current ?? 70) / Double(max(c?.max ?? 100, 1)),
                        muted: m?.current == 1))
                } else if isBuiltIn || AppleBrightness.supported(id) {
                    // Backlight only — the built-in's gamma table belongs to the XDR boost,
                    // so combined dimming is off here to keep the two from fighting.
                    found.append(ManagedDisplay(
                        id: id, name: name, isBuiltIn: isBuiltIn, hardware: .appleNative,
                        softwareFraction: 0,
                        brightness: Double(AppleBrightness.get(id) ?? 1)))
                } else {
                    // No DDC, no native protocol: AirPlay, Sidecar, DisplayLink, virtual.
                    found.append(ManagedDisplay(
                        id: id, name: name, isBuiltIn: false, hardware: .none,
                        software: .shade, softwareFraction: 1, brightness: 1))
                }
            }

            DispatchQueue.main.async {
                guard generation == self.refreshGeneration else { return }
                self.knownDisplays = Set(found.map { $0.id })
                self.displays = found
                self.rebuildMenu()
                self.applyState()
            }
        }
    }

    @objc private func displaysChanged() {
        // A display arriving is what completes a launch that had none. Do this before
        // anything else here touches the deferred objects.
        if !isReady, let screen = builtInScreen ?? NSScreen.main {
            finishLaunch(on: screen)
            return
        }
        // Before the gamma comparison below and deliberately unconditional: this feature
        // compares display UUIDs rather than the CGDirectDisplayIDs `knownDisplays` holds, and
        // it must see the notifications this one decides to ignore.
        spaces.screenParametersChanged()

        let current = Set(NSScreen.screens.compactMap { $0.displayID })
        // This notification also fires for brightness and colour-profile changes, not only
        // hotplug. Only a genuine change of display set can stale a captured gamma baseline,
        // and invalidating restores the boost before forgetting it — so doing that on every
        // notification made the screen visibly drop out of XDR and pop back on each nudge.
        guard current != knownDisplays else { reapply(); return }
        knownDisplays = current
        GammaBoost.invalidate()
        refreshDisplays()
        reapply()
    }

    private func display(for id: CGDirectDisplayID) -> ManagedDisplay? {
        displays.first { $0.id == id }
    }

    // MARK: - Media keys

    /// A monitor answering DDC's volume register is not the same as sound coming out of it.
    /// Unless the display is the current audio output there is nothing for us to usefully do,
    /// and taking the key would only stop macOS adjusting the volume you can actually hear.
    ///
    /// ponytail: evaluated per keypress rather than cached on ManagedDisplay, so switching
    /// output device takes effect immediately. The menu row is gated at rebuild time, so it
    /// can lag a device switch until the next display change — add a CoreAudio property
    /// listener if that becomes annoying.
    private func ownsAudio(_ display: ManagedDisplay) -> Bool {
        display.hasAudio && AudioOutput.matches(displayName: display.name)
    }

    /// Contrast as it stood before the merge took it over, keyed by EDID serial.
    ///
    /// Persisted, and that is the whole point: capturing it fresh each launch would read a
    /// value the merge had already dimmed and adopt it as the new ceiling, ratcheting contrast
    /// down a little further every time the app started.
    private func contrastCeiling(_ display: ManagedDisplay) -> Double? {
        let store = UserDefaults.standard.dictionary(forKey: "MergedContrastCeiling") as? [String: Double]
        return store?[String(CGDisplaySerialNumber(display.id))]
    }

    private func setContrastCeiling(_ display: ManagedDisplay, _ value: Double?) {
        var store = UserDefaults.standard.dictionary(forKey: "MergedContrastCeiling") as? [String: Double] ?? [:]
        store[String(CGDisplaySerialNumber(display.id))] = value
        UserDefaults.standard.set(store, forKey: "MergedContrastCeiling")
    }

    /// One place that writes brightness, so `mergeContrast` applies to the slider and the
    /// media keys alike rather than only whichever path remembered to check it.
    private func applyBrightness(_ display: ManagedDisplay, _ value: Double, animated: Bool? = nil) {
        controller.set(display, brightness: value, screen: screen(for: display.id), animated: animated)
        guard mergeContrast, let service = display.ddcService else { return }

        // Contrast follows brightness, but only from the calibrated setting down to half of
        // it. A low backlight is simply dim; a low contrast is flat and grey, so mapping them
        // 1:1 wrecks the bottom of the range. Anchoring the top at the pre-merge value also
        // stops the merge pushing contrast up into highlight clipping.
        let ceiling = contrastCeiling(display) ?? {
            setContrastCeiling(display, display.contrast)
            return display.contrast
        }()
        let contrast = ceiling * (0.5 + 0.5 * min(max(value, 0), 1))

        display.contrast = contrast
        DDC.writer.write(service, display: display.id, command: DDC.contrast,
                         value: UInt16((contrast * Double(display.ddcContrastMax)).rounded()))
    }

    private func handleMediaKey(_ key: MediaKeys.Key, on screen: NSScreen,
                                modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let id = screen.displayID, let target = display(for: id) else { return false }
        let adjustment = MediaKeys.adjustment(for: modifiers)

        // ⌥ alone is a shortcut into System Settings rather than an adjustment, and we have to
        // perform it ourselves: the key is swallowed, so macOS never gets its turn. Until this
        // existed the modifier was ignored and the value stepped instead.
        if adjustment == .openSettings {
            switch key {
            case .brightnessUp, .brightnessDown: openSettingsPane("com.apple.Displays-Settings.extension")
            case .volumeUp, .volumeDown, .mute:  openSettingsPane("com.apple.Sound-Settings.extension")
            }
            return true
        }
        let fine = adjustment == .fine

        switch key {
        case .brightnessUp, .brightnessDown:
            let up = key == .brightnessUp
            let targets = syncAll ? displays.filter { $0.hasHardware || $0.softwareFraction > 0 } : [target]
            // Remember what we asked for. Re-reading `level` afterwards would report the value
            // from before the press, because the backlight write is still queued.
            var builtInTarget: Float?
            for display in targets {
                if display.isBuiltIn {
                    // The unified scale runs to 159%, so the keys keep climbing past the top
                    // of the backlight into the XDR range instead of stopping at 100%.
                    // setLevel pins the backlight and re-runs applyState on the way through.
                    let next = Detent.next(from: level, up: up, ceiling: maxLevel, fine: fine)
                    setLevel(next)
                    builtInTarget = next
                    sync(display, .brightness, Double(next))
                } else {
                    applyBrightness(display, Double(Detent.next(from: Float(display.brightness), up: up, ceiling: 1, fine: fine)))
                    sync(display, .brightness, display.brightness)
                }
            }
            if target.isBuiltIn, let shown = builtInTarget {
                showBuiltInOSD(on: screen, level: shown)
            } else {
                // weak target: hotplug rescans replace the whole display list, and the HUD
                // stays interactive after the keypress — a strongly-held stale display would
                // scrub an orphaned model through a dead service.
                showOSD(on: screen, symbol: "sun.max.fill", image: .brightness,
                        value: target.brightness,
                        onScrub: { [weak self, weak target] fraction in
                            guard let target = target else { return }
                            self?.scrub(target, to: fraction)
                        })
            }
            return true

        case .volumeUp, .volumeDown:
            let up = key == .volumeUp

            // The display genuinely plays the sound: its own register is the one to move.
            if let service = target.ddcService, ownsAudio(target) {
                target.volume = Double(Detent.next(from: Float(target.volume), up: up, ceiling: 1, fine: fine))
                DDC.writer.write(service, display: target.id, command: DDC.volume,
                                 value: UInt16((target.volume * Double(target.ddcVolumeMax)).rounded()))
                if target.muted, target.volume > 0 {
                    target.muted = false
                    DDC.writer.write(service, display: target.id, command: DDC.mute, value: 2)
                }
                sync(target, .volume, target.volume)
                click(adjustment)
                showVolumeOSD(on: screen, value: target.volume, muted: target.volume == 0,
                              onScrub: { [weak self, weak target] fraction in
                                  guard let target = target else { return }
                                  self?.scrubVolume(target, to: fraction)
                              })
                return true
            }

            // It does not — so move the level the user can actually hear. Taking the key and
            // writing a register nobody is listening to is exactly the bug that had volume
            // interception removed the first time.
            guard let device = AudioOutput.defaultDevice,
                  let current = AudioOutput.volume(of: device) else { return false }
            let next = Detent.next(from: current, up: up, ceiling: 1, fine: fine)
            // A readable-but-fixed master level (optical out, some HDMI) passes the guard
            // above and then refuses the write. Nothing has been written yet, so declining
            // the key is still clean — macOS drives the device its own way.
            guard AudioOutput.setVolume(next, on: device) else { return false }
            // Nudging off zero unmutes, which is what the hardware keys do.
            if next > 0, AudioOutput.isMuted(device) == true { AudioOutput.setMuted(false, on: device) }
            // And zero mutes. Scalar 0 is not silence everywhere: DisplayPort and HDMI audio
            // devices keep emitting at their minimum level with the scalar on the floor —
            // observed as "every indicator says muted, the video is still audible". Control
            // Center's slider silences its far end by setting the mute flag; match it.
            if next == 0, AudioOutput.isMuted(device) == false { AudioOutput.setMuted(true, on: device) }
            click(adjustment)
            showVolumeOSD(on: screen, value: Double(next), muted: next == 0,
                          onScrub: { [weak self] fraction in self?.scrubVolume(device, to: fraction) })
            return true

        case .mute:
            if let service = target.ddcService, ownsAudio(target) {
                target.muted.toggle()
                DDC.writer.write(service, display: target.id, command: DDC.mute,
                                 value: target.muted ? 1 : 2)
                showVolumeOSD(on: screen, value: target.muted ? 0 : target.volume,
                              muted: target.muted, onScrub: nil)
                return true
            }
            // No mute control on the device (optical out, some HDMI) — hand the key back to
            // macOS rather than faking it by parking the level at zero.
            guard let device = AudioOutput.defaultDevice,
                  let muted = AudioOutput.isMuted(device) else { return false }
            AudioOutput.setMuted(!muted, on: device)
            showVolumeOSD(on: screen,
                          value: muted ? Double(AudioOutput.volume(of: device) ?? 0) : 0,
                          muted: !muted, onScrub: nil)
            return true
        }
    }

    /// ⌥ + a media key opens the matching System Settings pane, matching what macOS would have
    /// done with the key we swallowed.
    private func openSettingsPane(_ identifier: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The volume feedback click.
    ///
    /// Shift does not simply "play a sound" — it *inverts* the feedback setting for that press,
    /// so it silences the click when the click is on and plays it when it is off.
    private func click(_ adjustment: MediaKeys.Adjustment) {
        let wanted = adjustment == .coarseInvertedFeedback ? !volumeFeedback : volumeFeedback
        guard wanted, let sound = volumeClick else { return }
        // Restart rather than overlap: holding the key down should tick, not smear.
        sound.stop()
        sound.play()
    }

    // MARK: - HUD

    /// One place that decides which indicator renders, so every call site gets the toggle free.
    ///
    /// - chiclets: overrides the default 16-notch strip on the system bezel. Only the built-in
    ///   panel needs it, because its scale runs past 100%.
    private func showOSD(on screen: NSScreen, symbol: String, image: SystemOSD.Image,
                         value: Double?, mark: Double? = nil,
                         chiclets: (filled: UInt32, total: UInt32)? = nil,
                         onScrub: ((Double) -> Void)? = nil) {
        guard useSystemHUD, let id = screen.displayID else {
            osd.show(on: screen, symbol: symbol, value: value, mark: mark, onScrub: onScrub)
            return
        }
        guard let value = value else {
            systemOSD.show(on: id, image: image)
            return
        }
        let strip = chiclets ?? (SystemOSD.chiclets(value), 16)
        systemOSD.show(on: id, image: image, filled: strip.filled, total: strip.total)
    }

    /// The built-in panel's indicator: one 0...159% track with the 100% boundary marked, and a
    /// different glyph past it, so crossing into XDR is unmistakable without a readout.
    private func showBuiltInOSD(on screen: NSScreen, level shown: Float) {
        showOSD(on: screen,
                symbol: shown > 1.0 ? "sparkles" : "sun.max.fill",
                image: .brightness,
                value: Double(shown / maxLevel),
                mark: Double(1.0 / maxLevel),
                // The strip keeps Apple's 1/16 notch and simply runs longer, so the chiclets
                // past the 16th *are* the XDR range rather than a rescaled 0...100%.
                chiclets: (UInt32(max(0, Detent.notch(shown).rounded())),
                           UInt32(max(1, Detent.notch(maxLevel).rounded()))),
                onScrub: { [weak self] fraction in self?.scrubBuiltIn(to: fraction) })
    }

    private func showVolumeOSD(on screen: NSScreen, value: Double, muted: Bool,
                               onScrub: ((Double) -> Void)?) {
        showOSD(on: screen,
                symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                image: muted ? .speakerMuted : .speaker,
                value: value, onScrub: onScrub)
    }

    // MARK: - HUD dragging
    //
    // The fraction is the position along the track, which for the built-in panel is not the
    // brightness — the track spans 0...maxLevel. Each of these maps back, applies, and pushes
    // the result into both the HUD and the menu row.

    private func scrubBuiltIn(to fraction: Double) {
        let value = min(max(Float(fraction) * maxLevel, 0), maxLevel)
        setLevel(value)
        if let display = builtInDisplay { sync(display, .brightness, Double(value)) }
        osd.update(value: Double(value / maxLevel))
    }

    private func scrub(_ display: ManagedDisplay, to fraction: Double) {
        let value = min(max(fraction, 0), 1)
        applyBrightness(display, value, animated: false)
        sync(display, .brightness, value)
        osd.update(value: value)
    }

    private func scrubVolume(_ display: ManagedDisplay, to fraction: Double) {
        guard let service = display.ddcService else { return }
        display.volume = min(max(fraction, 0), 1)
        DDC.writer.write(service, display: display.id, command: DDC.volume,
                         value: UInt16((display.volume * Double(display.ddcVolumeMax)).rounded()))
        // Raising the level unmutes, exactly as the volume-up key does — otherwise dragging
        // the track up from zero moves the fill in silence.
        if display.muted, display.volume > 0 {
            display.muted = false
            DDC.writer.write(service, display: display.id, command: DDC.mute, value: 2)
        }
        sync(display, .volume, display.volume)
        osd.update(value: display.volume)
    }

    private func scrubVolume(_ device: AudioDeviceID, to fraction: Double) {
        let value = min(max(fraction, 0), 1)
        AudioOutput.setVolume(Float(value), on: device)
        if value > 0, AudioOutput.isMuted(device) == true { AudioOutput.setMuted(false, on: device) }
        // Zero mutes, matching the key path — scalar 0 alone is audible on DP/HDMI audio.
        if value == 0, AudioOutput.isMuted(device) == false { AudioOutput.setMuted(true, on: device) }
        osd.update(value: value)
    }

    /// Keep the open menu's slider and its percentage in step with a change made elsewhere.
    private func sync(_ display: ManagedDisplay, _ row: Row, _ value: Double) {
        guard let widgets = rows[rowKey(display, row)] else { return }
        widgets.slider.doubleValue = value
        widgets.label.stringValue = percent(value)
    }

    private func rowKey(_ display: ManagedDisplay, _ row: Row) -> RowKey {
        RowKey(id: display.id, row: row)
    }

    private struct RowKey: Hashable { let id: CGDirectDisplayID; let row: Row }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: - State

    private func applyState() {
        let needsEDR = boosting

        if needsEDR {
            // Reposition every time. If the display it was parked on changed size or went
            // away, the window is now off-screen: not composited, so the EDR request lapses
            // and the headroom collapses while the table is still scaled, which reads as
            // blown-out whites.
            if let screen = builtInScreen { positionTrigger(on: screen) }
            trigger.setEDREnabled(true)
            // Re-asserted per show: a window ordered front while a fullscreen Space is active
            // can be adopted by it (see OSD.show). For this window that would mean the EDR
            // request only holds inside that Space — the boost silently lapsing everywhere
            // else, with the gamma table still scaled.
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.orderFrontRegardless()
            waitForHDRThenApplyGamma()
        } else {
            hdrWait?.invalidate()
            hdrWait = nil
            trigger.setEDREnabled(false)
            window.orderOut(nil)
            // Below 100% the backlight does the dimming, so there is never a sub-1.0 gamma
            // table to hold on the built-in — anything left over gets handed back.
            if let id = builtInScreen?.displayID { GammaBoost.restore(id) }
        }

        // Circled sun, not a bare one: a plain sun.max was indistinguishable from
        // MonitorControl's icon sitting a few slots away in the same menu bar.
        // Filled means the boost is actually live — above 100% and not suspended.
        statusItem.button?.image = NSImage(
            systemSymbolName: needsEDR ? "sun.max.circle.fill" : "sun.max.circle",
            accessibilityDescription: "KelvinXDR brightness")
    }

    /// Gamma above 1.0 only has headroom to move into once the display is in EDR mode, and
    /// that takes a moment after the trigger window appears.
    private func waitForHDRThenApplyGamma() {
        hdrWait?.invalidate()
        // Already have headroom: apply now rather than up to 100ms later, so dragging the
        // slider tracks the pointer instead of lagging behind it.
        if let id = builtInScreen?.displayID, builtInScreen?.hdrEngaged == true {
            GammaBoost.apply(factor: xdrFactor, to: id)
            hdrWait = nil
            return
        }
        let deadline = Date().addingTimeInterval(5)

        // Into .common, not the default mode: the status menu's tracking loop does not run
        // default-mode timers, and every fresh crossing into the boost range rides this timer
        // (EDR is always disengaged at that moment) — scheduled normally, a quick in-menu
        // drag to 159% showed no boost for as long as the menu stayed open.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let engaged = self.builtInScreen?.hdrEngaged ?? false
            guard engaged || Date() > deadline else { return }

            timer.invalidate()
            self.hdrWait = nil
            if engaged, let id = self.builtInScreen?.displayID {
                GammaBoost.apply(factor: self.xdrFactor, to: id)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hdrWait = timer
    }

    @objc private func reapply() {
        guard isReady else { return }
        refreshBuiltInBrightness()
        applyState()
    }

    /// Pull the built-in's backlight back from the hardware into our model.
    ///
    /// Auto-brightness is on by default, and Control Center and the ambient sensor move the
    /// backlight without telling us. Every one of those posts didChangeScreenParameters, which
    /// is what lands here, so this is the moment the cache can go stale and the moment to fix
    /// it. Deliberately *not* done inside the `level` getter: a read there would run before
    /// our own queued write had reached the hardware, so it would report the pre-press value
    /// and overwrite the fresh one with it.
    private func refreshBuiltInBrightness() {
        guard let builtIn = builtInDisplay, let live = AppleBrightness.get(builtIn.id) else { return }
        builtIn.brightness = Double(live)
    }

    /// The display the pointer is on, matching how the media keys pick their target.
    private var cursorScreen: NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .displayOff:
            Shortcuts.sleepDisplays()

        case .brightnessUp, .brightnessDown:
            // Straight through the media-key path so a shortcut and the F1/F2 keys cannot
            // drift apart in behaviour.
            guard let screen = cursorScreen else { return }
            _ = handleMediaKey(action == .brightnessUp ? .brightnessUp : .brightnessDown,
                               on: screen, modifiers: [])

        case .maximumBrightness:
            guard let screen = cursorScreen, let id = screen.displayID,
                  let target = display(for: id) else { return }
            if target.isBuiltIn {
                let shown = maxLevel
                setLevel(shown)
                sync(target, .brightness, Double(shown))
                showBuiltInOSD(on: screen, level: shown)
            } else {
                applyBrightness(target, 1.0, animated: false)
                sync(target, .brightness, target.brightness)
                showOSD(on: screen, symbol: "sun.max.fill", image: .brightness,
                        value: target.brightness,
                        onScrub: { [weak self, weak target] fraction in
                            guard let target = target else { return }
                            self?.scrub(target, to: fraction)
                        })
            }
        }
    }

    /// The settings window edited something. Re-read what is cached rather than working out
    /// which control moved.
    private func settingsChanged() {
        excluded = Set(UserDefaults.standard.stringArray(forKey: "ExcludedBundleIDs") ?? [])
        suspended = excluded.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        if let screen = builtInScreen { positionTrigger(on: screen) }
        shortcuts.reload()
        applyState()
        rebuildMenu()
    }

    @objc private func openSettings() { settings.show() }

    @objc private func frontmostAppChanged() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let shouldSuspend = excluded.contains(frontmost)
        guard shouldSuspend != suspended, isReady else { return }
        suspended = shouldSuspend
        applyState()
    }

    // MARK: - Menu

    /// The rows are snapshots, and outside movers change the hardware while the menu is
    /// closed: auto-brightness and Control Center move the backlight, the monitor's own
    /// buttons move the DDC registers. The stale knob position is what a click would write,
    /// so refresh both as the menu opens — the built-in synchronously (the read is local),
    /// the DDC registers asynchronously off the I2C bus.
    func menuWillOpen(_ menu: NSMenu) {
        refreshBuiltInBrightness()
        if let builtIn = builtInDisplay { sync(builtIn, .brightness, Double(level)) }
        refreshDDCRows()
    }

    /// Land each DDC display's real register values into the already-open menu.
    ///
    /// The reads run off-thread (~70ms per register on the bus), and the results come back
    /// through a common-modes run-loop block, not `main.async` — the menu's tracking loop
    /// starves the plain main queue, so a queued block would only run after the menu closed.
    /// A result is dropped if the user touched that display while the read was on the bus:
    /// their value is newer than the hardware snapshot.
    private func refreshDDCRows() {
        for display in displays {
            guard display.ddcService != nil else { continue }
            let snapshot = (display.brightness, display.contrast, display.volume)
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak display] in
                guard let display = display, let service = display.ddcService else { return }
                let b = DDC.read(service, DDC.brightness)
                let c = DDC.read(service, DDC.contrast)
                let v = DDC.read(service, DDC.volume)
                let m = DDC.read(service, DDC.mute)
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    guard let self = self,
                          (display.brightness, display.contrast, display.volume) == snapshot
                    else { return }
                    if let b = b {
                        // Inverse of split(): the register only holds the hardware segment of
                        // the combined 0...1 scale. At register zero the software share is
                        // unknowable from the monitor, so the cache stands.
                        let hw = Double(b.current) / Double(display.ddcBrightnessMax)
                        if hw > 0 {
                            let f = display.softwareFraction
                            display.brightness = f + hw * (1 - f)
                            self.sync(display, .brightness, display.brightness)
                        }
                    }
                    if let c = c {
                        display.contrast = Double(c.current) / Double(display.ddcContrastMax)
                        self.sync(display, .contrast, display.contrast)
                    }
                    if let v = v {
                        display.volume = Double(v.current) / Double(display.ddcVolumeMax)
                        self.sync(display, .volume, display.volume)
                    }
                    if let m = m { display.muted = m.current == 1 }
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu(title: "KelvinXDR")
        menu.delegate = self
        rows.removeAll()

        for display in displays {
            let header = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if display.isBuiltIn {
                // One control spanning 0...159%. Below 100% it drives the backlight, above it
                // the XDR gamma boost — crossing 100% is the switch, so there is no toggle.
                menu.addItem(row(display, .brightness, "sun.max.fill",
                                 value: Double(level), max: Double(maxLevel),
                                 text: percent(Double(level)),
                                 action: #selector(builtInLevelChanged)))
            } else if display.hasHardware || display.softwareFraction > 0 {
                menu.addItem(row(display, .brightness, "sun.max.fill",
                                 value: display.brightness, text: percent(display.brightness),
                                 action: #selector(brightnessChanged)))
            }
            // Merged into the brightness row above, so it has no separate control.
            if display.ddcService != nil, !mergeContrast {
                menu.addItem(row(display, .contrast, "circle.lefthalf.filled",
                                 value: display.contrast, text: percent(display.contrast),
                                 action: #selector(contrastChanged)))
            }
            if display.hasAudio, showVolume || ownsAudio(display) {
                menu.addItem(row(display, .volume, "speaker.wave.2.fill",
                                 value: display.volume, text: percent(display.volume),
                                 action: #selector(volumeChanged)))
            }
            menu.addItem(.separator())
        }

        if displays.isEmpty {
            let item = NSMenuItem(title: "Detecting displays…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        menu.addItem(check("Sync All Displays", syncAll, #selector(toggleSync)))
        menu.addItem(check("Sync Contrast + Brightness", mergeContrast, #selector(toggleMergeContrast)))
        menu.addItem(check("Show Volume", showVolume, #selector(toggleShowVolume)))
        menu.addItem(check("Smooth Transitions", smooth, #selector(toggleSmooth)))
        menu.addItem(check("Use System HUD", useSystemHUD, #selector(toggleSystemHUD)))
        menu.addItem(spacesMenu())

        if !mediaKeys.isRunning {
            let item = NSMenuItem(title: "Enable Media Keys…", action: #selector(enableMediaKeys), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(check("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin)))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Its own submenu: these actions have nothing to do with brightness, and the main
    /// menu is already one row per display per control.
    private func spacesMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Space Layout Protection", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Space Layout Protection")
        // Restore is greyed out until something has been saved, and AppKit only leaves an
        // explicit isEnabled alone once it has been told to stop enabling items itself.
        submenu.autoenablesItems = false

        if let status = spaces.capabilityStatusText {
            let note = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
        }
        let automatic = check("Automatically Restore Layouts", spaces.automaticRestoreEnabled,
                              #selector(toggleAutomaticSpaceRestore))
        // Always allow turning it off immediately, including while an operation is active.
        automatic.isEnabled = spaces.automaticRestoreEnabled || spaces.capabilities.canRestore
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        let save = NSMenuItem(title: "Save Current Normal-Space Layout",
                              action: #selector(saveSpaceLayout), keyEquivalent: "")
        save.target = self
        save.isEnabled = spaces.canSave
        submenu.addItem(save)

        let restore = NSMenuItem(title: "Restore Normal-Space Layout",
                                 action: #selector(restoreSpaceLayout), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = spaces.hasSavedLayout && spaces.canRestore
        submenu.addItem(restore)

        let conversion = NSMenuItem(title: "Convert Fullscreen Apps to Dedicated Desktops…",
                                    action: #selector(convertFullscreenApps), keyEquivalent: "")
        conversion.target = self
        conversion.isEnabled = spaces.canConvert
        submenu.addItem(conversion)
        item.submenu = submenu
        return item
    }

    private func check(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func row(_ display: ManagedDisplay, _ kind: Row, _ symbol: String,
                     value: Double, max maxValue: Double = 1, text: String,
                     action: Selector) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 268, height: 28))

        let icon = NSImageView(frame: NSRect(x: 18, y: 6, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        container.addSubview(icon)

        let slider = NSSlider(frame: NSRect(x: 44, y: 4, width: 170, height: 20))
        slider.minValue = 0
        slider.maxValue = maxValue
        slider.doubleValue = value
        slider.isContinuous = true
        slider.tag = Int(display.id)
        slider.target = self
        slider.action = action
        container.addSubview(slider)

        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 220, y: 5, width: 42, height: 16)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        container.addSubview(label)

        rows[RowKey(id: display.id, row: kind)] = (slider, label)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    // MARK: - Actions

    @objc private func toggleAutomaticSpaceRestore() {
        spaces.automaticRestoreEnabled.toggle()
        rebuildMenu()
    }
    @objc private func saveSpaceLayout() { spaces.saveCurrentLayout() }
    @objc private func restoreSpaceLayout() { spaces.restoreCurrentLayout() }
    @objc private func convertFullscreenApps() { spaces.convertFullscreenApps() }

    @objc private func toggleSync() { syncAll.toggle(); rebuildMenu() }
    @objc private func toggleSmooth() { smooth.toggle(); rebuildMenu() }
    @objc private func toggleShowVolume() { showVolume.toggle(); rebuildMenu() }
    @objc private func toggleSystemHUD() { useSystemHUD.toggle(); rebuildMenu() }

    @objc private func toggleMergeContrast() {
        mergeContrast.toggle()

        for display in displays where display.ddcService != nil {
            if mergeContrast {
                // Remember the calibration before dimming starts overwriting it, then pull
                // contrast onto brightness so the two are not left silently disagreeing until
                // the next time something moves.
                setContrastCeiling(display, display.contrast)
                applyBrightness(display, display.brightness, animated: false)
            } else if let restored = contrastCeiling(display), let service = display.ddcService {
                // Hand the panel back exactly where it was, not wherever dimming left it.
                display.contrast = restored
                DDC.writer.write(service, display: display.id, command: DDC.contrast,
                                 value: UInt16((restored * Double(display.ddcContrastMax)).rounded()))
                setContrastCeiling(display, nil)
            }
        }
        rebuildMenu()
    }

    /// The one path that writes a row's value, so a dragged slider and a typed percentage
    /// cannot drift apart in what they actually do.
    private func applyRow(_ display: ManagedDisplay, _ kind: Row, _ value: Double) {
        switch kind {
        case .brightness where display.isBuiltIn:
            setLevel(Float(value))
            sync(display, .brightness, value)

        case .brightness:
            let targets = syncAll ? displays.filter { $0.hasHardware || $0.softwareFraction > 0 } : [display]
            for target in targets {
                // The built-in lives on the 0...1.59 level model. Routing it through the raw
                // external path moved the backlight under a still-scaled gamma table and left
                // xdrFactor stale — dragging an external back to 100% then silently re-engaged
                // a boost the built-in's own slider would have cleared. setLevel keeps model,
                // gamma and trigger in step; handleMediaKey already special-cases this.
                if target.isBuiltIn {
                    setLevel(Float(value))
                    sync(target, .brightness, value)
                } else {
                    applyBrightness(target, value, animated: false)
                    sync(target, .brightness, value)
                }
            }

        case .contrast:
            // Contrast is only meaningful on displays with DDC, so the built-in and any
            // shade-only display sit this out.
            let targets = syncAll ? displays.filter { $0.ddcService != nil } : [display]
            for target in targets {
                guard let service = target.ddcService else { continue }
                target.contrast = value
                DDC.writer.write(service, display: target.id, command: DDC.contrast,
                                 value: UInt16((value * Double(target.ddcContrastMax)).rounded()))
                sync(target, .contrast, value)
            }

        case .volume:
            guard let service = display.ddcService else { return }
            display.volume = value
            DDC.writer.write(service, display: display.id, command: DDC.volume,
                             value: UInt16((value * Double(display.ddcVolumeMax)).rounded()))
            sync(display, .volume, value)
        }
    }

    /// The levels the settings window offers for typing. Rebuilt on every open, because the
    /// display list is not fixed.
    private func editableValues() -> [SettingsWindowController.Value] {
        var values: [SettingsWindowController.Value] = []
        for display in displays {
            func add(_ kind: Row, _ name: String, _ fraction: Double, max maxFraction: Double = 1) {
                values.append(.init(title: "\(display.name) — \(name)",
                                    fraction: fraction, maxFraction: maxFraction) { [weak self, weak display] value in
                    guard let self = self, let display = display else { return }
                    self.applyRow(display, kind, value)
                })
            }

            if display.isBuiltIn {
                add(.brightness, "Brightness", Double(level), max: Double(maxLevel))
            } else if display.hasHardware || display.softwareFraction > 0 {
                add(.brightness, "Brightness", display.brightness)
            }
            if display.ddcService != nil, !mergeContrast {
                add(.contrast, "Contrast", display.contrast)
            }
            if display.hasAudio, showVolume || ownsAudio(display) {
                add(.volume, "Volume", display.volume)
            }
        }
        return values
    }

    @objc private func builtInLevelChanged(_ sender: NSSlider) {
        guard let display = builtInDisplay else { return }
        applyRow(display, .brightness, sender.doubleValue)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)) else { return }
        applyRow(display, .brightness, sender.doubleValue)
    }

    @objc private func contrastChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)) else { return }
        applyRow(display, .contrast, sender.doubleValue)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)) else { return }
        applyRow(display, .volume, sender.doubleValue)
    }

    @objc private func enableMediaKeys() {
        MediaKeys.requestTrust()
        pollForTrust()
    }

    /// The Accessibility switch is flipped in System Settings, long after launch and with no
    /// notification to us — so watch for it rather than making the user click a menu item at
    /// exactly the right moment.
    private func pollForTrust() {
        guard !mediaKeys.isRunning else { return }
        trustPoll?.invalidate()
        // .common for the same reason as hdrWait — a default-mode timer pauses while the
        // status menu is open, which for this one only delays trust detection, but the fix
        // is the same line.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard self.mediaKeys.isTrusted, self.mediaKeys.start() else { return }
            timer.invalidate()
            self.trustPoll = nil
            UserDefaults.standard.set(true, forKey: "MediaKeysActive")
            self.rebuildMenu()
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPoll = timer
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("KelvinXDR: launch at login failed. \(error.localizedDescription)")
        }
        rebuildMenu()
    }
}
