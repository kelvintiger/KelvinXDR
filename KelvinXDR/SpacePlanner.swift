//
//  SpacePlanner.swift
//  KelvinXDR
//
//  Pure capability, inventory, matching, conversion, geometry, retry, and restore policy.
//  Runtime adapters translate macOS state into these values and execute the resulting plans.
//

import Foundation
import CoreGraphics

enum CapabilityAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

struct SpaceCapabilities: Equatable {
    var orderedNormalSpaceInventory: CapabilityAvailability
    var windowSpaceMembership: CapabilityAvailability
    var normalSpaceMovement: CapabilityAvailability
    var missingDesktopCreation: CapabilityAvailability
    var accessibilityWindowIdentification: CapabilityAvailability
    var normalWindowGeometry: CapabilityAvailability
    var fullscreenConversion: CapabilityAvailability
    var highQualityTitles: CapabilityAvailability

    static let allAvailable = SpaceCapabilities(
        orderedNormalSpaceInventory: .available,
        windowSpaceMembership: .available,
        normalSpaceMovement: .available,
        missingDesktopCreation: .available,
        accessibilityWindowIdentification: .available,
        normalWindowGeometry: .available,
        fullscreenConversion: .available,
        highQualityTitles: .available)

    var canInventory: Bool {
        orderedNormalSpaceInventory.isAvailable && windowSpaceMembership.isAvailable
    }

    var canSave: Bool { canInventory && accessibilityWindowIdentification.isAvailable }

    var canRestore: Bool {
        canSave && normalSpaceMovement.isAvailable && missingDesktopCreation.isAvailable
            && normalWindowGeometry.isAvailable
    }

    var canConvert: Bool {
        canRestore && fullscreenConversion.isAvailable
    }

    var unavailableReasons: [String] {
        [orderedNormalSpaceInventory, windowSpaceMembership, normalSpaceMovement,
         missingDesktopCreation, accessibilityWindowIdentification, normalWindowGeometry,
         fullscreenConversion].compactMap {
            if case .unavailable(let reason) = $0 { return reason }
            return nil
        }
    }
}

enum PlatformTier: Equatable {
    case primarySequoia
    case expectedSequoia
    case expectedTahoe
    case runtimeOnly
}

enum PlatformPolicy {
    static func tier(major: Int, minor: Int, patch: Int) -> PlatformTier {
        if major == 15, minor == 7, patch == 9 { return .primarySequoia }
        if major == 15, minor == 7 { return .expectedSequoia }
        if major == 26, minor >= 4 { return .expectedTahoe }
        return .runtimeOnly
    }

    /// OS versions are evidence labels, never substitutes for runtime and outcome checks.
    static func hardBlocksWrites(major: Int) -> Bool { false }
}

struct LiveSpaceDescriptor: Equatable {
    var id: UInt64
    var uuid: String
    var type: Int
    var tileWindows: [UInt32]
    var tileAppNames: [String]

    init(id: UInt64, uuid: String, type: Int, tileWindows: [UInt32] = [],
         tileAppNames: [String] = []) {
        self.id = id
        self.uuid = uuid
        self.type = type
        self.tileWindows = tileWindows
        self.tileAppNames = tileAppNames
    }
}

struct LiveSpace: Equatable {
    var id: UInt64
    var uuid: String
}

/// Type-4 evidence is retained only for explicit conversion eligibility and skip diagnostics.
struct LiveFullscreen: Equatable {
    var spaceID: UInt64
    var index: Int
    var tileWindows: [UInt32]
    var tileAppNames: [String]

    init(spaceID: UInt64, index: Int, tileWindows: [UInt32], tileAppNames: [String] = []) {
        self.spaceID = spaceID
        self.index = index
        self.tileWindows = tileWindows
        self.tileAppNames = tileAppNames
    }
}

struct LiveDisplay: Equatable {
    var managedDisplayID: ManagedSpaceDomainID
    var spaces: [LiveSpace]
    var fullscreen: [LiveFullscreen]

    init(managedDisplayID: ManagedSpaceDomainID, spaces: [LiveSpace],
         fullscreen: [LiveFullscreen] = []) {
        self.managedDisplayID = managedDisplayID
        self.spaces = spaces
        self.fullscreen = fullscreen
    }
}

enum ManagedSpaceMode: Equatable {
    case separate
    case sharedMain
    case unavailable

