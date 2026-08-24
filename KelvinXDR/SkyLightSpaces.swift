//
//  SkyLightSpaces.swift
//  KelvinXDR
//
//  Narrow runtime-gated access to ordered normal Spaces, per-window membership, and the
//  bridged normal-Space move. No profile, topology, conversion, matching, geometry, Dock UI,
//  or retry policy belongs here.
//
//  Data-shape and bridged-operation details follow SpaceKit (MIT); see THIRD_PARTY_NOTICES.md.
//

import Cocoa

enum SkyLightFailure: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    case malformedInventory(String)
    case rejected(String)

    var description: String {
        switch self {
        case .unavailable(let reason), .malformedInventory(let reason), .rejected(let reason):
            return reason
        }
    }
}

struct SkyLightRuntimeCapabilities: Equatable {
    var frameworkLoading: CapabilityAvailability
    var connectionSymbol: CapabilityAvailability
    var connectionValue: CapabilityAvailability
    var managedDisplayEnumerationSymbol: CapabilityAvailability
    var windowMembershipSymbol: CapabilityAvailability
    var bridgedMoveClass: CapabilityAvailability
    var moveInitializer: CapabilityAvailability
    var movePerformer: CapabilityAvailability

    var orderedInventory: CapabilityAvailability {
        firstUnavailable([frameworkLoading, connectionSymbol, connectionValue,
                          managedDisplayEnumerationSymbol])
    }

    var membership: CapabilityAvailability {
        firstUnavailable([frameworkLoading, connectionSymbol, connectionValue,
                          windowMembershipSymbol])
    }

    var movement: CapabilityAvailability {
        firstUnavailable([frameworkLoading, bridgedMoveClass, moveInitializer, movePerformer])
    }

    private func firstUnavailable(_ values: [CapabilityAvailability]) -> CapabilityAvailability {
        values.first(where: { !$0.isAvailable }) ?? .available
    }
}

enum SkyLightSpaces {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let handle = dlopen(frameworkPath, RTLD_LAZY)

    private static func symbol(_ names: String...) -> UnsafeMutableRawPointer? {
        guard let handle = handle else { return nil }
        for name in names {
            if let result = dlsym(handle, name) { return result }
        }
        return nil
    }

    /// `SLSMainConnectionID`, with the retained `CGSMainConnectionID` alias as fallback.
    private static let connectionFunction: MainConnectionID? =
        symbol("SLSMainConnectionID", "CGSMainConnectionID")
            .map { unsafeBitCast($0, to: MainConnectionID.self) }
    private static let connection: Int32? = connectionFunction.map { $0() }.flatMap { $0 == 0 ? nil : $0 }

