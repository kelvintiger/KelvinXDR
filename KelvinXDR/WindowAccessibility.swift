//
//  WindowAccessibility.swift
//  KelvinXDR
//
//  Narrow Accessibility adapter for mapping AX windows to CGWindowIDs, reading stable window
//  evidence, explicitly leaving native fullscreen, and setting/verifying normal geometry.
//  It never selects Spaces, creates desktops, schedules restores, or requests Screen Recording.
//

import Cocoa

enum WindowAccessibilityFailure: Error, Equatable, CustomStringConvertible {
    case permission
    case windowBridge
    case windowUnavailable(UInt32)
    case attributeUnavailable(UInt32, String)
    case attributeNotSettable(UInt32, String)
    case writeFailed(UInt32, String)

    var description: String {
        switch self {
        case .permission: return "Accessibility permission is not granted"
        case .windowBridge: return "_AXUIElementGetWindow is unavailable"
        case .windowUnavailable(let id): return "Accessibility cannot reach window \(id)"
        case .attributeUnavailable(let id, let name): return "window \(id) has no \(name)"
        case .attributeNotSettable(let id, let name): return "window \(id) cannot set \(name)"
        case .writeFailed(let id, let name): return "window \(id) rejected \(name)"
        }
    }
}

struct WindowAccessibilityCapabilities: Equatable {
    var accessibilityPermission: CapabilityAvailability
    var axWindowBridge: CapabilityAvailability
    var windowEnumeration: CapabilityAvailability
    var positionWrites: CapabilityAvailability
    var sizeWrites: CapabilityAvailability
    var fullscreenWrites: CapabilityAvailability
    var highQualityTitles: CapabilityAvailability

    var identification: CapabilityAvailability {
        firstUnavailable([accessibilityPermission, axWindowBridge, windowEnumeration])
    }

    var geometry: CapabilityAvailability {
        firstUnavailable([identification, positionWrites, sizeWrites])
    }

    var conversion: CapabilityAvailability {
        firstUnavailable([identification, geometry, fullscreenWrites])
    }

    private func firstUnavailable(_ values: [CapabilityAvailability]) -> CapabilityAvailability {
        values.first(where: { !$0.isAvailable }) ?? .available
    }
}

struct PhysicalDisplayGeometry: Equatable {
    var uuid: String
    var name: String
    var bounds: CGRect
    /// Visible frame in AX/CGWindow top-left-origin coordinates.
    var visibleFrame: CGRect
}

enum WindowAccessibility {
    private typealias AXGetWindow = @convention(c)
        (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let axGetWindow: AXGetWindow? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
            .map { unsafeBitCast($0, to: AXGetWindow.self) }

    private static var evidenceCache: [UInt32: (title: String?, document: String?)] = [:]
    private static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?
            .object(forKey: "GloballyEnabled") as? Bool ?? false
    }

    static var runtimeCapabilities: WindowAccessibilityCapabilities {
        let trusted = AXIsProcessTrusted()
        let permission: CapabilityAvailability = trusted
            ? .available : .unavailable("Accessibility permission is not granted")
        let bridge: CapabilityAvailability = axGetWindow == nil
            ? .unavailable("_AXUIElementGetWindow is unavailable") : .available
        let identification = trusted && axGetWindow != nil
        return WindowAccessibilityCapabilities(
            accessibilityPermission: permission,
            axWindowBridge: bridge,
            windowEnumeration: identification
                ? .available : .unavailable("AX window enumeration is unavailable"),
            positionWrites: identification
                ? .available : .unavailable("AXPosition writes are unavailable"),
            sizeWrites: identification
                ? .available : .unavailable("AXSize writes are unavailable"),
            fullscreenWrites: identification
                ? .available : .unavailable("AXFullScreen writes are unavailable"),
            highQualityTitles: CGPreflightScreenCaptureAccess()
                ? .available : .unavailable("Screen Recording is not granted (optional)"))
    }

    static func windows() -> Result<[LiveWindow], WindowAccessibilityFailure> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        guard let getWindow = axGetWindow else { return .failure(.windowBridge) }
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return .success([])
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var axByPID: [Int32: [UInt32: AXUIElement]] = [:]
        var bundleByPID: [Int32: String] = [:]
        var result: [LiveWindow] = []

        for entry in raw {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  cgFrame.width >= 120, cgFrame.height >= 120 else { continue }

            if axByPID[pid] == nil {
                axByPID[pid] = elements(pid: pid, using: getWindow)
                if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                    bundleByPID[pid] = bundle
                }
            }
            let element = axByPID[pid]?[id]
            var frame = cgFrame
            var title = entry[kCGWindowName as String] as? String
            var document: String?
            var isFullscreen = false
            var isStandard = false
            var stageManager = false
            var setFullscreen = false
            var setPosition = false
            var setSize = false

