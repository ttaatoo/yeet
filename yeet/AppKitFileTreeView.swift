//
//  AppKitFileTreeView.swift
//  yeet
//

import AppKit

/// Flattened Files-inspector row. Rules live here so presentation tests can
/// assert selection, Git badges, and spoken labels without a window.
struct FileTreeRowDisplayState: Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isDraft: Bool
    let isRenaming: Bool
    let isCurrent: Bool
    let isExpanded: Bool
    let depth: Int
    let gitDecoration: GitStatusModel.FileDecoration?

    var accessibilityLabel: String {
        guard let gitDecoration else { return name }
        return name + ", " + gitDecoration.accessibilityName
    }

    var nameColor: NSColor {
        if let gitDecoration { return gitDecoration.indicatorColor }
        return name.hasPrefix(".")
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            : .secondaryLabelColor
    }
}

final class AppKitFileTreePanel: NSView, NSTextFieldDelegate {
    private let header = NSView()
    private let titleLabel = AppKitInspectorHeaderLabel()
    private let badgeLabel = inspectorLabel()
    private let revealButton = AppKitChromeIconButton(
        systemImage: "arrow.up.forward.app",
        help: String(localized: "Reveal in Finder"),
        iconSize: 11
    )
    private let scrollView = NSScrollView()
    private let documentView = AppKitFileTreeDocumentView()

    private weak var model: FileTreeModel?
    private weak var git: GitStatusModel?
    private weak var session: TerminalSession?
    private var currentFilePath: String?
    private var rootBadge: (text: String, description: String)?
    private var openFile: ((String) -> Void)?
    private var openToSide: ((String) -> Void)?
    private var onRename: ((String, String) -> Void)?
    private var refreshGitStatus: (() -> Void)?
    private var fontScale: CGFloat = 1
    private var fontFamily = ""
    private var lastItemPaths: [String] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        header.addSubview(titleLabel)
        header.addSubview(badgeLabel)
        header.addSubview(revealButton)
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 4
        revealButton.onAction = { [weak self] in
            guard let path = self?.model?.rootPath, !path.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        documentView.postsFrameChangedNotifications = true
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        model: FileTreeModel,
        git: GitStatusModel,
        session: TerminalSession?,
        rootBadge: (text: String, description: String)?,
        currentFilePath: String?,
        openFile: @escaping (String) -> Void,
        openToSide: @escaping (String) -> Void,
        onRename: @escaping (String, String) -> Void,
        refreshGitStatus: @escaping () -> Void
    ) {
        self.model = model
        self.git = git
        self.session = session
        self.rootBadge = rootBadge
        self.currentFilePath = currentFilePath
        self.openFile = openFile
        self.openToSide = openToSide
        self.onRename = onRename
        self.refreshGitStatus = refreshGitStatus

        let settings = AppSettings.shared
        fontScale = CGFloat(settings.filesFontSize / AppSettings.defaultFilesFontSize)
        fontFamily = settings.filesFontFamily

        titleLabel.configure(title: model.rootName, subtitle: model.rootPath, fontScale: 1)
        updateRootBadge(rootBadge)
        rebuildRowsIfNeeded()
        needsLayout = true
    }

    func updateRootBadge(_ badge: (text: String, description: String)?) {
        rootBadge = badge
        if let badge {
            badgeLabel.isHidden = false
            badgeLabel.stringValue = badge.text
            badgeLabel.font = .systemFont(ofSize: 9, weight: .medium)
            badgeLabel.textColor = .secondaryLabelColor
            badgeLabel.layer?.backgroundColor = Theme.chromeSelected.cgColor
            badgeLabel.setAccessibilityLabel(badge.description)
        } else {
            badgeLabel.isHidden = true
            badgeLabel.stringValue = ""
        }
        needsLayout = true
    }

    var debugRowNames: [String] {
        documentView.rows.compactMap { $0.debugName }
    }

    var debugRowCount: Int { documentView.rows.count }

