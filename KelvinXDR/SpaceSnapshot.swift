//
//  SpaceSnapshot.swift
//  KelvinXDR
//
//  Persistent normal-Space layouts and the pure topology state that selects them. This file
//  deliberately contains no SkyLight, Accessibility, WindowServer, or AppKit UI calls.
//

import Foundation
import CoreGraphics

/// The set of physical displays selects a docked/undocked profile.
struct PhysicalTopologyID: RawRepresentable, Hashable, Codable, CustomStringConvertible {
    var rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// SkyLight's opaque `Display Identifier` selects one Mission Control Space row.
struct ManagedSpaceDomainID: RawRepresentable, Hashable, Codable, CustomStringConvertible {
    static let main = ManagedSpaceDomainID("Main")

    var rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DisplayTopology {
    static let none = PhysicalTopologyID("none")

    static func fingerprint(_ displayUUIDs: [String]) -> PhysicalTopologyID {
        let uuids = displayUUIDs.filter { !$0.isEmpty }.sorted()
        return uuids.isEmpty ? none : PhysicalTopologyID(uuids.joined(separator: "+"))
    }
}

/// Commits only non-empty physical topology samples.
struct TopologyGate {
    private(set) var fingerprint: PhysicalTopologyID

    init(fingerprint: PhysicalTopologyID = PhysicalTopologyID("")) {
        self.fingerprint = fingerprint
    }

    mutating func noticed(_ next: PhysicalTopologyID) -> Bool {
        guard next != DisplayTopology.none, next != fingerprint else { return false }
        fingerprint = next
        return true
    }
}

/// Token-based debounce state. A re-arm invalidates the previous token; disabling invalidates
/// every outstanding token immediately. The manager re-samples topology only after accepting
/// the newest token.
struct TopologyDebouncer {
    private(set) var enabled: Bool
    private var generation = 0
    private var pending: Int?

    init(enabled: Bool) { self.enabled = enabled }

    mutating func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            generation += 1
            pending = nil
        }
    }

    mutating func schedule() -> Int? {
        guard enabled else { return nil }
        generation += 1
        pending = generation
        return generation
    }

    func accept(_ token: Int) -> Bool { enabled && pending == token }

    mutating func consume(_ token: Int) -> Bool {
        guard accept(token) else { return false }
        pending = nil
        return true
    }
}

/// Pure overlap policy for save/restore/conversion. A topology change arriving during an
/// operation is remembered and re-evaluated exactly once when the operation finishes.
struct LayoutOperationCoordinator {
    private(set) var isBusy = false
    private(set) var hasPendingTopology = false

    mutating func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    mutating func noteTopologyChange() {
        if isBusy { hasPendingTopology = true }
    }

    mutating func cancelPendingTopology() { hasPendingTopology = false }

    mutating func finish(automaticRestoreEnabled: Bool) -> Bool {
        isBusy = false
        let shouldReevaluate = hasPendingTopology && automaticRestoreEnabled
        hasPendingTopology = false
        return shouldReevaluate
    }
}

/// A frame normalized into a display's visible frame. Each topology has its own snapshot, and
/// this representation also survives resolution, menu-bar, and Dock-size changes within it.
struct RelativeWindowFrame: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

/// One normal-Space arrangement. Native fullscreen/type-4 order is intentionally absent.
struct SpaceSnapshot: Codable, Equatable {
    static let currentSchema = 4

    var schemaVersion = SpaceSnapshot.currentSchema
    var topologyID: PhysicalTopologyID
    var savedAt: Date
    var displays: [Display]

    struct Display: Codable, Equatable {
        /// SkyLight's opaque `Display Identifier` (`Main` in shared-domain mode).
        var managedDisplayID: ManagedSpaceDomainID
        /// Mapping captured while separate Spaces are enabled. nil for the shared `Main` row.
        var physicalDisplayUUID: String?
        var spaces: [Space]
        var displayName: String?

        init(managedDisplayID: ManagedSpaceDomainID, physicalDisplayUUID: String?,
             spaces: [Space], displayName: String? = nil) {
            self.managedDisplayID = managedDisplayID
            self.physicalDisplayUUID = physicalDisplayUUID
            self.spaces = spaces
            self.displayName = displayName
        }

