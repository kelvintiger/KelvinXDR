//
//  MediaKeys.swift
//  KelvinXDR
//
//  Intercepts the keyboard's brightness / volume / mute keys and routes them to whichever
//  display the cursor is currently on, rather than always the main one.
//
//  Requires Accessibility permission — a CGEventTap that can *consume* events cannot be
//  created without it. Without permission `start()` returns false and the keys keep their
//  stock behaviour.
//

import Cocoa

final class MediaKeys {
    enum Key {
        case brightnessUp, brightnessDown, volumeUp, volumeDown, mute
    }

    /// What macOS itself does with a media key under each modifier combination.
    ///
    /// Every one of these has to be reimplemented rather than inherited: a swallowed key never
    /// reaches the system, so any behaviour we do not reproduce is simply lost. Option-alone
    /// was the regression that prompted this — we consumed the key and stepped the value where
    /// macOS would have opened System Settings.
    enum Adjustment: Equatable {
        /// No modifier: one 1/16 notch, with the feedback click if it is switched on.
        case coarse
        /// ⌥⇧: a quarter notch, 1/64.
        case fine
        /// ⌥ alone: open the relevant System Settings pane and change nothing.
        case openSettings
        /// ⇧ alone: one notch, with the feedback-sound setting *inverted* for this press —
        /// silent when the click is on, audible when it is off.
        case coarseInvertedFeedback
    }

    /// Pure so it can be checked without an event tap; see Tests/main.swift.
    ///
    /// Only Option and Shift participate. Command and Control are ignored rather than
    /// rejected, matching macOS: ⌘⇧ volume-up still steps and still inverts the click.
    static func adjustment(for modifiers: NSEvent.ModifierFlags) -> Adjustment {
        switch (modifiers.contains(.option), modifiers.contains(.shift)) {
        case (true, true):   return .fine
        case (true, false):  return .openSettings
        case (false, true):  return .coarseInvertedFeedback
        case (false, false): return .coarse
        }
    }

    /// Return true if handled — the key event is then swallowed so macOS does not also act
    /// on it. Return false to let it through (e.g. volume for a device we cannot drive,
    /// which macOS adjusts natively; built-in brightness is deliberately always handled —
    /// the 0...159% ladder only exists because we own the key).
    ///
    /// The whole modifier set is passed, not a pre-digested flag: the handler needs to tell
    /// ⌥ (open settings) from ⌥⇧ (fine step) from ⇧ (invert the click), and a Bool cannot.
    typealias Handler = (Key, NSScreen, NSEvent.ModifierFlags) -> Bool

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private static let nxSoundUp: Int = 0
    private static let nxSoundDown: Int = 1
    private static let nxBrightnessUp: Int = 2
    private static let nxBrightnessDown: Int = 3
    private static let nxMute: Int = 7

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show the "grant Accessibility" prompt. Returns current trust state.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard isTrusted else { return false }

        // NX_SYSDEFINED — media keys arrive as system-defined events, not key events.
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-arm it rather than dying quietly.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let passThrough = Unmanaged.passUnretained(event)
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return passThrough }

        let data = nsEvent.data1
        let keyCode = Int((data & 0xFFFF_0000) >> 16)
        let flags = data & 0x0000_FFFF
        let isKeyDown = ((flags & 0xFF00) >> 8) == 0x0A
        guard isKeyDown else { return passThrough }

        let key: Key
        switch keyCode {
        case Self.nxBrightnessUp:   key = .brightnessUp
        case Self.nxBrightnessDown: key = .brightnessDown
        case Self.nxSoundUp:        key = .volumeUp
        case Self.nxSoundDown:      key = .volumeDown
        case Self.nxMute:           key = .mute
        default: return passThrough
        }

        // The display the cursor is on wins — that is how MonitorControl picks a target, and
        // it is the only thing that makes sense with more than one external monitor.
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
                ?? NSScreen.main else { return passThrough }

        let modifiers = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        return handler(key, screen, modifiers) ? nil : passThrough
    }
}