    func debugRow(at index: Int) -> AppKitFileTreeRowView? {
        documentView.rows.indices.contains(index) ? documentView.rows[index] : nil
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 40)
        revealButton.frame = NSRect(x: bounds.width - 30, y: 10, width: 18, height: 18)
        var trailing = revealButton.frame.minX - 6
        if !badgeLabel.isHidden {
            badgeLabel.sizeToFit()
            let badgeWidth = badgeLabel.bounds.width + 10
            badgeLabel.frame = NSRect(
                x: trailing - badgeWidth,
                y: 12,
                width: badgeWidth,
                height: 16
            )
            trailing = badgeLabel.frame.minX - 6
        }
        titleLabel.frame = NSRect(x: 12, y: 6, width: max(0, trailing - 12), height: 28)
        scrollView.frame = NSRect(
            x: 0, y: 40, width: bounds.width, height: max(0, bounds.height - 40)
        )
        layoutDocument()
    }

    private func rebuildRowsIfNeeded() {
        guard let model else { return }
        let items = model.items
        let paths = items.map(\.path)
        let itemsChanged = paths != lastItemPaths
        lastItemPaths = paths
        if itemsChanged {
            documentView.rows.forEach { $0.removeFromSuperview() }
            documentView.rows = items.map { item in
                let row = AppKitFileTreeRowView(frame: .zero)
                documentView.addSubview(row)
                return row
            }
        }
        for (row, item) in zip(documentView.rows, items) {
            apply(item, to: row)
        }
        layoutDocument()
    }

    private func apply(_ item: FileTreeModel.Item, to row: AppKitFileTreeRowView) {
        guard let model else { return }
        let state = FileTreeRowDisplayState(
            name: item.name,
            path: item.path,
            isDirectory: item.isDirectory,
            isDraft: item.isDraft,
            isRenaming: model.renamingPath == item.path,
            isCurrent: !item.isDirectory && item.path == currentFilePath,
            isExpanded: model.isExpanded(item),
            depth: item.depth,
            gitDecoration: git?.fileDecoration(for: item.path, isDirectory: item.isDirectory)
        )
        row.configure(
            item: item,
            state: state,
            fontScale: fontScale,
            fontFamily: fontFamily,
            onActivate: { [weak self] in self?.activate(item) },
            onRenameCommit: { [weak self] name in self?.commitRename(item, name: name) },
            onRenameCancel: { [weak self] in self?.model?.cancelRename() },
            onDraftCommit: { [weak self] name in self?.commitDraft(name: name) },
            onDraftCancel: { [weak self] in self?.model?.cancelDraft() },
            menu: { [weak self] in self?.menu(for: item) ?? NSMenu() }
        )
    }

    private func activate(_ item: FileTreeModel.Item) {
        guard let model else { return }
        if item.isDirectory {
            model.toggle(item)
        } else {
            openFile?(item.path)
        }
    }

    private func commitRename(_ item: FileTreeModel.Item, name: String) {
        let oldPath = item.path
        if let newPath = model?.rename(item, to: name) {
            onRename?(oldPath, newPath)
            refreshGitStatus?()
        }
    }

    private func commitDraft(name: String) {
        if let created = model?.commitDraft(name: name) {
            openFile?(created)
        }
        refreshGitStatus?()
    }

    private func menu(for item: FileTreeModel.Item) -> NSMenu {
        let menu = NSMenu()
        if !item.isDirectory {
            menu.addItem(actionItem(String(localized: "Open")) { [weak self] in
                self?.openFile?(item.path)
            })
            menu.addItem(actionItem(String(localized: "Open to the Side")) { [weak self] in
                self?.openToSide?(item.path)
            })
        }
        menu.addItem(actionItem(String(localized: "Open in Default App")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        })
        menu.addItem(actionItem(String(localized: "Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        })
        menu.addItem(actionItem(String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        })
        if item.isDirectory {
            menu.addItem(actionItem(String(localized: "cd Here")) { [weak self] in
                self?.session?.sendCommand("cd " + POSIXShell.quote(item.path) + "\n")
            })
            menu.addItem(.separator())
            menu.addItem(actionItem(String(localized: "New File…")) { [weak self] in
                self?.model?.beginNewFile(in: item.path)
            })
            menu.addItem(actionItem(String(localized: "New Folder…")) { [weak self] in
                self?.model?.beginNewFolder(in: item.path)
            })
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Rename")) { [weak self] in
            self?.model?.beginRename(item)
        })
        let trash = actionItem(String(localized: "Move to Trash")) { [weak self] in
            self?.confirmMoveToTrash(item)
        }
        trash.target = nil
        menu.addItem(trash)
        return menu
    }

    private func confirmMoveToTrash(_ item: FileTreeModel.Item) {
        Task { @MainActor in
            let kind = item.isDirectory
                ? String(localized: "folder")
                : String(localized: "file")
            let approved = await WorkspaceAlert.confirm(
                message: String(
                    localized: "Move “\(item.name)” to the Trash?",
                    comment: "File tree trash confirmation. The placeholder is a file or folder name."
                ),
                informative: item.isDirectory
                    ? String(localized: "This folder and everything inside it will be moved to the Trash.")
                    : String(localized: "This \(kind) will be moved to the Trash."),
                confirmTitle: String(localized: "Move to Trash"),
                on: window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
            guard approved else { return }
            model?.moveToTrash(item)
            refreshGitStatus?()
        }
    }

    private func layoutDocument() {
        let width = max(scrollView.contentSize.width, bounds.width)
        var y: CGFloat = 0
        for row in documentView.rows {
            let height = row.fittingHeight
            row.frame = NSRect(x: 6, y: y, width: max(0, width - 12), height: height)
            y += height + 1
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scrollView.contentSize.height))
    }

    private func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppKitMenuTrampoline.run), keyEquivalent: "")
        let trampoline = AppKitMenuTrampoline(action)
        item.target = trampoline
        item.representedObject = trampoline
        return item
    }
}

