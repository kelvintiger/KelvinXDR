//
//  DisplayControl.swift
//  KelvinXDR
//
//  One display, and every mechanism available for changing its brightness.
//
//  Brightness is a single 0...1 value. The bottom `softwareFraction` of that range drives
//  software dimming with the hardware already at its minimum, which is how dimming continues
//  below a panel's own floor and all the way to black. Above that, the hardware does the work
//  — DDC for external monitors, Apple's native protocol for the built-in.
//

import Cocoa

final class ManagedDisplay {
    enum Hardware {
        case ddc(IOAVService)
        case appleNative
        case none
    }

    /// How to dim below the hardware floor. Gamma is correct for real panels; virtual
    /// displays (AirPlay, Sidecar, DisplayLink) have no transfer table, so they need a shade.
    enum Software: String {
        case gamma, shade
    }

    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let hardware: Hardware
    let ddcBrightnessMax: UInt16
    let ddcVolumeMax: UInt16
    let ddcContrastMax: UInt16
    let hasAudio: Bool
    var software: Software

    /// Fraction of the slider given over to software dimming. 0 disables combined dimming.
    var softwareFraction: Double

    var brightness: Double
    var volume: Double
    var contrast: Double
    var muted: Bool

    var hasHardware: Bool {
        if case .none = hardware { return false }
        return true
    }

    var ddcService: IOAVService? {
        if case .ddc(let service) = hardware { return service }
        return nil
    }

    init(id: CGDirectDisplayID, name: String, isBuiltIn: Bool, hardware: Hardware,
         ddcBrightnessMax: UInt16 = 100, ddcVolumeMax: UInt16 = 100, ddcContrastMax: UInt16 = 100,
         hasAudio: Bool = false, software: Software = .gamma, softwareFraction: Double = 0.15,
         brightness: Double = 1, volume: Double = 0, contrast: Double = 0.7, muted: Bool = false) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.hardware = hardware
        self.ddcBrightnessMax = ddcBrightnessMax
        self.ddcVolumeMax = ddcVolumeMax
        self.ddcContrastMax = ddcContrastMax
        self.hasAudio = hasAudio
        self.software = software
        // A display with no hardware control is dimmed entirely in software.
        self.softwareFraction = { if case .none = hardware { return 1.0 } else { return softwareFraction } }()
        self.brightness = brightness
        self.volume = volume
        self.contrast = contrast
        self.muted = muted
    }

    /// Split a combined 0...1 value into what the hardware and the software layer each do.
    func split(_ value: Double) -> (hardware: Double, software: Double) {
        let v = min(max(value, 0), 1)
        let f = softwareFraction
        guard f > 0 else { return (v, 1) }
        guard f < 1 else { return (0, v) }
        return v >= f ? ((v - f) / (1 - f), 1) : (0, v / f)
    }
}

/// Applies brightness changes, optionally easing into them.
final class DisplayController {
    private let shade = Shade()
    /// Bumped per display to cancel an in-flight transition when a newer one starts.
    ///
    /// Guarded by a lock rather than the serial `queue`, deliberately: the whole point is that
    /// a new call preempts a ramp already running *on* that queue, so a bump enqueued behind
    /// the ramp could never cancel it. The lock is the only way both sides can touch this
    /// while one of them is mid-loop.
    private var generation: [CGDirectDisplayID: Int] = [:]
    private let generationLock = NSLock()

    private func nextGeneration(_ id: CGDirectDisplayID) -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        let next = (generation[id] ?? 0) + 1
        generation[id] = next
        return next
    }

    private func isCurrent(_ id: CGDirectDisplayID, _ value: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation[id] == value
    }
    private let queue = DispatchQueue(label: "KelvinXDR.displaycontrol", qos: .userInitiated)

    var smooth = true

    /// Call on the main thread.
    ///
    /// `display.brightness` is read and written here without a lock, which is safe only because
    /// every caller is a UI action, the media-key tap or the hotkey handler — all main. Two
    /// concurrent callers on different threads would race on it. The `generation` counter is
    /// separately locked because the ramp closure genuinely does touch it from another thread.
    func set(_ display: ManagedDisplay, brightness value: Double, screen: NSScreen?, animated: Bool? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let target = min(max(value, 0), 1)
        let from = display.brightness
        display.brightness = target

        // Never ramp a DDC display. Each step is a 20-40ms I2C exchange, so an eased ramp
        // reads as lag rather than smoothness — and the coalescing writer would discard the
        // intermediate steps anyway. Ramping is for the instant paths: Apple-native and gamma.
        let canAnimate = display.ddcService == nil
        let shouldAnimate = canAnimate && (animated ?? smooth) && abs(target - from) > 0.02
        let generationNow = nextGeneration(display.id)

        guard shouldAnimate else {
            queue.async { self.write(display, target, screen: screen, fast: false) }
            return
        }

        // Few steps and no I2C retries mid-flight: a DDC exchange is ~70ms at best, so a long
        // ramp would lag behind the key repeat rather than look smooth.
        let steps = display.ddcService != nil ? 4 : 12
        queue.async {
            for step in 1...steps {
                guard self.isCurrent(display.id, generationNow) else { return }
                let t = Double(step) / Double(steps)
                let eased = 1 - pow(1 - t, 3)
                self.write(display, from + (target - from) * eased, screen: screen, fast: step < steps)
                usleep(useconds_t(180_000 / steps))
            }
        }
    }

    private func write(_ display: ManagedDisplay, _ value: Double, screen: NSScreen?, fast: Bool) {
        let (hardware, software) = display.split(value)

        switch display.hardware {
        case .ddc(let service):
            let level = UInt16((hardware * Double(display.ddcBrightnessMax)).rounded())
            DDC.writer.write(service, display: display.id, command: DDC.brightness, value: level)
        case .appleNative:
            AppleBrightness.set(display.id, Float(hardware))
        case .none:
            break
        }

        // With combined dimming off there is no software layer to drive — and on the built-in
        // the gamma table belongs to the XDR boost, so touching it here would wipe it.
        guard display.softwareFraction > 0 else { return }

        switch display.software {
        case .gamma:
            // 1.0 means "leave it alone" — GammaBoost restores rather than scaling by 1.
            // Applied directly on this queue: GammaBoost is internally locked, and the old
            // main-queue hop predated that lock — the status menu's tracking loop starves
            // the main queue, which froze gamma-dimmed displays mid-drag until menu close.
            GammaBoost.apply(factor: Float(software), to: display.id)
        case .shade:
            // AppKit windows are main-thread-only, so the shade keeps the hop. It still lags
            // while a menu is open — accepted for the AirPlay/Sidecar fallback tier.
            DispatchQueue.main.async {
                if let screen = screen { self.shade.apply(level: CGFloat(software), to: screen) }
            }
        }
    }

    func clearAll() {
        shade.removeAll()
        GammaBoost.restoreAll()
    }
}
