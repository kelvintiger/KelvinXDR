//
//  AppDelegate.swift
//  KelvinXDR
//

import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MacBookPro18,1 built-in XDR. BrightIntosh's reference bonus gamma for this panel class
    // is 0.59, so 159% is the ceiling — past that you are only clipping highlights.
    private let maxLevel: Float = 1.59

    private var window: NSWindow!
    private var trigger: EDRTrigger!
    private var statusItem: NSStatusItem!

    private var hdrWait: Timer?
    private var trustPoll: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private var mediaKeys: MediaKeys!
    private let osd = OSD()
    private let controller = DisplayController()

    private var displays: [ManagedDisplay] = []
    private var rows: [RowKey: (slider: NSSlider, label: NSTextField)] = [:]

    private enum Row: Int { case brightness, contrast, volume }

    // Empty by default: the 1x1 trigger cannot cover video, so there is nothing to step
    // aside from. Populate it to release the boost while a given app is frontmost.
    private let excluded = Set(
        UserDefaults.standard.stringArray(forKey: "ExcludedBundleIDs") ?? []
    )

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
        set { UserDefaults.standard.set(min(max(newValue, 1.0), maxLevel), forKey: "XDRGammaFactor") }
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
            let old = defaults.object(forKey: "Brightness") != nil
                ? defaults.float(forKey: "Brightness") : maxLevel
            defaults.set(wasEnabled ? min(max(old, 1.0), maxLevel) : 1.0, forKey: "XDRGammaFactor")
        }
        defaults.removeObject(forKey: "Brightness")
        defaults.removeObject(forKey: "Enabled")
    }

    private var builtInDisplay: ManagedDisplay? { displays.first { $0.isBuiltIn } }

    /// The built-in panel's one control, 0...maxLevel. 1.0 is 100%: backlight at maximum, no
    /// boost. Below that it is the backlight; above it the backlight stays pinned and gamma
    /// spends the EDR headroom. Crossing 100% is what engages XDR.
    private var level: Float {
        guard let builtIn = builtInDisplay else { return xdrFactor }
        // A backlight below maximum means something outside this app pulled it down, and a
        // boost is meaningless there — report the backlight and let applyState drop the gamma.
        return builtIn.brightness < 0.99 ? Float(builtIn.brightness) : xdrFactor
    }

    private func setLevel(_ value: Float) {
        guard let builtIn = builtInDisplay else { return }
        let target = min(max(value, 0), maxLevel)

        if target >= 1.0 {
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
        switch UserDefaults.standard.string(forKey: "TriggerCorner") ?? "bottomRight" {
        case "topLeft":     origin = CGPoint(x: f.minX, y: f.maxY - 1)
        case "topRight":    origin = CGPoint(x: f.maxX - 1, y: f.maxY - 1)
        case "bottomLeft":  origin = CGPoint(x: f.minX, y: f.minY)
        default:            origin = CGPoint(x: f.maxX - 1, y: f.minY)
        }
        window.setFrameOrigin(origin)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        migrateLegacyPrefs()
        guard let screen = builtInScreen ?? NSScreen.main else { return }
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
        // Bottom-right corner. It reads as a dead pixel anywhere you can see it, and on this
        // panel the extreme corner falls inside the display's rounded-corner mask, so it is
        // hidden outright. Overridable in case a future display has square corners:
        //   defaults write com.kelvin.KelvinXDR TriggerCorner -string topLeft
        positionTrigger(on: screen)

        trigger = EDRTrigger()
        window.contentView = trigger

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        mediaKeys = MediaKeys { [weak self] key, screen, fine in
            self?.handleMediaKey(key, on: screen, fine: fine) ?? false
        }
        mediaKeys.start()
        // Written so the state is checkable from outside without rebuilding the app.
        UserDefaults.standard.set(mediaKeys.isRunning, forKey: "MediaKeysActive")
        pollForTrust()

        installTerminationHandlers()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reapply),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        suspended = excluded.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        rebuildMenu()
        applyState()
        refreshDisplays()
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
                GammaBoost.restoreAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Displays

    private func refreshDisplays() {
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
                self.knownDisplays = Set(found.map { $0.id })
                self.displays = found
                self.rebuildMenu()
                self.applyState()
            }
        }
    }

    @objc private func displaysChanged() {
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

    private func handleMediaKey(_ key: MediaKeys.Key, on screen: NSScreen, fine: Bool) -> Bool {
        guard let id = screen.displayID, let target = display(for: id) else { return false }

        switch key {
        case .brightnessUp, .brightnessDown:
            let up = key == .brightnessUp
            let targets = syncAll ? displays.filter { $0.hasHardware || $0.softwareFraction > 0 } : [target]
            for display in targets {
                if display.isBuiltIn {
                    // The unified scale runs to 159%, so the keys keep climbing past the top
                    // of the backlight into the XDR range instead of stopping at 100%.
                    // setLevel pins the backlight and re-runs applyState on the way through.
                    setLevel(Detent.next(from: level, up: up, ceiling: maxLevel, fine: fine))
                    sync(display, .brightness, Double(level))
                } else {
                    applyBrightness(display, Double(Detent.next(from: Float(display.brightness), up: up, ceiling: 1, fine: fine)))
                    sync(display, .brightness, display.brightness)
                }
            }
            if target.isBuiltIn {
                // Mark where 100% falls on a track that runs to 159%, and switch the glyph
                // once past it, so crossing into XDR is unmistakable without a readout.
                osd.show(on: screen, symbol: level > 1.0 ? "sparkles" : "sun.max.fill",
                         value: Double(level / maxLevel), mark: Double(1.0 / maxLevel))
            } else {
                osd.show(on: screen, symbol: "sun.max.fill", value: target.brightness)
            }
            return true

        case .volumeUp, .volumeDown:
            guard let service = target.ddcService, ownsAudio(target) else { return false }
            target.volume = Double(Detent.next(from: Float(target.volume), up: key == .volumeUp, ceiling: 1, fine: fine))
            DDC.writer.write(service, display: target.id, command: DDC.volume,
                             value: UInt16((target.volume * Double(target.ddcVolumeMax)).rounded()))
            if target.muted, target.volume > 0 {
                target.muted = false
                DDC.writer.write(service, display: target.id, command: DDC.mute, value: 2)
            }
            sync(target, .volume, target.volume)
            osd.show(on: screen, symbol: target.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                     value: target.volume)
            return true

        case .mute:
            guard let service = target.ddcService, ownsAudio(target) else { return false }
            target.muted.toggle()
            DDC.writer.write(service, display: target.id, command: DDC.mute,
                             value: target.muted ? 1 : 2)
            osd.show(on: screen, symbol: target.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                     value: target.muted ? 0 : target.volume)
            return true
        }
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
            trigger.setEDREnabled(true)
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

        hdrWait = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let engaged = self.builtInScreen?.hdrEngaged ?? false
            guard engaged || Date() > deadline else { return }

            timer.invalidate()
            self.hdrWait = nil
            if engaged, let id = self.builtInScreen?.displayID {
                GammaBoost.apply(factor: self.xdrFactor, to: id)
            }
        }
    }

    @objc private func reapply() { applyState() }

    @objc private func frontmostAppChanged() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let shouldSuspend = excluded.contains(frontmost)
        guard shouldSuspend != suspended else { return }
        suspended = shouldSuspend
        applyState()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu(title: "KelvinXDR")
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

        if !mediaKeys.isRunning {
            let item = NSMenuItem(title: "Enable Media Keys (needs Accessibility)…", action: #selector(enableMediaKeys), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(check("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin)))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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

    @objc private func toggleSync() { syncAll.toggle(); rebuildMenu() }
    @objc private func toggleSmooth() { smooth.toggle(); rebuildMenu() }
    @objc private func toggleShowVolume() { showVolume.toggle(); rebuildMenu() }

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

    @objc private func builtInLevelChanged(_ sender: NSSlider) {
        setLevel(Float(sender.doubleValue))
        if let display = builtInDisplay {
            rows[rowKey(display, .brightness)]?.label.stringValue = percent(sender.doubleValue)
        }
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)) else { return }
        let targets = syncAll ? displays.filter { $0.hasHardware || $0.softwareFraction > 0 } : [display]
        for target in targets {
            applyBrightness(target, sender.doubleValue, animated: false)
            if target !== display { sync(target, .brightness, sender.doubleValue) }
        }
        rows[rowKey(display, .brightness)]?.label.stringValue = percent(sender.doubleValue)
    }

    @objc private func contrastChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)) else { return }
        // Same toggle as brightness: contrast is only meaningful on displays with DDC, so the
        // built-in and any shade-only display sit this out.
        let targets = syncAll ? displays.filter { $0.ddcService != nil } : [display]
        for target in targets {
            guard let service = target.ddcService else { continue }
            target.contrast = sender.doubleValue
            DDC.writer.write(service, display: target.id, command: DDC.contrast,
                             value: UInt16((target.contrast * Double(target.ddcContrastMax)).rounded()))
            if target !== display { sync(target, .contrast, target.contrast) }
        }
        rows[rowKey(display, .contrast)]?.label.stringValue = percent(display.contrast)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)),
              let service = display.ddcService else { return }
        display.volume = sender.doubleValue
        DDC.writer.write(service, display: display.id, command: DDC.volume,
                         value: UInt16((display.volume * Double(display.ddcVolumeMax)).rounded()))
        rows[rowKey(display, .volume)]?.label.stringValue = percent(display.volume)
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
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard self.mediaKeys.isTrusted, self.mediaKeys.start() else { return }
            timer.invalidate()
            self.trustPoll = nil
            UserDefaults.standard.set(true, forKey: "MediaKeysActive")
            self.rebuildMenu()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("KelvinXDR: launch at login failed — \(error.localizedDescription)")
        }
        rebuildMenu()
    }
}