final class AppKitFileTreeDocumentView: NSView {
    var rows: [AppKitFileTreeRowView] = []
    override var isFlipped: Bool { true }
}

final class AppKitFileTreeRowView: NSView, NSTextFieldDelegate, NSDraggingSource {
    private let chevron = NSImageView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = inspectorLabel()
    private let badgeLabel = inspectorLabel()
    private let nameField = AppKitInlineNameField(frame: .zero)
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false
    private var dragStart: NSPoint?
    private var item: FileTreeModel.Item?
    private(set) var state: FileTreeRowDisplayState?
    private var fontScale: CGFloat = 1
    private var fontFamily = ""
    var onActivate: (() -> Void)?
    var onRenameCommit: ((String) -> Void)?
    var onRenameCancel: (() -> Void)?
    var onDraftCommit: ((String) -> Void)?
    var onDraftCancel: (() -> Void)?
    var menuBuilder: (() -> NSMenu)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }

    var fittingHeight: CGFloat {
        ceil(SidebarTypography.designedFileNameSize * fontScale) + 8
    }

    var debugName: String? { state?.isDraft == true ? nil : state?.name }
    var debugState: FileTreeRowDisplayState? { state }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        focusRingType = .default
        chevron.imageScaling = .scaleProportionallyDown
        iconView.imageScaling = .scaleProportionallyDown
        chevron.setAccessibilityElement(false)
        iconView.setAccessibilityElement(false)
        badgeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        nameField.isBordered = false
        nameField.focusRingType = .none
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commitInline)
        nameField.onCancel = { [weak self] in self?.cancelInline() }
        addSubview(chevron)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(badgeLabel)
        addSubview(nameField)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }

    func configure(
        item: FileTreeModel.Item,
        state: FileTreeRowDisplayState,
        fontScale: CGFloat,
        fontFamily: String,
        onActivate: @escaping () -> Void,
        onRenameCommit: @escaping (String) -> Void,
        onRenameCancel: @escaping () -> Void,
        onDraftCommit: @escaping (String) -> Void,
        onDraftCancel: @escaping () -> Void,
        menu: @escaping () -> NSMenu
    ) {
        self.item = item
        self.state = state
        self.fontScale = fontScale
        self.fontFamily = fontFamily
        self.onActivate = onActivate
        self.onRenameCommit = onRenameCommit
        self.onRenameCancel = onRenameCancel
        self.onDraftCommit = onDraftCommit
        self.onDraftCancel = onDraftCancel
        self.menuBuilder = menu
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshBackground()
    }

    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item, item.isDraft == false, let dragStart else { return }
        let current = event.locationInWindow
        guard hypot(current.x - dragStart.x, current.y - dragStart.y) >= 4 else { return }
        didDrag = true
        let url = URL(fileURLWithPath: item.path) as NSURL
        let draggingItem = NSDraggingItem(pasteboardWriter: url)
        draggingItem.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        self.dragStart = nil
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = !didDrag && state?.isDraft != true && state?.isRenaming != true
        dragStart = nil
        didDrag = false
        if shouldActivate { onActivate?() }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onActivate?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard state?.isDraft != true else { return nil }
        return menuBuilder?()
    }

    override func layout() {
        super.layout()
        guard let state else { return }
        let scale = fontScale
        var x = CGFloat(state.depth) * 12 + 6
        let chevronWidth = 10 * scale
        let iconWidth = 14 * scale
        let y = max(0, (bounds.height - iconWidth) / 2)
        if state.isDirectory && !state.isDraft {
            chevron.frame = NSRect(x: x, y: y + 2, width: chevronWidth, height: chevronWidth)
            chevron.frameRotation = state.isExpanded ? 90 : 0
        } else {
            chevron.frameRotation = 0
            chevron.frame = NSRect(x: x, y: y, width: chevronWidth, height: chevronWidth)
        }
        x += chevronWidth + 5
        iconView.frame = NSRect(x: x, y: y, width: iconWidth, height: iconWidth)
        x += iconWidth + 5
        var trailing = bounds.width - 6
        if !badgeLabel.isHidden {
            badgeLabel.sizeToFit()
            let badgeWidth = badgeLabel.bounds.width
            badgeLabel.frame = NSRect(
                x: trailing - badgeWidth,
                y: max(0, (bounds.height - badgeLabel.bounds.height) / 2),
                width: badgeWidth,
                height: badgeLabel.bounds.height
            )
            trailing -= badgeWidth + 4
        }
        let nameFrame = NSRect(
            x: x,
            y: 1,
            width: max(0, trailing - x),
            height: max(0, bounds.height - 2)
        )
        nameLabel.frame = nameFrame
        nameField.frame = nameFrame
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitInline()
    }

    @objc private func commitInline() {
        guard let state else { return }
        if state.isDraft {
            onDraftCommit?(nameField.stringValue)
        } else if state.isRenaming {
            onRenameCommit?(nameField.stringValue)
        }
    }

    private func cancelInline() {
        guard let state else { return }
        if state.isDraft {
            onDraftCancel?()
        } else {
            onRenameCancel?()
        }
    }

    private func refresh() {
        guard let state else { return }
        let scale = fontScale
        let editing = state.isRenaming || state.isDraft
        nameLabel.isHidden = editing
        nameField.isHidden = !editing
        nameLabel.stringValue = state.name
        nameLabel.font = SidebarTypography.nsFont(
            family: fontFamily,
            size: SidebarTypography.designedFileNameSize * scale
        )
        nameLabel.textColor = state.nameColor
        if editing {
            nameField.font = nameLabel.font
            nameField.placeholderString = state.isDraft
                ? (state.isDirectory
                    ? String(localized: "Folder name")
                    : String(localized: "File name"))
                : String(localized: "Name")
            if nameField.currentEditor() == nil {
                nameField.stringValue = state.isDraft ? "" : state.name
                DispatchQueue.main.async { [weak self] in
                    self?.window?.makeFirstResponder(self?.nameField)
                }
            }
            nameField.wantsLayer = true
            nameField.layer?.cornerRadius = 3
            nameField.layer?.backgroundColor = Theme.chromeHover.cgColor
            nameField.layer?.borderWidth = 1
            nameField.layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor
        }
        if state.isDirectory && !state.isDraft {
            chevron.isHidden = false
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.image = inspectorSymbolImage("chevron.right", size: 8 * scale, weight: .semibold)
        } else {
            chevron.isHidden = true
            chevron.image = nil
        }
        if state.isDirectory {
            iconView.image = inspectorSymbolImage("folder.fill", size: 10 * scale)
            iconView.contentTintColor = Theme.accent.withAlphaComponent(0.8)
        } else {
            iconView.contentTintColor = nil
            iconView.image = MaterialFileIcon.image(forPath: state.path, appearance: effectiveAppearance)
        }
        if let decoration = state.gitDecoration, !editing {
            badgeLabel.isHidden = false
            badgeLabel.stringValue = decoration.badge
            badgeLabel.textColor = decoration.indicatorColor
            badgeLabel.setAccessibilityElement(false)
        } else {
            badgeLabel.isHidden = true
            badgeLabel.stringValue = ""
        }
        setAccessibilityLabel(state.accessibilityLabel)
        refreshBackground()
        needsLayout = true
    }

    private func refreshBackground() {
        guard let state else { return }
        let fill: NSColor
        if state.isDraft {
            fill = Theme.chromeHover
        } else if state.isCurrent {
            fill = Theme.chromeSelected
        } else if isHovering {
            fill = Theme.chromeHover
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }
}

final class AppKitInlineNameField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// NSMenuItem target that keeps a closure alive for the menu's lifetime via
/// `representedObject`.
final class AppKitMenuTrampoline: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}
