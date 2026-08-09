//
//  SystemOSD.swift
//  KelvinXDR
//
//  The stock macOS bezel — the big rounded square with the chiclet strip — driven through the
//  private OSDUIHelper XPC service. `OSDUIHelperProtocol` is declared in Bridging.h.
//
//  Only the *rendering* moves here. We still own the value and still swallow the keypress:
//  brightness has to stay intercepted for the range above 100% whatever the HUD looks like.
//
//  ponytail: no fallback if the XPC goes away. The compact HUD is the default and is a plain
//  NSWindow — if a future macOS drops the service, the fix is to switch the pref back, not to
//  carry a third code path.
//

import Cocoa

final class SystemOSD {
    /// Image identifiers OSDUIHelper draws. Empirical — there is no header for these.
    enum Image: Int64 {
        case brightness = 1
        case speaker = 3
        case speakerMuted = 4
    }

    /// What the system's own bezel passes. Anything lower loses to a real system OSD.
    private static let priority: UInt32 = 0x1F31
    private static let fadeAfter: UInt32 = 1000

    private var connection: NSXPCConnection?

    /// Reuses one connection; rebuilds it if the service was invalidated or restarted.
    ///
    /// `options: []`, *not* `.privileged` — OSDUIHelper is a LaunchAgent in the per-user GUI
    /// domain (`gui/$UID/com.apple.OSDUIHelper`). Asking for the privileged system domain gets
    /// the connection invalidated the instant it is resumed, silently: the proxy still hands
    /// back an object and the one-way calls still "succeed", so this is worth stating rather
    /// than rediscovering.
    private var helper: OSDUIHelperProtocol? {
        if connection == nil {
            let new = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            new.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
            // Drop only the connection the handler belongs to. A handler queued for a dead
            // connection can land *after* a keypress has already built its replacement, and
            // a bare `connection = nil` would throw that fresh one away. Weak, not strong:
            // a connection retains its own handlers, so capturing it strongly is a cycle.
            new.invalidationHandler = { [weak self, weak new] in
                DispatchQueue.main.async { self?.dropConnection(ifCurrent: new) }
            }
            // No interruptionHandler on purpose: for a machService connection an interruption
            // means the helper died, not the connection — it re-establishes on the next
            // message by itself. Tearing it down here was needless churn.
            new.resume()
            connection = new
        }
        guard let current = connection else { return nil }
        return current.remoteObjectProxyWithErrorHandler { [weak self, weak current] _ in
            DispatchQueue.main.async { self?.dropConnection(ifCurrent: current) }
        } as? OSDUIHelperProtocol
    }

    private func dropConnection(ifCurrent dead: NSXPCConnection?) {
        guard let dead = dead, connection === dead else { return }
        connection = nil
        // Invalidate before letting go — required pairing with resume(), and a second
        // invalidate on the already-invalidated path is a documented no-op. Nil first, so
        // the invalidation handler this triggers sees `connection !== dead` and stands down.
        dead.invalidate()
    }

    /// - filled/total: chiclets in the strip. The built-in panel runs past 100%, so it asks for
    ///   more than the usual 16 rather than rescaling — the extra chiclets *are* the XDR range.
    ///   The bezel cannot draw the compact HUD's 100% mark, so on this style there is no line
    ///   showing where the backlight stops and the gamma boost starts.
    func show(on display: CGDirectDisplayID, image: Image, filled: UInt32, total: UInt32) {
        helper?.showImage(image.rawValue,
                          onDisplayID: UInt32(display),
                          priority: Self.priority,
                          msecUntilFade: Self.fadeAfter,
                          filledChiclets: min(filled, total),
                          totalChiclets: total,
                          locked: false)
    }

    /// The strip-less variant, for indicators with no level — mute.
    func show(on display: CGDirectDisplayID, image: Image) {
        helper?.showImage(image.rawValue,
                          onDisplayID: UInt32(display),
                          priority: Self.priority,
                          msecUntilFade: Self.fadeAfter)
    }

    /// Chiclet count for a 0...1 value on Apple's 16-notch strip.
    static func chiclets(_ value: Double) -> UInt32 {
        UInt32(max(0, (value * 16).rounded()))
    }
}
