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

    /// Return true if handled — the key event is then swallowed so macOS does not also act
    /// on it. Return false to let it through (e.g. brightness on the built-in panel, which
    /// macOS already does natively and better).
    ///
    /// The Bool is macOS's Option+Shift fine-adjust. Since a handled key is swallowed, the
    /// system never sees the combination, so we have to honour it ourselves or it is lost.
    typealias Handler = (Key, NSScreen, Bool) -> Bool

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

    func stop() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
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
        let fine = modifiers.isSuperset(of: [.option, .shift])

        return handler(key, screen, fine) ? nil : passThrough
    }
}
