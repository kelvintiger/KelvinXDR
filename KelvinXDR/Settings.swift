//
//  Settings.swift
//  KelvinXDR
//
//  The window owns editable lists, recorded shortcuts, and the Settings-only Experimental
//  Space Layout Protection surface. The menu bar stays focused on everyday display controls.
//
//  Built in code rather than a xib — build.sh is a bare swiftc call, and a nib would need a
//  resource pipeline for one window.
//

import Cocoa

/// Captures the next key combination pressed while it has focus.
final class ShortcutRecorder: NSView {
    var onChange: ((Shortcut?) -> Void)?
    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    /// Shown struck-through when another app already owns the combination.
    var isActive = true { didSet { needsDisplay = true } }

    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { recording = true; return true }
    override func resignFirstResponder() -> Bool { recording = false; return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                   : NSColor.controlBackgroundColor).setFill()
        rounded.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        rounded.lineWidth = recording ? 2 : 1
        rounded.stroke()

        let text: String
        let colour: NSColor
        if recording {
            text = "Press keys…"; colour = .secondaryLabelColor
        } else if let shortcut = shortcut {
            text = shortcut.displayString
            colour = isActive ? .labelColor : .systemRed
        } else {
            text = "Click to record"; colour = .tertiaryLabelColor
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .medium),
            .foregroundColor: colour,
        ]
        if shortcut != nil && !isActive && !recording {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }

        // Escape abandons the recording; delete clears the binding entirely.
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        if event.keyCode == 51 || event.keyCode == 117 {
            shortcut = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return
        }

        // A bare key would fire while you were typing anywhere else, so require a modifier.
        let carbon = Shortcut.carbonModifiers(from: event.modifierFlags)
        guard carbon != 0 else { NSSound.beep(); return }

        let recorded = Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon)
        shortcut = recorded
        onChange?(recorded)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While recording, swallow combinations AppKit would otherwise route to the menu —
        // otherwise ⌘Q would quit rather than being recorded.
        guard recording else { return false }
        keyDown(with: event)
        return true
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// One editable level. Each entry carries its own setter, so this window needs to know
    /// nothing about displays, DDC or the gamma boost.
    struct Value {
        let title: String
        let fraction: Double
        let maxFraction: Double
        let apply: (Double) -> Void
    }

    /// Called when anything changes, so the app can re-read defaults and re-register hotkeys.
    var onChange: (() -> Void)?
    /// Asks the app whether a shortcut actually registered.
    var isShortcutActive: ((ShortcutAction) -> Bool)?
    /// The levels to offer for typing, re-read every time the window opens.
    var values: (() -> [Value])?

    /// Saved Space layouts are immutable view data here. Every mutation routes back through
    /// SpaceLayoutManager's serialized queue instead of editing profile files from the UI.
    var spaceProfileCatalog: (() -> SpaceProfileCatalog)?
    /// Snapshot the screen and keep it under this name, then call back on the main thread.
    var captureProfile: ((String, @escaping () -> Void) -> Void)?
    var applyProfile: ((String?, PhysicalTopologyID) -> Void)?
    var selectProfile: ((String?, PhysicalTopologyID, @escaping () -> Void) -> Void)?
    var renameProfileMutation: ((String, String, PhysicalTopologyID, @escaping () -> Void) -> Void)?
    var deleteProfileMutation: ((String, PhysicalTopologyID, @escaping () -> Void) -> Void)?
    var layoutMutationsEnabled: (() -> Bool)?
    var experimentalWritesEnabled: (() -> Bool)?
    var setExperimentalWritesEnabled: ((Bool) -> Void)?
    var automaticSpaceRestoreEnabled: (() -> Bool)?
    var setAutomaticSpaceRestoreEnabled: ((Bool) -> Void)?
    var spaceCapabilityStatus: (() -> String?)?
    var canCaptureSpaceLayout: (() -> Bool)?
    var canRestoreSpaceLayout: (() -> Bool)?
    var canConvertFullscreenApps: (() -> Bool)?
    var convertFullscreenApps: (() -> Void)?

    private var setupPopup: NSPopUpButton!
    private var profileTable: NSTableView!
    private var profileEditingButtons: [NSButton] = []
    private var captureProfileButton: NSButton!
    private var restoreProfileButton: NSButton!
    private var convertFullscreenButton: NSButton!
    private var experimentalWritesButton: NSButton!
    private var automaticRestoreButton: NSButton!
    private var spaceStatusLabel: NSTextField!
    private var setups: [SpaceProfileCatalog.Setup] = []
    /// Rows of the profile table. `name` is nil for the auto-saved profile.
    /// Not private so the test can check what the list renders without showing a window.
    private(set) var profileRows: [(name: String?, label: String)] = []

    private var excluded: [String] = []
    private var excludedTable: NSTableView!
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var levelsStack: NSStackView!
    /// The content itself, inside the scroll view. Not private so the layout test can measure
    /// it without the scroller in the way.
    private(set) var contentStack: NSStackView!

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "KelvinXDR Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildContent()
    }

    func show() {
        reload()
        // LSUIElement apps are not in the Dock and do not activate on their own, so without
        // this the window opens behind whatever you were using.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
    }

    /// Disarm any recorder still waiting for a keypress.
    ///
    /// Closing the window leaves the recorder as first responder, and it stays that way when
    /// the window is reopened — so the next ⌘W or ⌘Q would be silently captured and registered
    /// as a global hotkey rather than closing or quitting.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    /// Not private so the layout test can populate the window without showing it.
    func reload() {
        excluded = UserDefaults.standard.stringArray(forKey: "ExcludedBundleIDs") ?? []
        excludedTable?.reloadData()
        for (action, recorder) in recorders {
            recorder.shortcut = Shortcuts.stored(action)
            recorder.isActive = isShortcutActive?(action) ?? true
        }
        reloadLevels()
        reloadSetups()
        reloadSpaceControls()
    }

    // MARK: - Space profiles

    /// The setup popup, current arrangement first so the common case needs no clicking.
    private func reloadSetups() {
        guard let popup = setupPopup else { return }
        let previous = selectedSetup?.topologyID
        setups = spaceProfileCatalog?().setups ?? []

        popup.removeAllItems()
        for setup in setups {
            popup.addItem(withTitle: setup.description + (setup.isConnected ? " (connected)" : ""))
        }
        if let previous = previous,
           let index = setups.firstIndex(where: { $0.topologyID == previous }) {
            popup.selectItem(at: index)
        } else if let index = setups.firstIndex(where: { $0.isConnected }) {
            popup.selectItem(at: index)
        }
        reloadProfiles()
    }

    private var selectedSetup: SpaceProfileCatalog.Setup? {
        guard let popup = setupPopup, popup.indexOfSelectedItem >= 0,
              popup.indexOfSelectedItem < setups.count else { return nil }
        return setups[popup.indexOfSelectedItem]
    }

    private func reloadProfiles() {
        guard let setup = selectedSetup else {
            profileRows = []
            profileTable?.reloadData()
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        var rows: [(String?, String)] = []
        if let newest = setup.autoSavedAt {
            rows.append((nil, "Auto-saved — updated "
                         + formatter.localizedString(for: newest, relativeTo: Date())))
        } else {
            rows.append((nil, "Auto-saved — nothing recorded yet"))
        }
        for profile in setup.profiles {
            rows.append((profile.name, "\(profile.name) — \(profile.spaceCount) desktop(s), "
                         + "\(profile.windowCount) normal window(s)"))
        }
        // The selected one is marked rather than merely highlighted: table selection means
        // "the row you are about to act on", which is a different thing.
        profileRows = rows.map { (name, label) in
            (name, (name == setup.selectedName ? "● " : "   ") + label)
        }
        profileTable?.reloadData()
    }

    @objc private func setupChanged() { reloadProfiles() }

    /// One-field prompt. NSAlert rather than a second window: it is one string.
    private func askForName(_ title: String, _ initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    @objc private func saveProfile() {
        guard let name = askForName("Name this layout", "Standard") else { return }
        captureProfile?(name) { [weak self] in self?.reloadSetups(); self?.onChange?() }
    }

    @objc private func useProfile() {
        guard let setup = selectedSetup else { return }
        let row = profileTable.selectedRow
        guard row >= 0, row < profileRows.count else { return }
        selectProfile?(profileRows[row].name, setup.topologyID) { [weak self] in
            self?.reloadSetups()
            self?.onChange?()
        }
    }

    @objc private func renameProfile() {
        guard let setup = selectedSetup else { return }
        let row = profileTable.selectedRow
        guard row >= 0, row < profileRows.count, let old = profileRows[row].name else { return }
        guard let new = askForName("Rename this layout", old), new != old else { return }
        renameProfileMutation?(old, new, setup.topologyID) { [weak self] in
            self?.reloadSetups()
            self?.onChange?()
        }
    }

    @objc private func deleteProfile() {
        guard let setup = selectedSetup else { return }
        let row = profileTable.selectedRow
        guard row >= 0, row < profileRows.count, let name = profileRows[row].name else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the layout \"\(name)\"?"
        alert.informativeText = "The arrangement it holds is not recoverable."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteProfileMutation?(name, setup.topologyID) { [weak self] in
            self?.reloadSetups()
            self?.onChange?()
        }
    }

    @objc private func restoreProfile() {
        guard let setup = selectedSetup else { return }
        let row = profileTable.selectedRow
        guard row >= 0, row < profileRows.count else { return }
        applyProfile?(profileRows[row].name, setup.topologyID)
    }

    private func reloadSpaceControls() {
        let idle = layoutMutationsEnabled?() ?? true
        let writes = experimentalWritesEnabled?() ?? false
        let automatic = automaticSpaceRestoreEnabled?() ?? false
        experimentalWritesButton?.state = writes ? .on : .off
        // A currently-enabled gate always stays clickable so it can be shut off immediately.
        experimentalWritesButton?.isEnabled = writes || idle
        automaticRestoreButton?.state = automatic ? .on : .off
        automaticRestoreButton?.isEnabled = automatic
            || (writes && (canRestoreSpaceLayout?() ?? false))
        captureProfileButton?.isEnabled = canCaptureSpaceLayout?() ?? false
        restoreProfileButton?.isEnabled = canRestoreSpaceLayout?() ?? false
        convertFullscreenButton?.isEnabled = canConvertFullscreenApps?() ?? false
        profileEditingButtons.forEach { $0.isEnabled = idle }
        if let status = spaceCapabilityStatus?() {
            spaceStatusLabel?.stringValue = status
        } else {
            spaceStatusLabel?.stringValue = writes
                ? "Experimental Space writes are enabled; outcomes remain unverified."
                : "Experimental Space writes are disabled."
        }
    }

    @objc private func experimentalWritesChanged(_ sender: NSButton) {
        setExperimentalWritesEnabled?(sender.state == .on)
        reloadSpaceControls()
    }

    @objc private func automaticSpaceRestoreChanged(_ sender: NSButton) {
        setAutomaticSpaceRestoreEnabled?(sender.state == .on)
        reloadSpaceControls()
    }

    @objc private func convertFullscreenAppsNow() {
        convertFullscreenApps?()
        reloadSpaceControls()
    }

    /// Rebuilt rather than updated: displays come and go, and the row count changes with them.
    private func reloadLevels() {
        guard let levelsStack = levelsStack else { return }
        for view in levelsStack.arrangedSubviews { view.removeFromSuperview() }

        let entries = values?() ?? []
        guard !entries.isEmpty else {
            levelsStack.addArrangedSubview(
                label("No displays detected.", 11, .regular, .secondaryLabelColor))
            return
        }

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        for entry in entries {
            let name = label(entry.title, 12, .regular)
            name.lineBreakMode = .byTruncatingTail
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: Self.contentWidth - 96).isActive = true

            let field = PercentField(string: Percent.text(entry.fraction))
            field.maxValue = entry.maxFraction
            field.revertText = Percent.text(entry.fraction)
            // Deliberately not onChange(): a level applies itself through `apply`, and the
            // full settings-changed path re-registers every global hotkey, which has no
            // business happening because someone typed a brightness.
            field.onCommit = { value in entry.apply(value) }
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true

            grid.addRow(with: [name, field])
        }
        levelsStack.addArrangedSubview(grid)
    }

    // MARK: - Layout

    /// Every full-width element uses this, so nothing can widen the window on its own.
    static let contentWidth: CGFloat = 400

    /// Stored `TriggerCorner` values, in the order the popup lists them. One array rather than
    /// two: the titles and the values were parallel lists that had to be reordered together,
    /// and getting that wrong would silently write the wrong corner. Index 0 is the default.
    static let corners = ["topRight", "topLeft", "bottomRight", "bottomLeft"]

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight,
                       _ colour: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        return field
    }

    /// A label that wraps instead of running off the edge.
    ///
    /// `NSTextField(labelWithString:)` is single-line: its intrinsic width is the whole string,
    /// so a long sentence silently widens the stack view — and with it the window — until the
    /// text clips against the frame. Wrapping needs all three of these, plus a width to wrap
    /// against, or the field has no idea where to break.
    private func paragraph(_ text: String) -> NSTextField {
        let field = label(text, 11, .regular, .secondaryLabelColor)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = Self.contentWidth
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return field
    }

    private func buildContent() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(label("Levels", 13, .semibold))
        root.addArrangedSubview(paragraph(
            "Type a percentage and press Return; Escape reverts. Above 100% is the XDR boost."))

        // Populated by reloadLevels() every time the window opens, since the display list is
        // not fixed. Empty at build time.
        levelsStack = NSStackView()
        levelsStack.orientation = .vertical
        levelsStack.alignment = .leading
        levelsStack.spacing = 6
        root.addArrangedSubview(levelsStack)

        root.addArrangedSubview(NSBox.separator())
        root.addArrangedSubview(label("Shortcuts", 13, .semibold))
        root.addArrangedSubview(paragraph(
            "These work in any app. Each one needs a modifier key."))

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 14
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
            recorder.translatesAutoresizingMaskIntoConstraints = false
            recorder.widthAnchor.constraint(equalToConstant: 140).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
            recorder.onChange = { [weak self] shortcut in
                Shortcuts.store(shortcut, for: action)
                self?.onChange?()
                // Re-read: the combination may belong to another app, in which case
                // registration silently failed and the recorder should say so.
                DispatchQueue.main.async { self?.reload() }
            }
            recorders[action] = recorder

            let text = NSStackView(views: [label(action.title, 12, .regular),
                                           label(action.detail, 10, .regular, .secondaryLabelColor)])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            grid.addRow(with: [text, recorder])
        }
        root.addArrangedSubview(grid)

        root.addArrangedSubview(NSBox.separator())
        root.addArrangedSubview(label("HDR trigger corner", 13, .semibold))
        root.addArrangedSubview(paragraph(
            "Where the 1×1 pixel that turns on HDR sits."))

        let corner = NSPopUpButton(frame: .zero, pullsDown: false)
        // Default first, so the `?? 0` fallback lands on it for an unset or unrecognised pref.
        corner.addItems(withTitles: ["Top Right", "Top Left", "Bottom Right", "Bottom Left"])
        corner.selectItem(at: SettingsWindowController.corners
            .firstIndex(of: UserDefaults.standard.string(forKey: "TriggerCorner") ?? "topRight") ?? 0)
        corner.target = self
        corner.action = #selector(cornerChanged(_:))
        root.addArrangedSubview(corner)

        root.addArrangedSubview(NSBox.separator())
        root.addArrangedSubview(label("Space Layout Protection — Experimental", 13, .semibold,
                                      .systemOrange))
        root.addArrangedSubview(paragraph(
            "Space writes are not production-validated. A failed restore or conversion may "
            + "leave extra desktops or partially changed normal windows."))

        experimentalWritesButton = NSButton(
            checkboxWithTitle: "Enable Experimental Space Writes", target: self,
            action: #selector(experimentalWritesChanged(_:)))
        root.addArrangedSubview(experimentalWritesButton)

        automaticRestoreButton = NSButton(
            checkboxWithTitle: "Automatically Restore Layouts", target: self,
            action: #selector(automaticSpaceRestoreChanged(_:)))
        root.addArrangedSubview(automaticRestoreButton)

        spaceStatusLabel = paragraph("Experimental Space writes are disabled.")
        spaceStatusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(spaceStatusLabel)
        root.addArrangedSubview(paragraph(
            "Layouts stay separate per physical display setup. ● marks the profile restored "
            + "for that exact setup."))

        setupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        setupPopup.target = self
        setupPopup.action = #selector(setupChanged)
        setupPopup.translatesAutoresizingMaskIntoConstraints = false
        setupPopup.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        root.addArrangedSubview(setupPopup)

        profileTable = NSTableView()
        profileTable.headerView = nil
        profileTable.rowHeight = 20
        profileTable.dataSource = self
        profileTable.delegate = self
        profileTable.doubleAction = #selector(useProfile)
        profileTable.target = self
        let profileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        profileColumn.width = 380
        profileTable.addTableColumn(profileColumn)

        let profileScroll = NSScrollView()
        profileScroll.documentView = profileTable
        profileScroll.hasVerticalScroller = true
        profileScroll.borderType = .bezelBorder
        profileScroll.translatesAutoresizingMaskIntoConstraints = false
        profileScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        profileScroll.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        root.addArrangedSubview(profileScroll)

        // Two rows: five buttons do not fit across 400pt without truncating their titles.
        let saveAs = NSButton(title: "Save Current As…", target: self, action: #selector(saveProfile))
        captureProfileButton = saveAs
        let use = NSButton(title: "Use for This Setup", target: self, action: #selector(useProfile))
        let restoreNow = NSButton(title: "Restore Now", target: self, action: #selector(restoreProfile))
        restoreProfileButton = restoreNow
        let topRow = NSStackView(views: [saveAs, use, restoreNow])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        root.addArrangedSubview(topRow)

        let rename = NSButton(title: "Rename", target: self, action: #selector(renameProfile))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteProfile))
        let bottomRow = NSStackView(views: [rename, delete])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        root.addArrangedSubview(bottomRow)
        profileEditingButtons = [use, rename, delete]

        convertFullscreenButton = NSButton(
            title: "Convert Fullscreen Apps to Dedicated Desktops…", target: self,
            action: #selector(convertFullscreenAppsNow))
        root.addArrangedSubview(convertFullscreenButton)

        root.addArrangedSubview(NSBox.separator())
        root.addArrangedSubview(label("Pause the boost for these apps", 13, .semibold))
        root.addArrangedSubview(paragraph(
            "The boost switches off while one of these is frontmost."))

        excludedTable = NSTableView()
        excludedTable.headerView = nil
        excludedTable.rowHeight = 20
        excludedTable.dataSource = self
        excludedTable.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        column.width = 380
        excludedTable.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = excludedTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        root.addArrangedSubview(scroll)

        let add = NSButton(title: "Add App…", target: self, action: #selector(addExcluded))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeExcluded))
        let buttons = NSStackView(views: [add, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        root.addArrangedSubview(buttons)

        // Scrolled rather than merely sized to fit. Five sections of content is taller than a
        // laptop screen, and a window sized to its content simply ran off the bottom, taking
        // the buttons with it — which is not something the user can scroll to.
        contentStack = root
        let outer = NSScrollView()
        outer.hasVerticalScroller = true
        outer.autohidesScrollers = true
        outer.drawsBackground = false
        outer.borderType = NSBorderType.noBorder
        outer.documentView = root
        window?.contentView = outer
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: outer.contentView.topAnchor),
            root.leadingAnchor.constraint(equalTo: outer.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: outer.contentView.trailingAnchor),
        ])

        // The contentRect passed to NSWindow is a guess; the stack knows the real height once
        // the wrapping labels have broken.
        root.layoutSubtreeIfNeeded()
        let fitting = root.fittingSize
        let ceiling = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        window?.setContentSize(NSSize(width: fitting.width,
                                      height: min(fitting.height, ceiling - 60)))
        window?.minSize = NSSize(width: fitting.width, height: 320)
    }

    // MARK: - Actions

    @objc private func cornerChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.corners.indices.contains(index) else { return }
        UserDefaults.standard.set(Self.corners[index], forKey: "TriggerCorner")
        onChange?()
    }

    @objc private func addExcluded() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        guard !excluded.contains(bundleID) else { return }
        excluded.append(bundleID)
        commitExcluded()
    }

    @objc private func removeExcluded() {
        let row = excludedTable.selectedRow
        guard row >= 0, row < excluded.count else { return }
        excluded.remove(at: row)
        commitExcluded()
    }

    private func commitExcluded() {
        UserDefaults.standard.set(excluded, forKey: "ExcludedBundleIDs")
        excludedTable.reloadData()
        onChange?()
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    /// Return and Escape have to be claimed explicitly — left to the field editor, Return
    /// inserts a newline into a one-line field and Escape does nothing at all.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? PercentField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            field.commit()
            field.window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.revert()
            field.window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// Clicking away is not a commit — Return is. This also makes the end-of-editing that
    /// follows a Return harmless, because committing already moved revertText forward.
    func controlTextDidEndEditing(_ notification: Notification) {
        (notification.object as? PercentField)?.revert()
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === profileTable ? profileRows.count : excluded.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if tableView === profileTable {
            guard row < profileRows.count else { return nil }
            let field = NSTextField(labelWithString: profileRows[row].label)
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        guard row < excluded.count else { return nil }
        let field = NSTextField(labelWithString: excluded[row])
        field.font = .systemFont(ofSize: 11)
        return field
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth).isActive = true
        return box
    }
}