    /// `SLSCopyManagedDisplaySpaces` returns per-domain dictionaries containing
    /// `Display Identifier` and ordered `Spaces` entries with `ManagedSpaceID`/`id64`, `uuid`,
    /// and `type` (0 normal, 4 native fullscreen/tiled).
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? =
        symbol("SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces")
            .map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }

    /// `SLSCopySpacesForWindows` returns the union for its input list, so this adapter always
    /// calls it with exactly one window. The 0x7 mask means current | other | user-created,
    /// from CGSInternal's `CGSSpace.h`.
    private static let copySpacesForWindows: CopySpacesForWindows? =
        symbol("SLSCopySpacesForWindows", "CGSCopySpacesForWindows")
            .map { unsafeBitCast($0, to: CopySpacesForWindows.self) }

    @objc private protocol BridgedMoveOperation {
        @objc(initWithWindows:spaceID:) init(windows: [NSNumber], spaceID: UInt64)
        @objc(performWithWMBridgeDelegate) func performWithWMBridgeDelegate()
    }

    private static let moveClass: AnyClass? =
        NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
    private static let moveInitializerSelector = NSSelectorFromString("initWithWindows:spaceID:")
    private static let movePerformerSelector = NSSelectorFromString("performWithWMBridgeDelegate")

    private static var moveClassAsNSObject: NSObject.Type? { moveClass as? NSObject.Type }

    static var runtimeCapabilities: SkyLightRuntimeCapabilities {
        SkyLightRuntimeCapabilities(
            frameworkLoading: handle == nil
                ? .unavailable("SkyLight.framework did not load") : .available,
            connectionSymbol: connectionFunction == nil
                ? .unavailable("SLSMainConnectionID/CGSMainConnectionID unavailable") : .available,
            connectionValue: connection == nil
                ? .unavailable("SkyLight main connection returned zero") : .available,
            managedDisplayEnumerationSymbol: copyManagedDisplaySpaces == nil
                ? .unavailable("SLSCopyManagedDisplaySpaces/CGSCopyManagedDisplaySpaces unavailable")
                : .available,
            windowMembershipSymbol: copySpacesForWindows == nil
                ? .unavailable("SLSCopySpacesForWindows/CGSCopySpacesForWindows unavailable")
                : .available,
            bridgedMoveClass: moveClass == nil
                ? .unavailable("SLSBridgedMoveWindowsToManagedSpaceOperation class unavailable")
                : .available,
            moveInitializer: moveClassAsNSObject?.instancesRespond(to: moveInitializerSelector) == true
                ? .available : .unavailable("initWithWindows:spaceID: unavailable"),
            movePerformer: moveClassAsNSObject?.instancesRespond(to: movePerformerSelector) == true
                ? .available : .unavailable("performWithWMBridgeDelegate unavailable"))
    }

    static func inventory() -> Result<[LiveDisplay], SkyLightFailure> {
        let capability = runtimeCapabilities.orderedInventory
        guard capability.isAvailable, let connection = connection,
              let copy = copyManagedDisplaySpaces else {
            return .failure(.unavailable(reason(capability)))
        }
        guard let raw = copy(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return .failure(.malformedInventory("SLSCopyManagedDisplaySpaces returned no dictionary array"))
        }

        var displays: [LiveDisplay] = []
        for entry in raw {
            guard let identifier = entry["Display Identifier"] as? String,
                  !identifier.isEmpty else {
                return .failure(.malformedInventory("managed display is missing Display Identifier"))
            }
            guard let spaces = entry["Spaces"] as? [[String: Any]] else {
                return .failure(.malformedInventory("\(identifier) is missing Spaces"))
            }
            var descriptors: [LiveSpaceDescriptor] = []
            for space in spaces {
                let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
                    ?? (space["id64"] as? NSNumber)?.uint64Value ?? 0
                guard id != 0, let type = (space["type"] as? NSNumber)?.intValue else { continue }
                let tileSpaces = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"]
                    as? [[String: Any]] ?? []
                let tileWindows = tileSpaces.compactMap {
                    ($0["TileWindowID"] as? NSNumber)?.uint32Value
                }.filter { $0 != 0 }
                let tileNames = tileSpaces.compactMap { $0["appName"] as? String }
                descriptors.append(LiveSpaceDescriptor(
                    id: id, uuid: space["uuid"] as? String ?? "", type: type,
                    tileWindows: tileWindows, tileAppNames: tileNames))
            }
            displays.append(SpacePlanner.inventory(
                managedDisplayID: ManagedSpaceDomainID(identifier), descriptors: descriptors))
        }
        return .success(displays)
    }

    static func membership(forWindow id: UInt32) -> Result<[UInt64], SkyLightFailure> {
        let capability = runtimeCapabilities.membership
        guard capability.isAvailable, let connection = connection,
              let copy = copySpacesForWindows else {
            return .failure(.unavailable(reason(capability)))
        }
        let windows = [NSNumber(value: id)] as CFArray
        guard let raw = copy(connection, 0x7, windows)?.takeRetainedValue() as? [NSNumber] else {
            return .failure(.rejected("SLSCopySpacesForWindows returned no membership for \(id)"))
        }
        return .success(raw.map { $0.uint64Value })
    }

    /// Submits the bridged operation. Acceptance is not success: the manager must poll
    /// `membership(forWindow:)` and verify the requested normal Space within its retry bound.
    static func submitMove(_ windowIDs: [UInt32],
                           toNormalSpace spaceID: UInt64) -> Result<Void, SkyLightFailure> {
        let capability = runtimeCapabilities.movement
        guard capability.isAvailable, !windowIDs.isEmpty, spaceID != 0,
              let moveClass = moveClass else {
            return .failure(.unavailable(reason(capability)))
        }
        let type = unsafeBitCast(moveClass, to: BridgedMoveOperation.Type.self)
        let operation = type.init(windows: windowIDs.map { NSNumber(value: $0) },
                                  spaceID: spaceID)
        operation.performWithWMBridgeDelegate()
        return .success(())
    }

    private static func reason(_ capability: CapabilityAvailability) -> String {
        if case .unavailable(let reason) = capability { return reason }
        return "capability unavailable"
    }
}