    static func detect(_ displays: [LiveDisplay]) -> ManagedSpaceMode {
        guard !displays.isEmpty else { return .unavailable }
        return displays.contains(where: { $0.managedDisplayID == .main }) ? .sharedMain : .separate
    }
}

struct LiveWindow: Equatable {
    var id: UInt32
    var pid: Int32
    var bundleID: String?
    var ownerName: String
    var title: String?
    var documentIdentity: String?
    var frame: CGRect
    var spaceIDs: [UInt64]
    var isFullscreen: Bool
    var isAXReachable: Bool
    var isStandardWindow: Bool
    var isStageManagerSpecial: Bool
    var canSetFullscreen: Bool
    var canSetPosition: Bool
    var canSetSize: Bool

    init(id: UInt32, pid: Int32, bundleID: String?, ownerName: String, title: String?,
         documentIdentity: String? = nil, frame: CGRect, spaceIDs: [UInt64] = [],
         isFullscreen: Bool = false, isAXReachable: Bool = true,
         isStandardWindow: Bool = true, isStageManagerSpecial: Bool = false,
         canSetFullscreen: Bool = true, canSetPosition: Bool = true,
         canSetSize: Bool = true) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.ownerName = ownerName
        self.title = title
        self.documentIdentity = documentIdentity
        self.frame = frame
        self.spaceIDs = spaceIDs
        self.isFullscreen = isFullscreen
        self.isAXReachable = isAXReachable
        self.isStandardWindow = isStandardWindow
        self.isStageManagerSpecial = isStageManagerSpecial
        self.canSetFullscreen = canSetFullscreen
        self.canSetPosition = canSetPosition
        self.canSetSize = canSetSize
    }

    var singleSpaceID: UInt64? { spaceIDs.count == 1 ? spaceIDs[0] : nil }
}

enum WindowGeometry {
    static func relative(_ frame: CGRect, in visibleFrame: CGRect) -> RelativeWindowFrame {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1)
        }
        return RelativeWindowFrame(
            x: (frame.minX - visibleFrame.minX) / visibleFrame.width,
            y: (frame.minY - visibleFrame.minY) / visibleFrame.height,
            width: frame.width / visibleFrame.width,
            height: frame.height / visibleFrame.height)
    }

    static func absolute(_ relative: RelativeWindowFrame, in visibleFrame: CGRect) -> CGRect {
        let frame = CGRect(
            x: visibleFrame.minX + relative.x * visibleFrame.width,
            y: visibleFrame.minY + relative.y * visibleFrame.height,
            width: relative.width * visibleFrame.width,
            height: relative.height * visibleFrame.height)
        return usable(frame, in: visibleFrame)
    }

    static func usable(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        let width = min(max(frame.width, 120), visibleFrame.width)
        let height = min(max(frame.height, 120), visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func maximizedFrame(in visibleFrame: CGRect) -> CGRect { visibleFrame }

    static func isMaximized(_ frame: CGRect, in visibleFrame: CGRect,
                            tolerance: CGFloat = 2) -> Bool {
        frame.approximatelyEquals(visibleFrame, tolerance: tolerance)
    }

    /// NSScreen uses a bottom-left main-display origin; AX and CGWindow bounds use top-left.
    static func accessibilityFrame(fromCocoa frame: CGRect,
                                   mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainDisplayHeight - frame.maxY,
               width: frame.width, height: frame.height)
    }
}

extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

struct RetryPolicy: Equatable {
    var maxAttempts: Int
    var wallClockBudget: TimeInterval

    func shouldAttempt(number: Int, elapsed: TimeInterval) -> Bool {
        number > 0 && number <= maxAttempts && elapsed <= wallClockBudget
    }
}

struct SpaceWriteCircuit: Equatable {
    let maxVerificationFailures: Int
    private(set) var verificationFailures = 0
    private(set) var isOpen = false

    init(maxVerificationFailures: Int) {
        self.maxVerificationFailures = max(1, maxVerificationFailures)
    }

    mutating func recordVerificationFailure() {
        guard !isOpen else { return }
        verificationFailures += 1
        if verificationFailures >= maxVerificationFailures { isOpen = true }
    }

    mutating func recordVerifiedMove() {
        guard !isOpen else { return }
        verificationFailures = 0
    }
}