        private enum CodingKeys: String, CodingKey {
            case managedDisplayID, physicalDisplayUUID, spaces, displayName
            case legacyDisplayUUID = "displayUUID"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let current = try container.decodeIfPresent(ManagedSpaceDomainID.self,
                                                            forKey: .managedDisplayID) {
                managedDisplayID = current
            } else {
                managedDisplayID = ManagedSpaceDomainID(
                    try container.decode(String.self, forKey: .legacyDisplayUUID))
            }
            physicalDisplayUUID = try container.decodeIfPresent(String.self,
                                                                  forKey: .physicalDisplayUUID)
            if physicalDisplayUUID == nil, managedDisplayID != .main {
                // Schemas 1...3 casually equated these identities. Preserve the measured
                // mapping as a migration hint without carrying that assumption forward.
                physicalDisplayUUID = managedDisplayID.rawValue
            }
            spaces = try container.decode([Space].self, forKey: .spaces)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            // A legacy `fullscreen` key is deliberately ignored. It is historical evidence,
            // never an instruction to rebuild type-4 Spaces.
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(managedDisplayID, forKey: .managedDisplayID)
            try container.encodeIfPresent(physicalDisplayUUID, forKey: .physicalDisplayUUID)
            try container.encode(spaces, forKey: .spaces)
            try container.encodeIfPresent(displayName, forKey: .displayName)
        }
    }

    struct Space: Codable, Equatable {
        /// Diagnostic/stability hint only. `logicalIndex` is authoritative during restore.
        var spaceUUID: String
        var logicalIndex: Int
        var windows: [Window]
    }

    struct Window: Codable, Equatable {
        var windowID: UInt32
        var pid: Int32
        var bundleID: String?
        var ownerName: String
        var title: String?
        var documentIdentity: String?
        /// Last normal frame in Accessibility/CoreGraphics top-left coordinates.
        var frame: CGRect
        var relativeFrame: RelativeWindowFrame?
        var isMaximized: Bool
        /// Usable normal frame to fall back to after conversion or failed geometry.
        var restorationFrame: CGRect?

        init(windowID: UInt32, pid: Int32, bundleID: String?, ownerName: String,
             title: String?, documentIdentity: String? = nil, frame: CGRect,
             relativeFrame: RelativeWindowFrame? = nil, isMaximized: Bool = false,
             restorationFrame: CGRect? = nil) {
            self.windowID = windowID
            self.pid = pid
            self.bundleID = bundleID
            self.ownerName = ownerName
            self.title = title
            self.documentIdentity = documentIdentity
            self.frame = frame
            self.relativeFrame = relativeFrame
            self.isMaximized = isMaximized
            self.restorationFrame = restorationFrame
        }

        private enum CodingKeys: String, CodingKey {
            case windowID, pid, bundleID, ownerName, title, documentIdentity, frame
            case relativeFrame, isMaximized, restorationFrame
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            windowID = try container.decode(UInt32.self, forKey: .windowID)
            pid = try container.decode(Int32.self, forKey: .pid)
            bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
            ownerName = try container.decode(String.self, forKey: .ownerName)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            documentIdentity = try container.decodeIfPresent(String.self, forKey: .documentIdentity)
            frame = try container.decode(CGRect.self, forKey: .frame)
            relativeFrame = try container.decodeIfPresent(RelativeWindowFrame.self,
                                                            forKey: .relativeFrame)
            isMaximized = try container.decodeIfPresent(Bool.self, forKey: .isMaximized) ?? false
            restorationFrame = try container.decodeIfPresent(CGRect.self,
                                                               forKey: .restorationFrame)
        }
    }

    var setupDescription: String {
        let names = displays.map { $0.displayName ?? "Unknown display" }
        guard !names.isEmpty else { return "No displays" }
        if names.count == 1 { return names[0] + " only" }
        return names.joined(separator: " + ")
    }

    var spaceCount: Int { displays.reduce(0) { $0 + $1.spaces.count } }
    var windowCount: Int {
        displays.reduce(0) { $0 + $1.spaces.reduce(0) { $0 + $1.windows.count } }
    }

    /// Session content identity for bounded history deduplication. Titles and geometry are
    /// intentionally omitted because AX can reveal them intermittently.
    var signature: String {
        displays.map { display in
            let spaces = display.spaces.map { space in
                let windows = space.windows.map {
                    ($0.bundleID ?? $0.ownerName) + "#\($0.windowID)"
                }.sorted().joined(separator: ",")
                return "\(space.logicalIndex):" + windows
            }.joined(separator: ";")
            return display.managedDisplayID.rawValue + "[" + spaces + "]"
        }.sorted().joined(separator: "/")
    }
}

struct LayoutFile: Codable {
    var schemaVersion = SpaceSnapshot.currentSchema
    var topologyID: PhysicalTopologyID
    var selected: String?
    var auto: [SpaceSnapshot] = []
    var profiles: [Profile] = []

    struct Profile: Codable, Equatable {
        var name: String
        var snapshot: SpaceSnapshot
    }

