//
//  MissionControlDesktopCreator.swift
//  KelvinXDR
//
//  Narrow adapter for explicitly opening Mission Control and pressing Dock Accessibility's
//  add-desktop buttons. It owns no restore, conversion, topology, or retry policy.
//

import Cocoa

enum DesktopCreationFailure: Equatable, CustomStringConvertible {
    case accessibilityPermission
    case dockUnavailable
    case missionControlLaunch
    case missingMissionControlIdentifier
    case missingDisplayRows
    case missingAddIdentifier(ManagedSpaceDomainID)
    case pressFailed(ManagedSpaceDomainID)

    var description: String {
        switch self {
        case .accessibilityPermission: return "Accessibility permission is not granted"
        case .dockUnavailable: return "Dock Accessibility application is unavailable"
        case .missionControlLaunch: return "Mission Control could not be opened"
        case .missingMissionControlIdentifier: return "Dock AX identifier mc is unavailable"
        case .missingDisplayRows: return "Dock AX identifier mc.display is unavailable"
        case .missingAddIdentifier(let id):
            return "Dock AX identifier mc.spaces.add is unavailable for \(id.rawValue)"
        case .pressFailed(let id): return "Dock refused the add-desktop action for \(id.rawValue)"
        }
    }
}

struct DesktopCreationResult: Equatable {
    var requested: Int
    var created: Int
    var failures: [DesktopCreationFailure]

    var succeeded: Bool { created == requested && failures.isEmpty }
}

enum MissionControlDesktopCreator {
    static var capability: CapabilityAvailability {
        guard AXIsProcessTrusted() else {
            return .unavailable("Accessibility is required for Mission Control desktop creation")
        }
        guard dockApplication != nil else {
            return .unavailable("Dock is unavailable for Mission Control desktop creation")
        }
        return .available
    }

    /// Deficits must be ordered exactly like the SkyLight managed-display inventory. The AX
    /// tree exposes one `mc.display` row per managed domain in that same order.
    static func create(_ deficits: [SpacePlanner.Deficit],
                       returningFocusTo requestedFrontmost: NSRunningApplication? = nil)
        -> DesktopCreationResult {
        let requested = deficits.reduce(0) { $0 + max(0, $1.count) }
        guard requested > 0 else {
            return DesktopCreationResult(requested: 0, created: 0, failures: [])
        }
        guard AXIsProcessTrusted() else {
            return DesktopCreationResult(requested: requested, created: 0,
                                         failures: [.accessibilityPermission])
        }
        guard let dock = dockApplication else {
            return DesktopCreationResult(requested: requested, created: 0,
                                         failures: [.dockUnavailable])
        }

        let previousFrontmost = requestedFrontmost ?? NSWorkspace.shared.frontmostApplication
        defer {
            dismissMissionControl()
            Thread.sleep(forTimeInterval: 0.25)
            previousFrontmost?.activate()
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Mission Control"]
        guard (try? open.run()) != nil else {
            return DesktopCreationResult(requested: requested, created: 0,
                                         failures: [.missionControlLaunch])
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard waitForIdentifier("mc", in: dockElement, timeout: 2.0) != nil else {
            return DesktopCreationResult(requested: requested, created: 0,
                                         failures: [.missingMissionControlIdentifier])
        }
        guard !displayRows(in: dockElement).isEmpty else {
            return DesktopCreationResult(requested: requested, created: 0,
                                         failures: [.missingDisplayRows])
        }

        var result = DesktopCreationResult(requested: requested, created: 0, failures: [])
        for (index, deficit) in deficits.enumerated() where deficit.count > 0 {
            for _ in 0..<deficit.count {
                // Adding one desktop reflows the whole AX tree. Re-read `mc`, `mc.display`,
                // and `mc.spaces.add` before every press.
                let rows = displayRows(in: dockElement)
                guard index < rows.count else {
                    result.failures.append(.missingDisplayRows)
                    break
                }
                guard let button = find(rows[index], identifier: "mc.spaces.add") else {
                    result.failures.append(.missingAddIdentifier(deficit.managedDisplayID))
                    break
                }
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    result.failures.append(.pressFailed(deficit.managedDisplayID))
                    break
                }
                result.created += 1
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        return result
    }

    private static var dockApplication: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock"
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func identifier(_ element: AXUIElement) -> String {
        value(element, kAXIdentifierAttribute) as? String ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func find(_ element: AXUIElement, identifier wanted: String) -> AXUIElement? {
        if identifier(element) == wanted { return element }
        for child in children(element) {
            if let match = find(child, identifier: wanted) { return match }
        }
        return nil
    }

    private static func waitForIdentifier(_ identifier: String, in element: AXUIElement,
                                          timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = find(element, identifier: identifier) { return match }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private static func displayRows(in dock: AXUIElement) -> [AXUIElement] {
        guard let missionControl = find(dock, identifier: "mc") else { return [] }
        return children(missionControl).filter { identifier($0) == "mc.display" }
    }

    private static func dismissMissionControl() {
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?
                .post(tap: .cghidEventTap)
        }
    }
}
