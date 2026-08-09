//
//  GammaBoost.swift
//  KelvinXDR
//
//  Per-display gamma transfer table control. Two jobs:
//
//   1. Boost the built-in XDR panel above SDR white (factor > 1.0), using the headroom the
//      EDRTrigger opens. Applied at scanout, after compositing, so unlike a blended overlay
//      it also brightens protected video planes that the compositor may not read.
//
//   2. Software dimming (factor < 1.0) for displays with no working DDC, and to continue
//      dimming below a monitor's hardware minimum all the way to black.
//
//  Technique from BrightIntosh (GPL-3.0) — github.com/niklasr22/BrightIntosh
//

import Cocoa

enum GammaBoost {
    private static let tableSize: UInt32 = 256

    /// Guards every static below, and the CGSetDisplayTransferByTable calls that read them.
    ///
    /// The termination handlers run on a global queue while the main thread may be part-way
    /// through `apply`. Without this, `restoreAll` could hand the display back, the main thread
    /// could then finish writing its scaled table, and `exit(0)` would leave the screen at
    /// 1.59x until logout — precisely what those handlers exist to prevent.
    private static let lock = NSLock()

    /// Set once a termination handler has restored. Any `apply` that arrives afterwards is a
    /// write we must not perform, because nothing will run to undo it.
    private static var terminating = false

    /// Untouched table per display. Every apply scales from this, never from the current
    /// table, or repeated applies compound into a white screen.
    private static var base: [CGDirectDisplayID: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])] = [:]

    /// Displays we currently hold a modified table for.
    private static var active: Set<CGDirectDisplayID> = []

    /// True once we have reset ColorSync this session. A previous instance may have died
    /// without restoring — SIGKILL, a panic, or a modal menu blocking the signal handler —
    /// and capturing an already-scaled table as the baseline would multiply on top of it.
    private static var didResetOnce = false

    private static func captureBaseIfNeeded(_ display: CGDirectDisplayID) -> Bool {
        if base[display] != nil { return true }

        if !didResetOnce {
            CGDisplayRestoreColorSyncSettings()
            didResetOnce = true
        }

        var r = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var g = r
        var b = r
        var count: UInt32 = 0

        guard CGGetDisplayTransferByTable(display, tableSize, &r, &g, &b, &count) == .success,
              count == tableSize else { return false }

        base[display] = (r, g, b)
        return true
    }

    /// - factor: 1.0 leaves the display alone. Above 1.0 boosts into EDR headroom, below 1.0
    ///           dims, 0.0 is black.
    static func apply(factor: Float, to display: CGDirectDisplayID) {
        lock.lock()
        defer { lock.unlock() }
        applyLocked(factor: factor, to: display)
    }

    /// Put one display back. There is no per-display restore in CoreGraphics, so this
    /// rewrites the captured baseline rather than resetting everything.
    static func restore(_ display: CGDirectDisplayID) {
        lock.lock()
        defer { lock.unlock() }
        restoreLocked(display)
    }

    /// Hand every display back to ColorSync. Must run before exit or screens stay scaled.
    static func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        restoreAllLocked()
    }

    /// Restore and then refuse all further writes. For the signal handlers: an `apply` already
    /// in flight on another thread finishes first (it holds the lock), and any that arrives
    /// afterwards sees `terminating` and does nothing, so the last write to the hardware is
    /// always the restore.
    static func prepareForTermination() {
        lock.lock()
        defer { lock.unlock() }
        restoreAllLocked()
        terminating = true
    }

    // MARK: - Lock held

    private static func applyLocked(factor: Float, to display: CGDirectDisplayID) {
        guard !terminating else { return }
        guard factor != 1.0 else { restoreLocked(display); return }
        guard captureBaseIfNeeded(display), let base = base[display] else { return }

        var r = base.r.map { $0 * factor }
        var g = base.g.map { $0 * factor }
        var b = base.b.map { $0 * factor }

        if CGSetDisplayTransferByTable(display, tableSize, &r, &g, &b) == .success {
            active.insert(display)
        }
    }

    private static func restoreLocked(_ display: CGDirectDisplayID) {
        guard active.contains(display), var base = base[display] else { return }
        CGSetDisplayTransferByTable(display, tableSize, &base.r, &base.g, &base.b)
        active.remove(display)
    }

    private static func restoreAllLocked() {
        CGDisplayRestoreColorSyncSettings()
        active.removeAll()
    }

    /// Forget cached baselines — call when the display layout changes, since a reconnected
    /// display may have a different calibration.
    ///
    /// This MUST restore before forgetting. Dropping a baseline while its table is still
    /// scaled loses the only record of what "unscaled" was, and the next capture then reads
    /// the scaled table as the new baseline and multiplies on top of it — 1.59 becomes 2.53,
    /// and the screen washes out.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        // restoreAllLocked, not restoreAll: NSLock is not recursive, so calling the public
        // entry point from here would deadlock.
        restoreAllLocked()
        base.removeAll()
        // Force a fresh ColorSync reset before the next capture, belt-and-braces.
        didResetOnce = false
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// EDR is engaged once the display reports headroom above 1.0.
    var hdrEngaged: Bool {
        maximumExtendedDynamicRangeColorComponentValue > 1.05
    }
}