    var active: SpaceSnapshot? {
        if let selected = selected,
           let profile = profiles.first(where: { $0.name == selected }) {
            return profile.snapshot
        }
        return auto.first
    }

    var activeName: String { selected ?? "Auto-saved" }
}

/// Immutable settings-window view data. Mutations go back through SpaceLayoutManager so the
/// window never races background profile work with its own file read-modify-write cycle.
struct SpaceProfileCatalog: Equatable {
    struct Profile: Equatable {
        var name: String
        var spaceCount: Int
        var windowCount: Int
    }

    struct Setup: Equatable {
        var topologyID: PhysicalTopologyID
        var description: String
        var isConnected: Bool
        var selectedName: String?
        var autoSavedAt: Date?
        var profiles: [Profile]
    }

    var setups: [Setup]
}

/// A dedicated serialized store. Settings and background restoration never perform competing
/// read-modify-write cycles against the same file.
final class SnapshotStore {
    let directory: URL
    var autoLimit: Int
    private let lock = NSRecursiveLock()

    static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KelvinXDR/SpaceLayouts", isDirectory: true)

    init(directory: URL, autoLimit: Int = 5) {
        self.directory = directory
        self.autoLimit = autoLimit
    }

    func url(for topologyID: PhysicalTopologyID) -> URL {
        let safe = topologyID.rawValue.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    func load(_ topologyID: PhysicalTopologyID) -> LayoutFile {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked(topologyID)
    }

    private func loadUnlocked(_ topologyID: PhysicalTopologyID) -> LayoutFile {
        guard let data = try? Data(contentsOf: url(for: topologyID)) else {
            return LayoutFile(topologyID: topologyID, selected: nil)
        }
        if var file = try? JSONDecoder.snapshots.decode(LayoutFile.self, from: data),
           file.schemaVersion <= SpaceSnapshot.currentSchema {
            file.auto.removeAll { $0.schemaVersion > SpaceSnapshot.currentSchema }
            file.profiles.removeAll { $0.snapshot.schemaVersion > SpaceSnapshot.currentSchema }
            if let selected = file.selected,
               !file.profiles.contains(where: { $0.name == selected }) {
                file.selected = nil
            }
            return file
        }
        // Schemas 1...3 stored a bare snapshot array. Unknown `fullscreen` keys decode but are
        // discarded by `SpaceSnapshot.Display`.
        if let legacy = try? JSONDecoder.snapshots.decode([SpaceSnapshot].self, from: data) {
            return LayoutFile(topologyID: topologyID, selected: nil,
                              auto: legacy.filter { $0.schemaVersion <= SpaceSnapshot.currentSchema })
        }
        return LayoutFile(topologyID: topologyID, selected: nil)
    }

    private func writeUnlocked(_ file: LayoutFile) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.snapshots.encode(file) else { return }
        try? data.write(to: url(for: file.topologyID), options: .atomic)
    }

    private func mutate(_ topologyID: PhysicalTopologyID, _ body: (inout LayoutFile) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var file = loadUnlocked(topologyID)
        body(&file)
        writeUnlocked(file)
    }

    func saveAuto(_ snapshot: SpaceSnapshot) {
        mutate(snapshot.topologyID) { file in
            file.auto.insert(snapshot, at: 0)
            if file.auto.count > autoLimit { file.auto.removeLast(file.auto.count - autoLimit) }
        }
    }

    func saveProfile(named name: String, _ snapshot: SpaceSnapshot) {
        mutate(snapshot.topologyID) { file in
            file.profiles.removeAll { $0.name == name }
            file.profiles.append(LayoutFile.Profile(name: name, snapshot: snapshot))
            file.profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            file.selected = name
        }
    }

    func deleteProfile(named name: String, in topologyID: PhysicalTopologyID) {
        mutate(topologyID) { file in
            file.profiles.removeAll { $0.name == name }
            if file.selected == name { file.selected = nil }
        }
    }

    func renameProfile(_ old: String, to new: String, in topologyID: PhysicalTopologyID) {
        mutate(topologyID) { file in
            guard let index = file.profiles.firstIndex(where: { $0.name == old }) else { return }
            file.profiles[index].name = new
            file.profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if file.selected == old { file.selected = new }
        }
    }

    func select(_ name: String?, in topologyID: PhysicalTopologyID) {
        mutate(topologyID) { $0.selected = name }
    }

    func allTopologies() -> [PhysicalTopologyID] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }.map { PhysicalTopologyID($0.deletingPathExtension().lastPathComponent) }
    }
}

extension JSONEncoder {
    static var snapshots: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var snapshots: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
