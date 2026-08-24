//
//  SpaceLayoutManager.swift
//  KelvinXDR
//
//  Serialized policy for manual capture/restore/conversion and separately opt-in automatic
//  restoration. Runtime operations live behind narrow adapters; all planning stays pure.
//

import Cocoa

private enum LayoutOperationFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

final class SpaceLayoutManager {
    static let automaticRestoreKey = "AutomaticallyRestoreSpaceLayouts"

    private enum Operation: String {
        case saving = "saving"
        case restoring = "restoring"
        case converting = "converting"
    }

    private struct LiveState {
        var displays: [LiveDisplay]
        var windows: [LiveWindow]
        var mode: ManagedSpaceMode
        var geometryByDomain: [ManagedSpaceDomainID: PhysicalDisplayGeometry]
    }

    private let debounceDelay: TimeInterval = 2.5
    private let moveRetry = RetryPolicy(maxAttempts: 3, wallClockBudget: 8)
    private let geometryRetry = RetryPolicy(maxAttempts: 3, wallClockBudget: 5)
    private let store: SnapshotStore
    private let queue = DispatchQueue(label: "KelvinXDR.spaces", qos: .utility)

    private var topologyGate = TopologyGate()
    private var debouncer = TopologyDebouncer(enabled: false)
    private var pendingRestore: DispatchWorkItem?
    private var operationCoordinator = LayoutOperationCoordinator()
    private var writeCircuit = SpaceWriteCircuit(maxVerificationFailures: 3)
    private var convertedRestorationFrames: [UInt32: CGRect] = [:]

    private(set) var isOperating = false
    private(set) var writesDisabledForSession = false
    private(set) var detectedMode: ManagedSpaceMode = .unavailable
    var onChange: (() -> Void)?

    init(store: SnapshotStore = SnapshotStore(directory: SnapshotStore.defaultDirectory)) {
        self.store = store
    }

    // MARK: - Capabilities and preference

    var capabilities: SpaceCapabilities {
        let sky = SkyLightSpaces.runtimeCapabilities
        let ax = WindowAccessibility.runtimeCapabilities
        return SpaceCapabilities(
            orderedNormalSpaceInventory: sky.orderedInventory,
            windowSpaceMembership: sky.membership,
            normalSpaceMovement: sky.movement,
            missingDesktopCreation: MissionControlDesktopCreator.capability,
            accessibilityWindowIdentification: ax.identification,
            normalWindowGeometry: ax.geometry,
            fullscreenConversion: ax.conversion,
            highQualityTitles: ax.highQualityTitles)
    }

