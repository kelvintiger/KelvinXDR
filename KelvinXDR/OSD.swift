//
//  OSD.swift
//  KelvinXDR
//
//  Level indicator shown when a media key changes something, on the display the change
//  applied to.
//
//  ponytail: our own HUD rather than the system one. macOS's OSD lives behind a private
//  XPC protocol (OSDUIHelper) that MonitorControl reverse-engineers; this is ~60 lines,
//  needs no private API, and lands on the right monitor without extra work.
//

import Cocoa

final class OSD {
    private var window: NSWindow?
    private var icon: NSImageView?
    private var fill: NSView?
    private var hideWorkItem: DispatchWorkItem?

    private let size = NSSize(width: 220, height: 56)

    /// - value: 0...1, or nil for a stateless indicator such as mute.
    func show(on screen: NSScreen, symbol: String, value: Double?) {
        let window = self.window ?? makeWindow()

        icon?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))

        let trackWidth = size.width - 76
        fill?.frame.size.width = trackWidth * CGFloat(min(max(value ?? 1, 0), 1))

        // Top-centre, clear of the menu bar and the notch on displays that have one.
        let frame = screen.frame
        let menuBar = frame.height - (screen.visibleFrame.maxY - frame.minY)
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                      y: frame.maxY - size.height - max(menuBar, 24) - 16))
        window.alphaValue = 1
        window.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak window] in
            guard let window = window else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                window.animator().alphaValue = 0
            } completionHandler: {
                window.orderOut(nil)
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true

        let iconView = NSImageView(frame: NSRect(x: 18, y: 16, width: 24, height: 24))
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyUpOrDown
        blur.addSubview(iconView)

        let trackWidth = size.width - 76
        let track = NSView(frame: NSRect(x: 56, y: 25, width: trackWidth, height: 6))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        track.layer?.cornerRadius = 3
        blur.addSubview(track)

        let fillView = NSView(frame: NSRect(x: 0, y: 0, width: trackWidth, height: 6))
        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor.white.cgColor
        fillView.layer?.cornerRadius = 3
        track.addSubview(fillView)

        window.contentView = blur
        self.window = window
        self.icon = iconView
        self.fill = fillView
        return window
    }
}
