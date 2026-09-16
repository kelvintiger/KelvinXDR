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

    // kVK_F14 / kVK_F15 — the brightness keys of pre-2007 Apple keyboards. Keyboard
    // remappers still speak that dialect: Logi Options+ delivers its "Brightness down"
    // action as a plain F14 keypress, not an NX_SYSDEFINED media key, so a remapped
    // third-party key reached nothing at all before this existed.
    private static let vkF14: Int = 107
    private static let vkF15: Int = 113

    /// Pure so it can be checked without an event tap; see Tests/main.swift.
    static func key(forFunctionKeyCode code: Int) -> Key? {
        switch code {
        case vkF14: return .brightnessDown
        case vkF15: return .brightnessUp
        default:    return nil
        }
    }

    private let handler: Handler
    private var taps: [CFMachPort] = []
    private var runLoopSources: [CFRunLoopSource] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show the "grant Accessibility" prompt. Returns current trust state.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    var isRunning: Bool { !taps.isEmpty }

    /// Two taps with deliberately disjoint interests, so no single press is counted twice.
    ///
    /// The built-in keys arrive as NX_SYSDEFINED and are taken at the HID level, the
    /// earliest point in the stream. F14/F15 cannot be taken there: a remapper synthesises
    /// them with CGEventPost at the *session* level, downstream of every HID tap, so a HID
    /// tap never sees them — measured with a listen-only tap at both levels.
    @discardableResult
    func start() -> Bool {
        guard taps.isEmpty else { return true }
        guard isTrusted else { return false }

        let sysDefined = CGEventMask(1 << 14)
        let keyEvents = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        // The media keys are why this class exists, so failing that tap is failing outright.
        guard let hid = addTap(.cghidEventTap, mask: sysDefined) else { return false }
        taps.append(hid)
        // The function-key dialect is an addition, so a refusal here is not fatal: the
        // built-in keyboard keeps working and only a remapped external key goes unhandled.
        if let session = addTap(.cgSessionEventTap, mask: keyEvents) { taps.append(session) }
        return true
    }

    private func addTap(_ location: CGEventTapLocation, mask: CGEventMask) -> CFMachPort? {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: location,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSources.append(source)
        return tap
    }

    /// The display the cursor is on wins — that is how MonitorControl picks a target, and
    /// it is the only thing that makes sense with more than one external monitor.
    private var cursorScreen: NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-arm it rather than dying quietly.
        // Every tap is re-enabled because the callback cannot tell which one was disabled,
        // and enabling an already-live tap is a no-op.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for tap in taps { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp { return handleFunctionKey(type: type, event: event) }

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

        guard let screen = cursorScreen else { return passThrough }
        let modifiers = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        return handler(key, screen, modifiers) ? nil : passThrough
    }

    /// F14/F15 as brightness. Only those two codes are touched — every other key event,
    /// which is to say all of typing, returns untouched on the first guard.
    private func handleFunctionKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let key = Self.key(forFunctionKeyCode: code) else { return passThrough }

        // Swallow the key-up too. Handing the front app half a keystroke for a key we took
        // would leave it believing F14 is still held down.
        guard type == .keyDown else { return nil }
        guard let screen = cursorScreen else { return passThrough }

        let modifiers = NSEvent(cgEvent: event)?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        return handler(key, screen, modifiers) ? nil : passThrough
    }
}