    var automaticRestoreEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.automaticRestoreKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticRestoreKey)
            debouncer.setEnabled(newValue)
            if !newValue {
                pendingRestore?.cancel()
                pendingRestore = nil
                operationCoordinator.cancelPendingTopology()
            }
            log(newValue ? "automatic restoration enabled" : "automatic restoration disabled")
            onChange?()
        }
    }

    var capabilityStatusText: String? {
        if writesDisabledForSession {
            return "Space writes disabled for this session after verification failures"
        }
        if detectedMode == .sharedMain {
            return "Per-display restoration unavailable while Spaces use the shared Main row"
        }
        let caps = capabilities
        if !caps.canInventory { return caps.unavailableReasons.first ?? "Space inventory unavailable" }
        if !caps.canRestore { return caps.unavailableReasons.first ?? "Space restoration unavailable" }
        return nil
    }

    var canSave: Bool {
        capabilities.canSave && !isOperating && detectedMode != .sharedMain
    }
    var canRestore: Bool {
        capabilities.canRestore && !isOperating && !writesDisabledForSession
            && detectedMode != .sharedMain
    }
    var canConvert: Bool {
        capabilities.canConvert && !isOperating && !writesDisabledForSession
            && detectedMode != .sharedMain
    }

    var hasSavedLayout: Bool {
        topologyGate.fingerprint != DisplayTopology.none
            && store.load(topologyGate.fingerprint).active != nil
    }

    var currentTopologyID: PhysicalTopologyID { topologyGate.fingerprint }

    func start() {
        topologyGate = TopologyGate(fingerprint: Self.currentTopology())
        debouncer = TopologyDebouncer(enabled: automaticRestoreEnabled)
        let caps = capabilities
        if !caps.canInventory { log("inventory unavailable: \(caps.unavailableReasons.joined(separator: "; "))") }
        queue.async { [weak self] in
            guard let self = self else { return }
            if case .success(let displays) = SkyLightSpaces.inventory() {
                self.publishMode(ManagedSpaceMode.detect(displays))
            }
        }
    }

    // MARK: - Physical topology and debounce

    static func currentTopology() -> PhysicalTopologyID {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return DisplayTopology.none
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return DisplayTopology.none
        }
        let uuids = ids.prefix(Int(count)).compactMap { id -> String? in
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            else { return nil }
            return CFUUIDCreateString(nil, uuid) as String
        }
        return DisplayTopology.fingerprint(Array(uuids))
    }

    /// Notifications only re-arm the timer. The topology is sampled after debounce, never
    /// trusted from notification time.
    func screenParametersChanged() {
        guard automaticRestoreEnabled else { return }
        scheduleAutomaticEvaluation(after: debounceDelay)
    }

    private func scheduleAutomaticEvaluation(after delay: TimeInterval) {
        guard let token = debouncer.schedule() else { return }
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.automaticDebounceFired(token) }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func automaticDebounceFired(_ token: Int) {
        guard debouncer.consume(token), automaticRestoreEnabled else { return }
        let sampled = Self.currentTopology()
        if sampled == DisplayTopology.none {
            // Transient clamshell/sleep reading. Re-sample after a fresh debounce period.
            scheduleAutomaticEvaluation(after: debounceDelay)
            return
        }
        guard topologyGate.noticed(sampled) else { return }
        onChange?()
        if isOperating {
            operationCoordinator.noteTopologyChange()
            return
        }
        restoreSaved(reason: "display topology change", automatic: true)
    }

    // MARK: - Manual save and profiles

    func saveCurrentLayout() {
        guard capabilities.canSave else {
            return log("save unavailable: \(capabilities.unavailableReasons.joined(separator: "; "))")
        }
        guard begin(.saving) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            switch self.captureSnapshot() {
            case .success(let snapshot):
                self.store.saveAuto(snapshot)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "SpacesLastSaved")
                self.finish("Saved \(snapshot.spaceCount) normal desktop(s) and "
                            + "\(snapshot.windowCount) normal window(s)")
            case .failure(let error): self.finish("Save failed: \(error)", alert: true)
            }
        }
    }

    func saveProfile(named name: String, completion: (() -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion?(); return }
        guard capabilities.canSave, begin(.saving) else { completion?(); return }
        queue.async { [weak self] in
            guard let self = self else { return }
            switch self.captureSnapshot() {
            case .success(let snapshot):
                self.store.saveProfile(named: trimmed, snapshot)
                self.finish("Saved profile “\(trimmed)”", completion: completion)
            case .failure(let error):
                self.finish("Profile save failed: \(error)", alert: true, completion: completion)
            }
        }
    }

    func profileCatalog() -> SpaceProfileCatalog {
        let current = topologyGate.fingerprint
        let setups = store.allTopologies().map { topology -> SpaceProfileCatalog.Setup in
            let file = store.load(topology)
            let representative = file.active ?? file.auto.first ?? file.profiles.first?.snapshot
            let description = representative?.setupDescription
                ?? "\(topology.rawValue.components(separatedBy: "+").count) display(s)"
            return SpaceProfileCatalog.Setup(
                topologyID: topology, description: description, isConnected: topology == current,
                selectedName: file.selected, autoSavedAt: file.auto.first?.savedAt,
                profiles: file.profiles.map {
                    SpaceProfileCatalog.Profile(name: $0.name,
                                                spaceCount: $0.snapshot.spaceCount,
                                                windowCount: $0.snapshot.windowCount)
                })
        }
        return SpaceProfileCatalog(setups: setups)
    }

    func selectProfile(_ name: String?, in topology: PhysicalTopologyID,
                       completion: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.store.select(name, in: topology)
            DispatchQueue.main.async { self?.onChange?(); completion() }
        }
    }

    func renameProfile(_ old: String, to new: String, in topology: PhysicalTopologyID,
                       completion: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.store.renameProfile(old, to: new, in: topology)
            DispatchQueue.main.async { self?.onChange?(); completion() }
        }
    }

    func deleteProfile(_ name: String, in topology: PhysicalTopologyID,
                       completion: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.store.deleteProfile(named: name, in: topology)
            DispatchQueue.main.async { self?.onChange?(); completion() }
        }
    }

    // MARK: - Restore

    func restoreCurrentLayout() { restoreSaved(reason: "manual menu action", automatic: false) }

    func restoreProfile(named name: String?, in topology: PhysicalTopologyID) {
        guard topology == Self.currentTopology() else {
            return showSummary("That profile belongs to a physical display setup that is not connected.")
        }
        let file = store.load(topology)
        let snapshot = name.flatMap { selected in
            file.profiles.first(where: { $0.name == selected })?.snapshot
        } ?? file.auto.first
        guard let snapshot = snapshot else { return showSummary("Nothing is saved under that profile.") }
        startRestore(snapshot, reason: "Settings profile", automatic: false)
    }

    private func restoreSaved(reason: String, automatic: Bool) {
        if automatic, !automaticRestoreEnabled { return }
        let topology = Self.currentTopology()
        guard topology != DisplayTopology.none,
              let snapshot = store.load(topology).active else {
            if !automatic { showSummary("No normal-Space layout is saved for this display setup.") }
            return
        }
        startRestore(snapshot, reason: reason, automatic: automatic)
    }

    private func startRestore(_ snapshot: SpaceSnapshot, reason: String, automatic: Bool) {
        guard capabilities.canRestore, !writesDisabledForSession else {
            if !automatic { showSummary(capabilityStatusText ?? "Space restoration is unavailable.") }
            return
        }
        guard begin(.restoring) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let summary = self.runRestore(snapshot, reason: reason, automatic: automatic)
            self.finish(summary, alert: !automatic && summary.lowercased().contains("failed"))
        }
    }

    private func runRestore(_ snapshot: SpaceSnapshot, reason: String,
                            automatic: Bool) -> String {
        if automatic, !automaticRestoreEnabled { return "Automatic restore cancelled before acting" }
        guard Self.currentTopology() == snapshot.topologyID else {
            return "Restore failed: physical topology no longer matches the profile"
        }
        guard case .success(var state) = readLiveState() else {
            return "Restore failed: current Space/window inventory is unavailable"
        }
        publishMode(state.mode)
        let eligibility = SpacePlanner.restoreEligibility(
            snapshotTopology: snapshot.topologyID, currentTopology: Self.currentTopology(),
            mode: state.mode, automaticEnabled: automatic ? automaticRestoreEnabled : true,
            capabilities: capabilities, circuitOpen: writeCircuit.isOpen)
        guard eligibility == .allowed else { return "Restore failed: \(eligibility)" }

        var plan = SpacePlanner.plan(snapshot, displays: state.displays, windows: state.windows)
        if plan.deficits.contains(where: { $0.count > 0 }) {
            let creation = MissionControlDesktopCreator.create(plan.deficits)
            guard creation.succeeded else {
                return "Restore failed before moving windows: created \(creation.created)/"
                    + "\(creation.requested) desktops; "
                    + creation.failures.map(\.description).joined(separator: "; ")
            }
            guard case .success(let refreshed) = readLiveState() else {
                return "Restore failed: could not verify created desktops"
            }
            state = refreshed
            plan = SpacePlanner.plan(snapshot, displays: state.displays, windows: state.windows)
            guard plan.deficits.allSatisfy({ $0.count == 0 }) else {
                return "Restore failed: desktop creation did not produce the required normal slots"
            }
        }

        let moveIDs = Set(plan.moves.map { $0.window })
        var moved = 0
        var framed = 0
        var failures: [String] = []
        for placement in plan.placements {
            if automatic, !automaticRestoreEnabled {
                failures.append("automatic restoration was disabled")
                break
            }
            guard Self.currentTopology() == snapshot.topologyID else {
                failures.append("physical topology changed during restore")
                break
            }
            guard capabilities.canRestore else {
                failures.append("required runtime capability disappeared")
                break
            }
            guard !writeCircuit.isOpen else {
                failures.append("Space-write circuit is open")
                break
            }
            if moveIDs.contains(placement.window) {
                if verifyMove(window: placement.window, to: placement.space) {
                    moved += 1
                } else {
                    failures.append("window \(placement.window) did not verify on Space \(placement.space)")
                    continue
                }
            }
            guard let geometry = state.geometryByDomain[placement.managedDisplayID] else {
                failures.append("no physical display mapping for \(placement.managedDisplayID.rawValue)")
                continue
            }
            let target = targetFrame(placement.presentation, visibleFrame: geometry.visibleFrame)
            if verifyFrame(pid: placement.pid, window: placement.window, target: target) {
                framed += 1
            } else {
                failures.append("window \(placement.window) geometry did not verify")
            }
        }

        let base = "\(reason): moved \(moved), restored geometry for \(framed), "
            + "\(plan.correct) already on the right normal Space, \(plan.unmatched) unmatched"
        return failures.isEmpty ? base : "Restore failed partially — " + base
            + "; " + failures.joined(separator: "; ")
    }

    // MARK: - Explicit fullscreen conversion

    func convertFullscreenApps() {
        guard capabilities.canConvert, !writesDisabledForSession else {
            return showSummary(capabilityStatusText ?? "Fullscreen conversion is unavailable.")
        }
        guard begin(.converting) else { return }
        queue.async { [weak self] in self?.prepareConversionConfirmation() }
    }

    private func prepareConversionConfirmation() {
        guard case .success(let state) = readLiveState() else {
            return finish("Conversion preparation failed: inventory unavailable", alert: true)
        }
        publishMode(state.mode)
        let plan = SpacePlanner.conversionPlan(displays: state.displays, windows: state.windows,
                                               capabilities: capabilities)
        guard !plan.candidates.isEmpty else {
            return finish("No confidently eligible single-window fullscreen apps were found. "
                          + "Skipped \(plan.skipped.count).", alert: true)
        }

        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Convert Fullscreen Apps to Dedicated Desktops?"
            alert.informativeText = "\(plan.candidates.count) eligible app(s) will visibly leave "
                + "native fullscreen, move to newly created normal desktops, and become maximized "
                + "normal windows. Split View, tiled, ambiguous, and unsupported windows are skipped."
            alert.addButton(withTitle: "Convert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                self.finish("Fullscreen conversion cancelled")
                return
            }
            // Re-read and re-plan after the confirmation so no stale candidate is mutated.
            self.queue.async { [weak self] in
                self?.executeConversion(returningFocusTo: previousFrontmost)
            }
        }
    }

    private func executeConversion(returningFocusTo previousFrontmost: NSRunningApplication?) {
        guard Self.currentTopology() != DisplayTopology.none,
              case .success(var state) = readLiveState() else {
            return finish("Conversion failed before acting: inventory unavailable", alert: true)
        }
        let topology = Self.currentTopology()
        let plan = SpacePlanner.conversionPlan(displays: state.displays, windows: state.windows,
                                               capabilities: capabilities)
        guard !plan.candidates.isEmpty else {
            return finish("Conversion stopped: eligible windows changed before confirmation", alert: true)
        }

        // This is the safety boundary: every desktop exists and is verified before the first
        // AXFullScreen write destroys a type-4 Space.
        let creation = MissionControlDesktopCreator.create(
            plan.deficits, returningFocusTo: previousFrontmost)
        guard creation.succeeded, case .success(let refreshed) = readLiveState() else {
            return finish("Conversion stopped before exiting fullscreen: created "
                          + "\(creation.created)/\(creation.requested) desktops; "
                          + creation.failures.map(\.description).joined(separator: "; "), alert: true)
        }
        state = refreshed
        let displayCounts = Dictionary(state.displays.map { ($0.managedDisplayID, $0.spaces.count) },
                                       uniquingKeysWith: { first, _ in first })
        guard plan.candidates.allSatisfy({
            (displayCounts[$0.managedDisplayID] ?? 0) > $0.targetLogicalIndex
        }) else {
            return finish("Conversion stopped before exiting fullscreen: new normal desktops "
                          + "could not be verified", alert: true)
        }

        var converted = 0
        var failed: [String] = []
        for candidate in plan.candidates {
            guard Self.currentTopology() == topology, !writeCircuit.isOpen,
                  capabilities.canConvert else {
                failed.append("runtime state changed; remaining windows were left untouched")
                break
            }
            guard let original = state.windows.first(where: { $0.id == candidate.window }) else {
                failed.append("window \(candidate.window) disappeared")
                continue
            }
            let identity = snapshotWindow(from: original, geometry: nil, restorationFrame: nil)
            guard case .success = WindowAccessibility.exitFullscreen(
                    pid: candidate.pid, windowID: candidate.window) else {
                failed.append("window \(candidate.window) refused to leave fullscreen")
                continue
            }
            guard let normal = waitForNormalWindow(identity) else {
                failed.append("window \(candidate.window) did not return as an AX normal window")
                continue
            }
            guard let display = state.displays.first(where: {
                    $0.managedDisplayID == candidate.managedDisplayID }),
                  candidate.targetLogicalIndex < display.spaces.count else {
                _ = restoreUsableFrame(normal, in: state.geometryByDomain[candidate.managedDisplayID])
                failed.append("window \(normal.id) has no verified target normal desktop")
                continue
            }
            let targetSpace = display.spaces[candidate.targetLogicalIndex].id
            guard verifyMove(window: normal.id, to: targetSpace) else {
                _ = restoreUsableFrame(normal, in: state.geometryByDomain[candidate.managedDisplayID])
                failed.append("window \(normal.id) is normal but its Space move failed; restore it manually")
                continue
            }
            guard let geometry = state.geometryByDomain[candidate.managedDisplayID],
                  verifyFrame(pid: normal.pid, window: normal.id,
                              target: WindowGeometry.maximizedFrame(in: geometry.visibleFrame)) else {
                _ = restoreUsableFrame(normal, in: state.geometryByDomain[candidate.managedDisplayID])
                failed.append("window \(normal.id) moved but maximization failed; a usable frame was restored")
                continue
            }
            convertedRestorationFrames[normal.id] = normal.frame
            converted += 1
        }

        waitForNormalLayoutToSettle()
        if case .success(let snapshot) = captureSnapshot() { store.saveAuto(snapshot) }
        let summary = "Converted \(converted)/\(plan.candidates.count) eligible fullscreen app(s); "
            + "skipped \(plan.skipped.count)."
            + (failed.isEmpty ? "" : " " + failed.joined(separator: " "))
        finish(summary, alert: true)
    }

    // MARK: - Runtime state and verified writes

    private func readLiveState() -> Result<LiveState, LayoutOperationFailure> {
        guard case .success(let displays) = SkyLightSpaces.inventory() else {
            return .failure(.message("ordered normal-Space inventory failed"))
        }
        guard case .success(var windows) = WindowAccessibility.windows() else {
            return .failure(.message("Accessibility window identification failed"))
        }
        for index in windows.indices {
            guard case .success(let membership) = SkyLightSpaces.membership(forWindow: windows[index].id)
            else { return .failure(.message("window-to-Space membership read failed")) }
            windows[index].spaceIDs = membership
        }
        let physical = WindowAccessibility.physicalDisplays()
        let byUUID = Dictionary(physical.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var geometry: [ManagedSpaceDomainID: PhysicalDisplayGeometry] = [:]
        for display in displays where display.managedDisplayID != .main {
            if let mapped = byUUID[display.managedDisplayID.rawValue] {
                geometry[display.managedDisplayID] = mapped
            }
        }
        return .success(LiveState(displays: displays, windows: windows,
                                  mode: ManagedSpaceMode.detect(displays),
                                  geometryByDomain: geometry))
    }

    private func captureSnapshot() -> Result<SpaceSnapshot, LayoutOperationFailure> {
        let before = Self.currentTopology()
        guard before != DisplayTopology.none else {
            return .failure(.message("CoreGraphics reports a transient zero-display topology"))
        }
        guard case .success(let state) = readLiveState() else {
            return .failure(.message("Space/window inventory is unavailable"))
        }
        publishMode(state.mode)
        guard state.mode == .separate else {
            return .failure(.message("shared Main Space-domain mode cannot save per-display ordering"))
        }

        let normalIDs = Set(state.displays.flatMap { $0.spaces.map { $0.id } })
        var bySpace: [UInt64: [SpaceSnapshot.Window]] = [:]
        for window in state.windows where !window.isFullscreen && window.isStandardWindow {
            guard let space = window.singleSpaceID, normalIDs.contains(space) else { continue }
            let domain = state.displays.first(where: { $0.spaces.contains(where: { $0.id == space }) })?
                .managedDisplayID
            let geometry = domain.flatMap { state.geometryByDomain[$0] }
            bySpace[space, default: []].append(snapshotWindow(
                from: window, geometry: geometry,
                restorationFrame: convertedRestorationFrames[window.id]))
        }

        let after = Self.currentTopology()
        guard after == before else {
            return .failure(.message("physical topology changed while capturing"))
        }
        return .success(SpaceSnapshot(
            topologyID: after, savedAt: Date(),
            displays: state.displays.map { display in
                let geometry = state.geometryByDomain[display.managedDisplayID]
                return SpaceSnapshot.Display(
                    managedDisplayID: display.managedDisplayID,
                    physicalDisplayUUID: geometry?.uuid,
                    spaces: display.spaces.enumerated().map { index, space in
                        SpaceSnapshot.Space(spaceUUID: space.uuid, logicalIndex: index,
                                            windows: bySpace[space.id] ?? [])
                    }, displayName: geometry?.name)
            }))
    }

    private func snapshotWindow(from window: LiveWindow, geometry: PhysicalDisplayGeometry?,
                                restorationFrame: CGRect?) -> SpaceSnapshot.Window {
        let maximized = geometry.map {
            WindowGeometry.isMaximized(window.frame, in: $0.visibleFrame)
        } ?? false
        return SpaceSnapshot.Window(
            windowID: window.id, pid: window.pid, bundleID: window.bundleID,
            ownerName: window.ownerName, title: window.title,
            documentIdentity: window.documentIdentity, frame: window.frame,
            relativeFrame: geometry.map { WindowGeometry.relative(window.frame, in: $0.visibleFrame) },
            isMaximized: maximized, restorationFrame: restorationFrame)
    }

    private func verifyMove(window: UInt32, to target: UInt64) -> Bool {
        if case .success(let current) = SkyLightSpaces.membership(forWindow: window),
           current == [target] { return true }
        let started = Date()
        var attempt = 1
        while moveRetry.shouldAttempt(number: attempt,
                                      elapsed: Date().timeIntervalSince(started)) {
            guard case .success = SkyLightSpaces.submitMove([window], toNormalSpace: target) else {
                return false
            }
            var verified = false
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.15)
                if case .success(let membership) = SkyLightSpaces.membership(forWindow: window),
                   membership == [target] {
                    verified = true
                    break
                }
            }
            if verified {
                writeCircuit.recordVerifiedMove()
                return true
            }
            writeCircuit.recordVerificationFailure()
            if writeCircuit.isOpen {
                publishCircuitOpen()
                return false
            }
            attempt += 1
        }
        return false
    }

    private func verifyFrame(pid: Int32, window: UInt32, target: CGRect) -> Bool {
        let started = Date()
        var attempt = 1
        while geometryRetry.shouldAttempt(number: attempt,
                                          elapsed: Date().timeIntervalSince(started)) {
            guard case .success = WindowAccessibility.setFrame(pid: pid, windowID: window,
                                                               frame: target) else { return false }
            Thread.sleep(forTimeInterval: 0.12)
            if case .success(let actual) = WindowAccessibility.frame(pid: pid, windowID: window),
               actual.approximatelyEquals(target, tolerance: 3) { return true }
            attempt += 1
        }
        return false
    }

    private func targetFrame(_ presentation: SpaceSnapshot.Window,
                             visibleFrame: CGRect) -> CGRect {
        if presentation.isMaximized { return WindowGeometry.maximizedFrame(in: visibleFrame) }
        if let relative = presentation.relativeFrame {
            return WindowGeometry.absolute(relative, in: visibleFrame)
        }
        return WindowGeometry.usable(presentation.frame, in: visibleFrame)
    }

    private func waitForNormalWindow(_ saved: SpaceSnapshot.Window) -> LiveWindow? {
        let deadline = Date().addingTimeInterval(6)
        repeat {
            if case .success(let state) = readLiveState() {
                let normal = state.windows.filter { !$0.isFullscreen && $0.isAXReachable }
                let match = SpacePlanner.match([saved], to: normal)[0]
                if let id = match, let window = normal.first(where: { $0.id == id }) { return window }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return nil
    }

    private func restoreUsableFrame(_ window: LiveWindow,
                                    in geometry: PhysicalDisplayGeometry?) -> Bool {
        guard let geometry = geometry else { return false }
        let target = WindowGeometry.usable(window.frame, in: geometry.visibleFrame)
        return verifyFrame(pid: window.pid, window: window.id, target: target)
    }

    /// Conversion animations can finish after the last AX write returns. Capture only after
    /// the normal-Space membership and geometry signature has held still for a short bounded
    /// quiet period.
    private func waitForNormalLayoutToSettle() {
        let deadline = Date().addingTimeInterval(4)
        var lastSignature = ""
        var unchangedSince = Date()
        while Date() < deadline {
            guard case .success(let state) = readLiveState() else { return }
            let normalSpaces = state.displays.flatMap { display in
                display.spaces.map { "\(display.managedDisplayID.rawValue):\($0.id)" }
            }
            let normalWindows = state.windows.filter { !$0.isFullscreen }.map {
                "\($0.id):\($0.spaceIDs):\($0.frame.minX),\($0.frame.minY),"
                    + "\($0.frame.width),\($0.frame.height)"
            }
            let signature = (normalSpaces + normalWindows).sorted().joined(separator: "|")
            if signature != lastSignature {
                lastSignature = signature
                unchangedSince = Date()
            } else if Date().timeIntervalSince(unchangedSince) >= 0.6 {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - Operation state and diagnostics

    private func begin(_ operation: Operation) -> Bool {
        guard operationCoordinator.begin() else {
            log("\(operation.rawValue) skipped: another layout operation is active")
            return false
        }
        isOperating = true
        onChange?()
        return true
    }

    private func finish(_ summary: String, alert: Bool = false,
                        completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion?(); return }
            self.isOperating = false
            self.log(summary)
            UserDefaults.standard.set(summary, forKey: "SpacesLastResult")
            self.onChange?()
            completion?()
            if alert { self.showSummary(summary) }
            if self.operationCoordinator.finish(
                    automaticRestoreEnabled: self.automaticRestoreEnabled) {
                self.scheduleAutomaticEvaluation(after: self.debounceDelay)
            }
        }
    }

    private func publishMode(_ mode: ManagedSpaceMode) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.detectedMode != mode else { return }
            self.detectedMode = mode
            self.onChange?()
        }
    }

    private func publishCircuitOpen() {
        DispatchQueue.main.async { [weak self] in
            self?.writesDisabledForSession = true
            self?.onChange?()
        }
    }

    private func showSummary(_ text: String) {
        let show = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Space Layout Protection"
            alert.informativeText = text
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
    }

    private func log(_ message: String) { NSLog("KelvinXDR [Spaces] %@", message) }

    /// Read-only diagnostic entry point. No permission prompts and no test moves.
    static func dump() -> String {
        let sky = SkyLightSpaces.runtimeCapabilities
        let ax = WindowAccessibility.runtimeCapabilities
        let inventory = try? SkyLightSpaces.inventory().get()
        var windows = (try? WindowAccessibility.windows().get()) ?? []
        for index in windows.indices {
            windows[index].spaceIDs = (try? SkyLightSpaces.membership(
                forWindow: windows[index].id).get()) ?? []
        }
        func status(_ value: CapabilityAvailability) -> String {
            if case .unavailable(let reason) = value { return "unavailable: " + reason }
            return "available"
        }
        let report: [String: Any] = [
            "physicalTopology": currentTopology().rawValue,
            "capabilities": [
                "skyLightFramework": status(sky.frameworkLoading),
                "connectionSymbol": status(sky.connectionSymbol),
                "connectionValue": status(sky.connectionValue),
                "orderedNormalSpaces": status(sky.managedDisplayEnumerationSymbol),
                "windowMembership": status(sky.windowMembershipSymbol),
                "moveClass": status(sky.bridgedMoveClass),
                "moveInitializer": status(sky.moveInitializer),
                "movePerformer": status(sky.movePerformer),
                "axWindowBridge": status(ax.axWindowBridge),
                "accessibility": status(ax.accessibilityPermission),
                "geometry": status(ax.geometry),
                "highQualityTitles": status(ax.highQualityTitles),
            ],
            "managedDisplays": (inventory ?? []).map { display in
                ["displayIdentifier": display.managedDisplayID.rawValue,
                 "normalSpaces": display.spaces.map { ["id": $0.id, "uuid": $0.uuid] },
                 "type4Spaces": display.fullscreen.map {
                    ["id": $0.spaceID, "tileWindows": $0.tileWindows]
                 }] as [String: Any]
            },
            "windows": windows.map {
                ["id": $0.id, "pid": $0.pid, "bundleID": $0.bundleID ?? "",
                 "owner": $0.ownerName, "title": $0.title ?? "",
                 "document": $0.documentIdentity ?? "", "spaces": $0.spaceIDs,
                 "isFullscreen": $0.isFullscreen,
                 "frame": ["x": $0.frame.minX, "y": $0.frame.minY,
                           "w": $0.frame.width, "h": $0.frame.height]] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