enum RestoreBlockReason: Equatable {
    case topologyMismatch
    case sharedSpaceDomain
    case automaticRestoreDisabled
    case missingCapabilities
    case writeCircuitOpen
}

enum RestoreEligibility: Equatable {
    case allowed
    case blocked(RestoreBlockReason)
}

enum SpacePlanner {
    struct Deficit: Equatable {
        var managedDisplayID: ManagedSpaceDomainID
        var count: Int
    }

    struct Move: Equatable {
        var window: UInt32
        var pid: Int32
        var space: UInt64
        var managedDisplayID: ManagedSpaceDomainID
        var presentation: SpaceSnapshot.Window
    }

    struct Plan: Equatable {
        var deficits: [Deficit] = []
        var moves: [Move] = []
        /// Every confidently matched window whose geometry should be restored, including
        /// windows already on the correct normal Space.
        var placements: [Move] = []
        var correct = 0
        var skipped = 0
        var unmatched = 0
        var unreachable = 0

        var isComplete: Bool { moves.isEmpty && deficits.allSatisfy { $0.count == 0 } }

        var summary: String {
            let missing = deficits.reduce(0) { $0 + $1.count }
            return "\(moves.count) move(s), \(missing) desktop(s) to create, "
                + "\(correct) already correct, \(skipped) skipped, "
                + "\(unmatched) unmatched, \(unreachable) unreachable"
        }
    }

    static func inventory(managedDisplayID: ManagedSpaceDomainID,
                          descriptors: [LiveSpaceDescriptor]) -> LiveDisplay {
        var normal: [LiveSpace] = []
        var fullscreen: [LiveFullscreen] = []
        for descriptor in descriptors {
            if descriptor.type == 0 {
                normal.append(LiveSpace(id: descriptor.id, uuid: descriptor.uuid))
            } else if descriptor.type == 4 {
                fullscreen.append(LiveFullscreen(spaceID: descriptor.id,
                                                 index: fullscreen.count,
                                                 tileWindows: descriptor.tileWindows,
                                                 tileAppNames: descriptor.tileAppNames))
            }
        }
        return LiveDisplay(managedDisplayID: managedDisplayID, spaces: normal,
                           fullscreen: fullscreen)
    }

    static func key(_ displayID: ManagedSpaceDomainID, _ logicalIndex: Int) -> String {
        "\(displayID.rawValue)#\(logicalIndex)"
    }

    /// Logical position among type-0 Spaces is authoritative. UUID is deliberately not
    /// consulted: following a surviving reordered UUID preserves the scramble users see.
    static func resolve(_ snapshot: SpaceSnapshot,
                        on displays: [LiveDisplay]) -> [String: UInt64] {
        let byDisplay = Dictionary(displays.map { ($0.managedDisplayID, $0.spaces) },
                                   uniquingKeysWith: { first, _ in first })
        var result: [String: UInt64] = [:]
        for display in snapshot.displays {
            guard let live = byDisplay[display.managedDisplayID] else { continue }
            for space in display.spaces where space.logicalIndex >= 0
                && space.logicalIndex < live.count {
                result[key(display.managedDisplayID, space.logicalIndex)]
                    = live[space.logicalIndex].id
            }
        }
        return result
    }

    static func deficits(_ snapshot: SpaceSnapshot, on displays: [LiveDisplay]) -> [Deficit] {
        let wanted = Dictionary(snapshot.displays.map { ($0.managedDisplayID, $0.spaces.count) },
                                uniquingKeysWith: { first, _ in first })
        return displays.map {
            Deficit(managedDisplayID: $0.managedDisplayID,
                    count: max(0, (wanted[$0.managedDisplayID] ?? 0) - $0.spaces.count))
        }
    }

    private static func appKey(_ bundleID: String?, _ ownerName: String) -> String {
        if let bundleID = bundleID, !bundleID.isEmpty { return "b:" + bundleID }
        return "o:" + ownerName
    }

    private static func appKey(_ window: SpaceSnapshot.Window) -> String {
        appKey(window.bundleID, window.ownerName)
    }

