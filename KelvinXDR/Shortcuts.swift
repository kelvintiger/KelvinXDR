//
//  Shortcuts.swift
//  KelvinXDR
//
//  User-assignable global hotkeys.
//
//  Carbon's RegisterEventHotKey rather than widening the CGEventTap in MediaKeys. The tap is
//  shared with the media keys, and a handler that stalls gets the whole tap torn down by the
//  system (tapDisabledByTimeout) — one slow path would silently kill brightness and volume
//  keys too. Carbon hot keys need no Accessibility grant and never see a keystroke that does
//  not match. It is old API, but it is what every hotkey library on macOS still wraps.
//

import Carbon.HIToolbox
import Cocoa

enum ShortcutAction: String, CaseIterable {
    case brightnessUp, brightnessDown, maximumBrightness, displayOff

    var title: String {
        switch self {
        case .brightnessUp:      return "Brightness Up"
        case .brightnessDown:    return "Brightness Down"
        case .maximumBrightness: return "Maximum Brightness"
        case .displayOff:        return "Turn Display Off"
        }
    }

    var detail: String {
        switch self {
        case .brightnessUp:      return "One notch up, past 100% into XDR"
        case .brightnessDown:    return "One notch down"
        case .maximumBrightness: return "Jump to the top of the scale"
        case .displayOff:        return "Put the displays to sleep"
        }
    }
}

/// A key combination, stored as the raw values UserDefaults can hold.
struct Shortcut: Equatable {
    let keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, ...), not NSEvent's.
    let modifiers: UInt32

    var displayString: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        return out + (Shortcut.keyName(keyCode) ?? "?")
    }

    /// NSEvent's modifier flags use a different bit layout from Carbon's, so a recorder that
    /// stored the former would register a hotkey nobody could type.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.option)  { out |= UInt32(optionKey) }
        if flags.contains(.shift)   { out |= UInt32(shiftKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        return out
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Resolve through the current keyboard layout, so a recorded key reads the way it is
    /// printed on the user's keyboard rather than as a US-QWERTY guess.
    static func keyName(_ keyCode: UInt32) -> String? {
        if let name = named[Int(keyCode)] { return name }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers the hotkeys and reports which action fired.
final class Shortcuts {
    typealias Handler = (ShortcutAction) -> Void

    private let handler: Handler
    private var registered: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// Carbon identifies a hotkey by a four-char signature plus an id; the id indexes back
    /// into ShortcutAction.allCases.
    private static let signature: OSType = 0x4B58_4452  // 'KXDR'

    init(handler: @escaping Handler) {
        self.handler = handler
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - Storage

    private static func key(_ action: ShortcutAction) -> String { "Shortcut_\(action.rawValue)" }

    static func stored(_ action: ShortcutAction) -> Shortcut? {
        guard let pair = UserDefaults.standard.array(forKey: key(action)) as? [Int],
              pair.count == 2 else { return nil }
        return Shortcut(keyCode: UInt32(pair[0]), modifiers: UInt32(pair[1]))
    }

    static func store(_ shortcut: Shortcut?, for action: ShortcutAction) {
        guard let shortcut = shortcut else {
            UserDefaults.standard.removeObject(forKey: key(action)); return
        }
        UserDefaults.standard.set([Int(shortcut.keyCode), Int(shortcut.modifiers)],
                                  forKey: key(action))
    }

    // MARK: - Registration

    /// Drop every hotkey and re-register from what is stored. Cheap, and it means the settings
    /// window only has to say "something changed" rather than track which one.
    func reload() {
        unregisterAll()
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = Shortcuts.stored(action), shortcut.modifiers != 0 else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Shortcuts.signature, id: UInt32(index))
            // A combination already owned by another app fails here rather than throwing;
            // leaving it unregistered is the honest outcome.
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref = ref {
                registered[action] = ref
            }
        }
    }

    /// Did the combination register, or is another app already holding it?
    func isActive(_ action: ShortcutAction) -> Bool { registered[action] != nil }

    private func unregisterAll() {
        registered.values.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == Shortcuts.signature,
                  Int(id.id) < ShortcutAction.allCases.count
            else { return OSStatus(eventNotHandledErr) }

            let me = Unmanaged<Shortcuts>.fromOpaque(context).takeUnretainedValue()
            me.handler(ShortcutAction.allCases[Int(id.id)])
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    // MARK: - Actions the app cannot do itself

    /// IODisplayWrangler, the classic way to do this, does not exist on Apple Silicon — so
    /// this shells out to pmset, which needs no privileges and is the documented route.
    static func sleepDisplays() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        do { try task.run() } catch {
            NSLog("KelvinXDR: could not sleep displays. \(error.localizedDescription)")
        }
    }
}