            if let element = element {
                if title?.isEmpty ?? true { title = value(element, kAXTitleAttribute) as? String }
                document = value(element, kAXDocumentAttribute) as? String
                if let origin = point(element, kAXPositionAttribute),
                   let dimensions = size(element, kAXSizeAttribute) {
                    frame = CGRect(origin: origin, size: dimensions)
                }
                isFullscreen = value(element, "AXFullScreen") as? Bool ?? false
                let role = value(element, kAXRoleAttribute) as? String
                let subrole = value(element, kAXSubroleAttribute) as? String
                isStandard = role == kAXWindowRole && subrole == kAXStandardWindowSubrole
                let identifier = (value(element, kAXIdentifierAttribute) as? String ?? "").lowercased()
                stageManager = stageManagerEnabled || identifier.contains("stage")
                    || bundleByPID[pid] == "com.apple.WindowManager"
                setFullscreen = isSettable(element, "AXFullScreen")
                setPosition = isSettable(element, kAXPositionAttribute)
                setSize = isSettable(element, kAXSizeAttribute)
            }

            if let title = title, !title.isEmpty {
                evidenceCache[id] = (title, document)
            } else if let cached = evidenceCache[id] {
                title = cached.title
                if document == nil { document = cached.document }
            }

            result.append(LiveWindow(
                id: id, pid: pid, bundleID: bundleByPID[pid],
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: (title?.isEmpty ?? true) ? nil : title,
                documentIdentity: (document?.isEmpty ?? true) ? nil : document,
                frame: frame, isFullscreen: isFullscreen,
                isAXReachable: element != nil, isStandardWindow: isStandard,
                isStageManagerSpecial: stageManager, canSetFullscreen: setFullscreen,
                canSetPosition: setPosition, canSetSize: setSize))
        }
        return .success(result)
    }

    /// Explicit conversion is the only caller allowed to turn AXFullScreen off. This adapter
    /// never turns it back on because that would append a new type-4 Space and change order.
    static func exitFullscreen(pid: Int32,
                               windowID: UInt32) -> Result<Void, WindowAccessibilityFailure> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        guard let element = element(pid: pid, windowID: windowID) else {
            return .failure(.windowUnavailable(windowID))
        }
        let attribute = "AXFullScreen"
        guard isSettable(element, attribute) else {
            return .failure(.attributeNotSettable(windowID, attribute))
        }
        if value(element, attribute) as? Bool == false { return .success(()) }
        guard AXUIElementSetAttributeValue(element, attribute as CFString,
                                           false as CFBoolean) == .success else {
            return .failure(.writeFailed(windowID, attribute))
        }
        return .success(())
    }

    static func frame(pid: Int32,
                      windowID: UInt32) -> Result<CGRect, WindowAccessibilityFailure> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        guard let element = element(pid: pid, windowID: windowID) else {
            return .failure(.windowUnavailable(windowID))
        }
        guard let origin = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute) else {
            return .failure(.attributeUnavailable(windowID, "AXPosition/AXSize"))
        }
        return .success(CGRect(origin: origin, size: size))
    }

    static func setFrame(pid: Int32, windowID: UInt32,
                         frame: CGRect) -> Result<Void, WindowAccessibilityFailure> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        guard let element = element(pid: pid, windowID: windowID) else {
            return .failure(.windowUnavailable(windowID))
        }
        guard isSettable(element, kAXPositionAttribute) else {
            return .failure(.attributeNotSettable(windowID, kAXPositionAttribute))
        }
        guard isSettable(element, kAXSizeAttribute) else {
            return .failure(.attributeNotSettable(windowID, kAXSizeAttribute))
        }
        var origin = frame.origin
        var dimensions = frame.size
        guard let pointValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &dimensions) else {
            return .failure(.attributeUnavailable(windowID, "AXPosition/AXSize"))
        }
        // Size first avoids applications clamping position against the old oversized frame.
        guard AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString,
                                           sizeValue) == .success else {
            return .failure(.writeFailed(windowID, kAXSizeAttribute))
        }
        guard AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString,
                                           pointValue) == .success else {
            return .failure(.writeFailed(windowID, kAXPositionAttribute))
        }
        return .success(())
    }

    static func physicalDisplays() -> [PhysicalDisplayGeometry] {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let rawUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            else { return nil }
            return PhysicalDisplayGeometry(
                uuid: CFUUIDCreateString(nil, rawUUID) as String,
                name: screen.localizedName,
                bounds: CGDisplayBounds(id),
                visibleFrame: WindowGeometry.accessibilityFrame(
                    fromCocoa: screen.visibleFrame, mainDisplayHeight: mainHeight))
        }
    }

    private static func elements(pid: Int32,
                                 using getWindow: AXGetWindow) -> [UInt32: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return [:] }
        var result: [UInt32: AXUIElement] = [:]
        for window in windows {
            var id: CGWindowID = 0
            if getWindow(window, &id) == .success, id != 0 { result[UInt32(id)] = window }
        }
        return result
    }

    private static func element(pid: Int32, windowID: UInt32) -> AXUIElement? {
        guard let getWindow = axGetWindow else { return nil }
        return elements(pid: pid, using: getWindow)[windowID]
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