    private static func appKey(_ window: LiveWindow) -> String {
        appKey(window.bundleID, window.ownerName)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY)
            + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func credibleBest(_ candidates: [LiveWindow],
                                     for saved: SpaceSnapshot.Window) -> LiveWindow? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        let ranked = candidates.map { ($0, distance($0.frame, saved.frame)) }
            .sorted { $0.1 < $1.1 }
        guard ranked[0].1 + 0.5 < ranked[1].1 else { return nil }
        return ranked[0].0
    }

    /// Exact session ID; stable document or title evidence; frame only as a tie-breaker;
    /// unique remaining app window. Anything else remains unmatched.
    static func match(_ saved: [SpaceSnapshot.Window],
                      to live: [LiveWindow]) -> [Int: UInt32] {
        let credibleLive = live.filter { $0.isAXReachable && $0.isStandardWindow }
        var matched: [Int: UInt32] = [:]
        var used: Set<UInt32> = []
        var remaining = Array(saved.indices)
        let byID = Dictionary(credibleLive.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })

        func take(_ index: Int, _ window: LiveWindow) {
            matched[index] = window.id
            used.insert(window.id)
        }

        remaining.removeAll { index in
            guard let candidate = byID[saved[index].windowID], !used.contains(candidate.id),
                  appKey(candidate) == appKey(saved[index]) else { return false }
            take(index, candidate)
            return true
        }

        remaining.removeAll { index in
            let wanted = saved[index]
            guard let document = wanted.documentIdentity, !document.isEmpty else { return false }
            let candidates = credibleLive.filter {
                !used.contains($0.id) && appKey($0) == appKey(wanted)
                    && $0.documentIdentity == document
            }
            guard let best = credibleBest(candidates, for: wanted) else { return false }
            take(index, best)
            return true
        }

        remaining.removeAll { index in
            let wanted = saved[index]
            guard let title = wanted.title, !title.isEmpty else { return false }
            let candidates = credibleLive.filter {
                !used.contains($0.id) && appKey($0) == appKey(wanted) && $0.title == title
            }
            guard let best = credibleBest(candidates, for: wanted) else { return false }
            take(index, best)
            return true
        }

        for index in remaining {
            let wanted = saved[index]
            let peers = remaining.filter { appKey(saved[$0]) == appKey(wanted) }
            let candidates = credibleLive.filter {
                !used.contains($0.id) && appKey($0) == appKey(wanted)
            }
            guard peers.count == 1, candidates.count == 1 else { continue }
            take(index, candidates[0])
        }
        return matched
    }

    static func plan(_ snapshot: SpaceSnapshot, displays: [LiveDisplay],
                     windows: [LiveWindow], leaveAlone: Set<UInt32> = []) -> Plan {
        var plan = Plan()
        plan.deficits = deficits(snapshot, on: displays)
        let resolved = resolve(snapshot, on: displays)

        var savedWindows: [SpaceSnapshot.Window] = []
        var targets: [(UInt64, ManagedSpaceDomainID)] = []
        for display in snapshot.displays {
            for space in display.spaces {
                guard let target = resolved[key(display.managedDisplayID, space.logicalIndex)] else {
                    plan.unreachable += space.windows.count
                    continue
                }
                for window in space.windows {
                    savedWindows.append(window)
                    targets.append((target, display.managedDisplayID))
                }
            }
        }

        let matched = match(savedWindows, to: windows)
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in savedWindows.indices {
            guard let liveID = matched[index], let live = byID[liveID] else {
                plan.unmatched += 1
                continue
            }
            if live.spaceIDs.count != 1 { plan.skipped += 1; continue }
            if leaveAlone.contains(liveID) { plan.skipped += 1; continue }
            let placement = Move(window: liveID, pid: live.pid, space: targets[index].0,
                                 managedDisplayID: targets[index].1,
                                 presentation: savedWindows[index])
            plan.placements.append(placement)
            if live.singleSpaceID == targets[index].0 { plan.correct += 1; continue }
            plan.moves.append(placement)
        }
        return plan
    }

    static func restoreEligibility(snapshotTopology: PhysicalTopologyID,
                                   currentTopology: PhysicalTopologyID,
                                   mode: ManagedSpaceMode, automaticEnabled: Bool,
                                   capabilities: SpaceCapabilities,
                                   circuitOpen: Bool) -> RestoreEligibility {
        guard snapshotTopology == currentTopology else { return .blocked(.topologyMismatch) }
        guard mode != .sharedMain else { return .blocked(.sharedSpaceDomain) }
        guard automaticEnabled else { return .blocked(.automaticRestoreDisabled) }
        guard capabilities.canRestore else { return .blocked(.missingCapabilities) }
        guard !circuitOpen else { return .blocked(.writeCircuitOpen) }
        return .allowed
    }

    enum ConversionSkipReason: String, Hashable {
        case missingCapabilities
        case sharedSpaceDomain
        case splitView
        case ambiguousOccupant
        case inaccessible
        case panel
        case stageManager
        case allDesktops
        case unsupportedApp
        case geometryUnavailable
    }

    struct ConversionSkip: Equatable {
        var window: UInt32?
        var reason: ConversionSkipReason
    }

    struct ConversionCandidate: Equatable {
        var window: UInt32
        var pid: Int32
        var managedDisplayID: ManagedSpaceDomainID
        var targetLogicalIndex: Int
        var restorationFrame: CGRect
    }

    enum ConversionAction: Equatable {
        case createDesktops([Deficit])
        case convert(ConversionCandidate)
    }

    struct ConversionPlan: Equatable {
        var deficits: [Deficit] = []
        var candidates: [ConversionCandidate] = []
        var skipped: [ConversionSkip] = []
        var actions: [ConversionAction] = []
    }

    static func conversionPlan(displays: [LiveDisplay], windows: [LiveWindow],
                               capabilities: SpaceCapabilities) -> ConversionPlan {
        var plan = ConversionPlan()
        let mode = ManagedSpaceMode.detect(displays)
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if mode == .sharedMain {
            for display in displays {
                for space in display.fullscreen {
                    plan.skipped.append(ConversionSkip(window: space.tileWindows.first,
                                                       reason: .sharedSpaceDomain))
                }
            }
            return plan
        }

        if !capabilities.canConvert {
            for display in displays {
                for space in display.fullscreen {
                    plan.skipped.append(ConversionSkip(window: space.tileWindows.first,
                                                       reason: .missingCapabilities))
                }
            }
            return plan
        }

        for display in displays {
            let start = display.spaces.count
            var eligibleOnDisplay = 0
            for space in display.fullscreen {
                guard space.tileWindows.count == 1 else {
                    plan.skipped.append(ConversionSkip(
                        window: space.tileWindows.first,
                        reason: space.tileWindows.count > 1 ? .splitView : .ambiguousOccupant))
                    continue
                }
                let id = space.tileWindows[0]
                guard let window = byID[id] else {
                    plan.skipped.append(ConversionSkip(window: id, reason: .inaccessible)); continue
                }
                guard window.spaceIDs.count == 1 else {
                    plan.skipped.append(ConversionSkip(window: id, reason: .allDesktops)); continue
                }
                guard window.isStandardWindow else {
                    plan.skipped.append(ConversionSkip(window: id, reason: .panel)); continue
                }
                guard !window.isStageManagerSpecial else {
                    plan.skipped.append(ConversionSkip(window: id, reason: .stageManager)); continue
                }
                guard window.isAXReachable else {
                    plan.skipped.append(ConversionSkip(window: id, reason: .inaccessible)); continue
                }
                guard window.isFullscreen, window.canSetFullscreen else {
                    plan.skipped.append(ConversionSkip(window: id, reason: .unsupportedApp)); continue
                }
                guard window.canSetPosition, window.canSetSize else {
                    plan.skipped.append(ConversionSkip(window: id, reason: .geometryUnavailable)); continue
                }

                plan.candidates.append(ConversionCandidate(
                    window: id, pid: window.pid, managedDisplayID: display.managedDisplayID,
                    targetLogicalIndex: start + eligibleOnDisplay,
                    restorationFrame: window.frame))
                eligibleOnDisplay += 1
            }
            // Preserve one entry per managed-display row, including zero deficits. The Dock
            // AX adapter addresses `mc.display` rows by this inventory position; compacting
            // the array would create desktops on the wrong display whenever an earlier row
            // has no eligible conversion candidate.
            plan.deficits.append(Deficit(managedDisplayID: display.managedDisplayID,
                                         count: eligibleOnDisplay))
        }

        if plan.deficits.contains(where: { $0.count > 0 }) {
            plan.actions.append(.createDesktops(plan.deficits))
        }
        plan.actions.append(contentsOf: plan.candidates.map { .convert($0) })
        return plan
    }
}
