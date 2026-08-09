//
//  AppDelegate.swift
//  KelvinXDR
//

import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MacBookPro18,1 built-in XDR. BrightIntosh's reference bonus gamma for this panel class
    // is 0.59, so 1.59x is the ceiling — past that you are only clipping highlights.
    private let maxFactor: Float = 1.59
    private let minFactor: Float = 0.30

    private var window: NSWindow!
    private var trigger: EDRTrigger!
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!

    private var hdrWait: Timer?
    private var trustPoll: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private var mediaKeys: MediaKeys!
    private let osd = OSD()
    private let controller = DisplayController()

    private var displays: [ManagedDisplay] = []
    private var rows: [RowKey: (slider: NSSlider, label: NSTextField)] = [:]

    private enum Row: Int { case brightness, contrast, volume, xdr }

    private let excluded = Set(
        UserDefaults.standard.stringArray(forKey: "ExcludedBundleIDs") ?? ["com.apple.TV"]
    )

    private func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    private var enabled: Bool {
        get { flag("Enabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "Enabled") }
    }
    private var syncAll: Bool {
        get { flag("SyncAllDisplays", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "SyncAllDisplays") }
    }
    private var smooth: Bool {
        get { flag("SmoothTransitions", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "SmoothTransitions"); controller.smooth = newValue }
    }

    /// Built-in panel gamma multiplier. Below 1.0 dims, above 1.0 needs EDR headroom.
    private var factor: Float {
        get {
            guard UserDefaults.standard.object(forKey: "Brightness") != nil else { return maxFactor }
            return min(max(UserDefaults.standard.float(forKey: "Brightness"), minFactor), maxFactor)
        }
        set { UserDefaults.standard.set(newValue, forKey: "Brightness") }
    }

    /// Display set as of the last configuration change, so we can tell a real hotplug from
    /// the many other things that post didChangeScreenParameters.
    private var knownDisplays: Set<CGDirectDisplayID> = []

    private var suspended = false
    private var boosting: Bool { enabled && !suspended }

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

        mediaKeys = MediaKeys { [weak self] key, screen in
            self?.handleMediaKey(key, on: screen) ?? false
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

    private func handleMediaKey(_ key: MediaKeys.Key, on screen: NSScreen) -> Bool {
        guard let id = screen.displayID, let target = display(for: id) else { return false }

        switch key {
        case .brightnessUp, .brightnessDown:
            let delta = key == .brightnessUp ? 1.0 / 16 : -1.0 / 16
            let targets = syncAll ? displays.filter { $0.hasHardware || $0.softwareFraction > 0 } : [target]
            for display in targets {
                controller.set(display, brightness: display.brightness + delta,
                               screen: self.screen(for: display.id))
                sync(display, .brightness, display.brightness)
            }
            osd.show(on: screen, symbol: "sun.max.fill", value: target.brightness)
            return true

        case .volumeUp, .volumeDown:
            guard let service = target.ddcService, target.hasAudio else { return false }
            let delta = key == .volumeUp ? 1.0 / 16 : -1.0 / 16
            target.volume = min(max(target.volume + delta, 0), 1)
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
            guard let service = target.ddcService, target.hasAudio else { return false }
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
        let needsEDR = boosting && factor > 1.0

        if needsEDR {
            trigger.setEDREnabled(true)
            window.orderFrontRegardless()
            waitForHDRThenApplyGamma()
        } else {
            hdrWait?.invalidate()
            hdrWait = nil
            trigger.setEDREnabled(false)
            window.orderOut(nil)
            if boosting, factor < 1.0, let id = builtInScreen?.displayID {
                GammaBoost.apply(factor: factor, to: id)
            } else if let id = builtInScreen?.displayID {
                GammaBoost.restore(id)
            }
        }

        // Circled sun, not a bare one: a plain sun.max was indistinguishable from
        // MonitorControl's icon sitting a few slots away in the same menu bar.
        statusItem.button?.image = NSImage(
            systemSymbolName: boosting ? "sun.max.circle.fill" : "sun.max.circle",
            accessibilityDescription: "KelvinXDR brightness")
        toggleItem?.state = enabled ? .on : .off
    }

    /// Gamma above 1.0 only has headroom to move into once the display is in EDR mode, and
    /// that takes a moment after the trigger window appears.
    private func waitForHDRThenApplyGamma() {
        hdrWait?.invalidate()
        // Already have headroom: apply now rather than up to 100ms later, so dragging the
        // slider tracks the pointer instead of lagging behind it.
        if let id = builtInScreen?.displayID, builtInScreen?.hdrEngaged == true {
            GammaBoost.apply(factor: factor, to: id)
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
                GammaBoost.apply(factor: self.factor, to: id)
            }
        }
    }

    @objc private func reapply() {
        guard boosting else { return }
        applyState()
    }

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
                toggleItem = NSMenuItem(title: "Extra Brightness", action: #selector(toggleEnabled), keyEquivalent: "")
                toggleItem.target = self
                toggleItem.state = enabled ? .on : .off
                menu.addItem(toggleItem)
                menu.addItem(row(display, .xdr, "sparkles",
                                 value: Double((factor - minFactor) / (maxFactor - minFactor)),
                                 text: String(format: "%.2fx", factor),
                                 action: #selector(xdrChanged)))
            }

            if display.hasHardware || display.softwareFraction > 0 {
                menu.addItem(row(display, .brightness, "sun.max.fill",
                                 value: display.brightness, text: percent(display.brightness),
                                 action: #selector(brightnessChanged)))
            }
            if display.ddcService != nil {
                menu.addItem(row(display, .contrast, "circle.lefthalf.filled",
                                 value: display.contrast, text: percent(display.contrast),
                                 action: #selector(contrastChanged)))
            }
            if display.hasAudio {
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
                     value: Double, text: String, action: Selector) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 268, height: 28))

        let icon = NSImageView(frame: NSRect(x: 18, y: 6, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        container.addSubview(icon)

        let slider = NSSlider(frame: NSRect(x: 44, y: 4, width: 170, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
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

    @objc private func toggleEnabled() { enabled.toggle(); applyState() }
    @objc private func toggleSync() { syncAll.toggle(); rebuildMenu() }
    @objc private func toggleSmooth() { smooth.toggle(); rebuildMenu() }

    @objc private func xdrChanged(_ sender: NSSlider) {
        factor = minFactor + Float(sender.doubleValue) * (maxFactor - minFactor)
        if let display = display(for: CGDirectDisplayID(sender.tag)) {
            sync(display, .xdr, sender.doubleValue)
            rows[rowKey(display, .xdr)]?.label.stringValue = String(format: "%.2fx", factor)
        }
        applyState()
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)) else { return }
        let targets = syncAll ? displays.filter { $0.hasHardware || $0.softwareFraction > 0 } : [display]
        for target in targets {
            controller.set(target, brightness: sender.doubleValue, screen: screen(for: target.id),
                           animated: false)
            if target !== display { sync(target, .brightness, sender.doubleValue) }
        }
        rows[rowKey(display, .brightness)]?.label.stringValue = percent(sender.doubleValue)
    }

    @objc private func contrastChanged(_ sender: NSSlider) {
        guard let display = display(for: CGDirectDisplayID(sender.tag)),
              let service = display.ddcService else { return }
        display.contrast = sender.doubleValue
        DDC.writer.write(service, display: display.id, command: DDC.contrast,
                         value: UInt16((display.contrast * Double(display.ddcContrastMax)).rounded()))
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
