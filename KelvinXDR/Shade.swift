//
//  Shade.swift
//  KelvinXDR
//
//  A black overlay window used to dim displays where neither DDC nor the gamma table works:
//  AirPlay receivers, Sidecar, DisplayLink adapters and other virtual screens. Those are
//  composited by the window server rather than driven as real panels, so there is no
//  transfer table to scale and no I2C channel to talk to.
//
//  Strictly a last resort — it darkens by covering the screen, so it cannot make anything
//  brighter and it sits above other windows.
//

import Cocoa

final class Shade {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    /// - level: 1.0 is fully clear, 0.0 is black.
    func apply(level: CGFloat, to screen: NSScreen) {
        guard let id = screen.displayID else { return }
        let alpha = min(max(1 - level, 0), 1)

        guard alpha > 0.001 else { remove(id); return }

        let window = windows[id] ?? make(on: screen, id: id)
        window.setFrame(screen.frame, display: false)
        window.alphaValue = alpha
        // Re-asserted per show — a fullscreen Space can adopt the window (see OSD.show), and
        // a shade that only dims one Space is a shade that silently stopped working.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
    }

    func remove(_ id: CGDirectDisplayID) {
        windows[id]?.orderOut(nil)
        windows.removeValue(forKey: id)
    }

    func removeAll() {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func make(on screen: NSScreen, id: CGDirectDisplayID) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        // Above everything the user can interact with, but below the screen saver and
        // below our own OSD so the level indicator stays readable while dimming.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        windows[id] = window
        return window
    }
}
