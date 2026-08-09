//
//  OSD.swift
//  KelvinXDR
//
//  Level indicator shown when a media key changes something, on the display the change
//  applied to.
//
//  ponytail: our own HUD rather than the system one. macOS's OSD lives behind a private
//  XPC protocol (OSDUIHelper) that MonitorControl reverse-engineers; this is ~60 lines,
//  needs no private API, and lands on the right monitor without extra work. SystemOSD.swift
//  drives the real bezel for people who prefer it — this stays the default.
//

import Cocoa

/// The hit area around the 6pt track.
///
/// A 6pt-tall drag target is unusable, so the visible bar is a subview of something with a
/// finger-sized height and only this view handles the mouse.
final class OSDTrack: NSView {
    /// 0...1 along the track. Fires continuously while dragging, like the iOS volume bar.
    var onScrub: ((Double) -> Void)?
    /// True on mouse-down, false on mouse-up — the OSD holds itself open in between.
    var onDragChanged: ((Bool) -> Void)?

    /// The app is LSUIElement and near-always inactive when the HUD appears; without this,
    /// AppKit's click-through protection can spend the first click on activating the app
    /// instead of delivering it — a grab during the visible window would do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onDragChanged?(true)
        scrub(event)
    }

    override func mouseDragged(with event: NSEvent) { scrub(event) }

    override func mouseUp(with event: NSEvent) {
        scrub(event)
        onDragChanged?(false)
    }

    private func scrub(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onScrub?(Double(min(max(x / bounds.width, 0), 1)))
    }
}

final class OSD {
    private var window: NSWindow?
    private var icon: NSImageView?
    private var fill: NSView?
    private var notch: NSView?
    private var track: OSDTrack?
    private var hideWorkItem: DispatchWorkItem?
    private var dragging = false
    /// Stamps each scheduled hide. A `show()` or drag that arrives *during* the 0.35s fade
    /// cannot stop it with `cancel()` — the work item has already run; the fade is its output —
    /// so the fade's completion re-checks this and stands down if it has been superseded.
    private var hideGeneration = 0

    private let size = NSSize(width: 220, height: 56)
    private let visibleFor: TimeInterval = 1.1

    /// Full width of the track in points — the fill is a fraction of this.
    private var trackWidth: CGFloat { size.width - 76 }

    /// - value: 0...1, or nil for a stateless indicator such as mute.
    /// - mark: 0...1 position of a reference line on the track, or nil for none. The built-in
    ///   panel uses it to show where 100% sits on a scale that keeps going to 159%.
    /// - onScrub: 0...1 from dragging the track. nil makes the HUD non-interactive, which is
    ///   also what stops it swallowing clicks for indicators that have nothing to drag.
    func show(on screen: NSScreen, symbol: String, value: Double?, mark: Double? = nil,
              onScrub: ((Double) -> Void)? = nil) {
        let window = self.window ?? makeWindow()

        icon?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))

        setFill(value ?? 1)

        if let mark = mark {
            notch?.isHidden = false
            notch?.frame.origin.x = trackWidth * CGFloat(min(max(mark, 0), 1)) - 1
        } else {
            notch?.isHidden = true
        }

        // Only listen for the mouse when there is something to drag, and only while on screen
        // — the window sits at .screenSaver level over everything, so anything it accepts is a
        // click the app underneath never sees.
        track?.onScrub = onScrub
        window.ignoresMouseEvents = onScrub == nil

        // Flush under the menu bar, which on a notched display is exactly the notch's height,
        // so the HUD reads as hanging off it. `max(_, 24)` covers a display whose menu bar we
        // cannot measure because it is not the active one.
        let frame = screen.frame
        let menuBar = frame.height - (screen.visibleFrame.maxY - frame.minY)
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                      y: frame.maxY - size.height - max(menuBar, 24) - 6))
        cancelHide()
        // Re-asserted on every show, not just at creation. Ordering the window front while a
        // fullscreen Space is active can get it *adopted* by that Space, after which
        // canJoinAllSpaces is effectively gone: every other Space changes the value with no
        // HUD, and only the fullscreen app still shows it. Re-applying the behaviour makes
        // WindowServer re-tag the window as float-everywhere. Same recipe as MonitorControl.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()

        scheduleHide()
    }

    /// Move the fill without touching the icon, position or hide timer — the drag callback
    /// re-enters through here after the owner has clamped and applied the value.
    func update(value: Double) {
        setFill(value)
    }

    private func setFill(_ value: Double) {
        fill?.frame.size.width = trackWidth * CGFloat(min(max(value, 0), 1))
    }

    /// Stop the hide wherever it is: still queued (cancel the work item), or already fading
    /// (bump the generation so its completion stands down, and re-target the alpha back to 1
    /// *through the animator* — assigning the property directly does not stop a running
    /// animation, whose next tick just overwrites the assignment).
    private func cancelHide() {
        hideGeneration += 1
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let window = window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        // A drag has no idea how long it will last; the timer restarts when the mouse comes up.
        guard !dragging else { return }

        hideGeneration += 1
        let generation = hideGeneration
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self = self, self.hideGeneration == generation, let window = window else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // A show() or drag that arrived mid-fade has bumped the generation; ordering
                // out now would hide a HUD that just asked to stay.
                guard let self = self, self.hideGeneration == generation else { return }
                window.orderOut(nil)
                // Belt and braces: an ordered-out window should not be hit-testable anyway.
                window.ignoresMouseEvents = true
                self.track?.onScrub = nil
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: work)
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

        // 28pt of grabbable height wrapped around a 6pt bar drawn through its middle.
        let hit = OSDTrack(frame: NSRect(x: 56, y: 14, width: trackWidth, height: 28))
        hit.onDragChanged = { [weak self] active in
            guard let self = self else { return }
            self.dragging = active
            if active {
                // The hide was already queued when the HUD appeared, and setting `dragging`
                // does not reach back and stop it — without this the HUD vanishes mid-drag,
                // 1.1s after it opened, however long you are still holding on. cancelHide,
                // not cancel(): a grab *during* the fade must also stop the fade itself.
                self.cancelHide()
            } else {
                // Mouse-up restarts the clock from now, so it does not disappear under the
                // pointer the instant a long drag ends.
                self.scheduleHide()
            }
        }

        let bar = NSView(frame: NSRect(x: 0, y: 11, width: trackWidth, height: 6))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        bar.layer?.cornerRadius = 3
        hit.addSubview(bar)

        let fillView = NSView(frame: NSRect(x: 0, y: 0, width: trackWidth, height: 6))
        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor.white.cgColor
        fillView.layer?.cornerRadius = 3
        bar.addSubview(fillView)

        // Reference line, taller than the track so it reads as a boundary rather than part of
        // the fill. Sits above it, so crossing 100% visibly runs past the mark.
        let notchView = NSView(frame: NSRect(x: 0, y: -3, width: 2, height: 12))
        notchView.wantsLayer = true
        notchView.layer?.backgroundColor = NSColor.white.cgColor
        notchView.layer?.cornerRadius = 1
        notchView.isHidden = true
        bar.addSubview(notchView)

        blur.addSubview(hit)

        window.contentView = blur
        self.window = window
        self.icon = iconView
        self.fill = fillView
        self.notch = notchView
        self.track = hit
        return window
    }
}
