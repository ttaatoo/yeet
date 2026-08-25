//
//  AppKitChromeViews.swift
//  yeet
//

import AppKit
import Combine
import SwiftUI

enum SidebarRowTrailingContent: Equatable {
    case none
    case shortcut(String)
    case close
}

/// The state that the native project-row view paints. Keeping the transient
/// rules here means the representable only mounts the view; it does not make
/// SwiftUI decide which badge, shortcut, or close control is visible.
struct SidebarRowDisplayState: Equatable {
    let title: String
    let sessionCount: Int
    let pendingReviewCount: Int?
    let agentRollup: KeroAgentRollup?
    let index: Int
    let isRenaming: Bool
    let isHovering: Bool
    let directory: String

    init(
        title: String,
        sessionCount: Int,
        pendingReviewCount: Int?,
        agentRollup: KeroAgentRollup?,
        index: Int,
        isRenaming: Bool,
        directory: String,
        isHovering: Bool = false
    ) {
        self.title = title
        self.sessionCount = sessionCount
        self.pendingReviewCount = pendingReviewCount
        self.agentRollup = agentRollup
        self.index = index
        self.isRenaming = isRenaming
        self.isHovering = isHovering
        self.directory = directory
    }

    var subtitle: String? {
        Self.subtitle(for: sessionCount)
    }

    static func subtitle(for sessionCount: Int) -> String? {
        guard sessionCount > 1 else { return nil }
        return String(
            localized: "\(sessionCount) sessions",
            comment: "Number of sessions in a project row."
        )
    }

    var showsReviewCount: Bool {
        !isRenaming && (pendingReviewCount ?? 0) > 0
    }

    var showsAgentBadge: Bool {
        !isRenaming && agentRollup != nil
    }

    var trailingContent: SidebarRowTrailingContent {
        guard !isRenaming else { return .none }
        if isHovering { return .close }
        guard index < 9 else { return .none }
        return .shortcut("⌘\(index + 1)")
    }

    var accessibilityLabel: String { title }
}

final class AppKitSidebarProjectRowView: NSView, NSTextFieldDelegate {
    private final class RenameField: NSTextField {
        var onCancel: (() -> Void)?

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }

    private weak var project: Project?
    private var projectObservation: AnyCancellable?
    private var index = 0
    private var fontSize = AppSettings.defaultSidebarFontSize
    private var isSelected = false
    private var isDragging = false
    private var isRenaming = false
    private var isHovering = false
    private var dragStart: NSPoint?
    private var didDrag = false
    private var trackingAreaReference: NSTrackingArea?
    private var suppressEndEditing = false
    private var refreshQueued = false

    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let reviewLabel = NSTextField(labelWithString: "")
    private let renameField = RenameField(frame: .zero)
    private let statusBadge = AgentStatusBadgeView(frame: .zero)
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(frame: .zero)
    private let selectionStripe = CALayer()

    private var displayState = SidebarRowDisplayState(
        title: "",
        sessionCount: 0,
        pendingReviewCount: nil,
        agentRollup: nil,
        index: 0,
        isRenaming: false,
        directory: ""
    )

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .default
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = false
        selectionStripe.cornerRadius = 1
        layer?.addSublayer(selectionStripe)

        iconView.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: String(localized: "Project")
        )
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        for label in [titleLabel, subtitleLabel, reviewLabel, shortcutLabel] {
            label.isBordered = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }

        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .none
        renameField.delegate = self
        renameField.target = self
        renameField.action = #selector(commitRenameAction)
        renameField.isHidden = true
        renameField.onCancel = { [weak self] in self?.cancelRename() }
        addSubview(renameField)

        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        statusBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(statusBadge)

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: "Close Project")
        )
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .texturedRounded
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        closeButton.toolTip = String(localized: "Close Project")
        closeButton.isHidden = true
        addSubview(closeButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rowHeight)
    }

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 2, dy: 1)
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: focusRingMaskBounds,
            xRadius: 6,
            yRadius: 6
        ).fill()
    }

    func update(
        project: Project,
        index: Int,
        isSelected: Bool,
        isDragging: Bool,
        fontSize: Double,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onDrag: @escaping (CGPoint) -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.index = index
        self.isSelected = isSelected
        self.isDragging = isDragging
        self.fontSize = fontSize
        self.onSelect = onSelect
        self.onClose = onClose
        self.onDrag = onDrag
        self.onDragEnded = onDragEnded

        if self.project !== project {
            self.project = project
            projectObservation?.cancel()
            projectObservation = project.objectWillChange.sink { [weak self] _ in
                self?.scheduleRefresh()
            }
        }
        refreshFromModel()
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshFromModel()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshFromModel()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRenaming else { return }
        window?.makeFirstResponder(self)
        dragStart = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isRenaming, let dragStart else { return }
        let current = event.locationInWindow
        let distance = hypot(current.x - dragStart.x, current.y - dragStart.y)
        guard distance >= 4 else { return }
        didDrag = true
        onDrag?(rootCoordinate(for: event))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = didDrag
        dragStart = nil
        didDrag = false
        if wasDragging {
            onDragEnded?()
        } else if !isRenaming {
            onSelect?()
        }
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        guard !isRenaming else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 36 || event.keyCode == 49 {
            onSelect?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard !isRenaming else { return false }
        onSelect?()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit,
           hit === closeButton
            || hit.isDescendant(of: closeButton)
            || hit === renameField
            || hit.isDescendant(of: renameField) {
            return hit
        }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let project else { return nil }
        let menu = NSMenu()
        menu.addItem(actionItem(
            title: String(localized: "Rename…"),
            action: #selector(beginRenameAction)
        ))
        if project.customName != nil {
            menu.addItem(actionItem(
                title: String(localized: "Use Automatic Title"),
                action: #selector(useAutomaticNameAction)
            ))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: String(localized: "Set Project Directory…"),
            action: #selector(setDirectoryAction)
        ))
        if project.customDirectory != nil {
            menu.addItem(actionItem(
                title: String(localized: "Use Automatic Directory"),
                action: #selector(useAutomaticDirectoryAction)
            ))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: String(localized: "Close Project"),
            action: #selector(closeAction)
        ))
        return menu
    }

    override func layout() {
        super.layout()
        let titleLineHeight = self.titleLineHeight
        let top = 6 * sidebarFontScale
        let iconFrame = NSRect(
            x: 8,
            y: top,
            width: titleLineHeight,
            height: titleLineHeight
        )
        iconView.frame = iconFrame

        let trailing = trailingLayout()
        let titleX = iconFrame.maxX + 8
        let titleWidth = max(0, trailing.leading - titleX - 8)
        titleLabel.frame = NSRect(
            x: titleX,
            y: top,
            width: titleWidth,
            height: titleLineHeight
        )
        renameField.frame = titleLabel.frame
        subtitleLabel.frame = NSRect(
            x: titleX,
            y: top + titleLineHeight + 1,
            width: titleWidth,
            height: supportingFontSize + 2
        )

        if displayState.showsReviewCount,
           let count = displayState.pendingReviewCount {
            let size = reviewLabel.sizeThatFits(
                NSSize(width: CGFloat.greatestFiniteMagnitude, height: titleLineHeight)
            )
            reviewLabel.frame = NSRect(
                x: trailing.reviewLeading,
                y: top,
                width: size.width,
                height: titleLineHeight
            )
            reviewLabel.stringValue = "\(count)"
        } else {
            reviewLabel.frame = .zero
        }

        if displayState.showsAgentBadge {
            let badgeSize = statusBadge.intrinsicContentSize
            statusBadge.frame = NSRect(
                x: trailing.badgeLeading,
                y: top + max(0, (titleLineHeight - badgeSize.height) / 2),
                width: badgeSize.width,
                height: badgeSize.height
            )
        } else {
            statusBadge.frame = .zero
        }

        switch displayState.trailingContent {
        case .close:
            closeButton.frame = trailing.trailingSlot
            shortcutLabel.frame = .zero
        case .shortcut:
            shortcutLabel.frame = trailing.trailingSlot
            closeButton.frame = .zero
        case .none:
            closeButton.frame = .zero
            shortcutLabel.frame = .zero
        }

        selectionStripe.frame = NSRect(
            x: 0,
            y: 6,
            width: 2,
            height: max(0, bounds.height - 12)
        )
    }

    private func refreshFromModel() {
        guard let project else { return }
        let reviewCount = project.pendingReview?.fileCount
        displayState = SidebarRowDisplayState(
            title: project.name,
            sessionCount: project.sessions.count,
            pendingReviewCount: reviewCount,
            agentRollup: project.agentRollup,
            index: index,
            isRenaming: isRenaming,
            directory: project.selectedSession?.currentDirectoryPath ?? "",
            isHovering: isHovering && !isDragging
        )

        titleLabel.stringValue = displayState.title
        titleLabel.font = NSFont.systemFont(ofSize: projectTitleFontSize)
        titleLabel.textColor = isSelected
            ? Theme.chromePrimaryText
            : Theme.chromeMutedText
        titleLabel.isHidden = isRenaming

        renameField.font = NSFont.systemFont(
            ofSize: projectTitleFontSize,
            weight: .medium
        )
        renameField.textColor = isSelected
            ? Theme.chromePrimaryText
            : Theme.chromeMutedText
        renameField.isHidden = !isRenaming

        subtitleLabel.stringValue = displayState.subtitle ?? ""
        subtitleLabel.font = NSFont.systemFont(ofSize: supportingFontSize)
        subtitleLabel.textColor = Theme.chromeMutedText
        subtitleLabel.isHidden = displayState.subtitle == nil

        reviewLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: supportingFontSize,
            weight: .medium
        )
        reviewLabel.textColor = Theme.chromeProgress
        reviewLabel.stringValue = displayState.showsReviewCount
            ? "\(reviewCount ?? 0)"
            : ""
        reviewLabel.isHidden = !displayState.showsReviewCount
        reviewLabel.setAccessibilityLabel(
            displayState.showsReviewCount
                ? String(localized: "\(reviewCount ?? 0) files to review")
                : nil
        )

        statusBadge.isHidden = !displayState.showsAgentBadge
        if let rollup = displayState.agentRollup, displayState.showsAgentBadge {
            statusBadge.apply(phase: rollup.phase, count: rollup.count)
        }

        shortcutLabel.stringValue = {
            if case .shortcut(let shortcut) = displayState.trailingContent {
                return shortcut
            }
            return ""
        }()
        shortcutLabel.font = NSFont.systemFont(ofSize: supportingFontSize)
        shortcutLabel.textColor = Theme.chromeMutedText
        shortcutLabel.alignment = .right

        switch displayState.trailingContent {
        case .close:
            closeButton.isHidden = false
            shortcutLabel.isHidden = true
        case .shortcut:
            closeButton.isHidden = true
            shortcutLabel.isHidden = false
        case .none:
            closeButton.isHidden = true
            shortcutLabel.isHidden = true
        }

        iconView.contentTintColor = isSelected
            ? Theme.chromeAccent
            : Theme.chromeMutedText
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 11 * sidebarFontScale,
            weight: .medium
        )
        if let image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: "Close Project")
        ) {
            closeButton.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 9 * sidebarFontScale,
                    weight: .bold
                )
            )
        }
        closeButton.contentTintColor = Theme.chromeMutedText
        alphaValue = isDragging ? 0.65 : 1
        layer?.backgroundColor = (
            isSelected
                ? Theme.chromeSelected
                : (isHovering ? Theme.chromeHover : .clear)
        ).cgColor
        selectionStripe.isHidden = !isSelected
        selectionStripe.backgroundColor = Theme.chromeAccent.cgColor
        toolTip = displayState.directory.isEmpty ? nil : displayState.directory
        setAccessibilityLabel(displayState.accessibilityLabel)
        setAccessibilityHelp(displayState.directory)
        refreshAccessibilityChildren()
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshFromModel()
        }
    }

    private func refreshAccessibilityChildren() {
        var children: [Any] = [titleLabel]
        if displayState.subtitle != nil {
            children.append(subtitleLabel)
        }
        if displayState.showsReviewCount {
            children.append(reviewLabel)
        }
        if displayState.showsAgentBadge {
            children.append(statusBadge)
        }
        if displayState.trailingContent == .close {
            children.append(closeButton)
        }
        setAccessibilityChildren(children)
    }

    private func trailingLayout() -> (
        leading: CGFloat,
        reviewLeading: CGFloat,
        badgeLeading: CGFloat,
        trailingSlot: NSRect
    ) {
        let trailingPadding: CGFloat = 8
        let slotWidth: CGFloat = 24
        let gap: CGFloat = 4
        var slotLeading = bounds.width - trailingPadding - slotWidth
        if displayState.trailingContent == .none {
            slotLeading = bounds.width - trailingPadding
        }

        var badgeLeading = slotLeading
        if displayState.showsAgentBadge {
            badgeLeading -= gap + statusBadge.intrinsicContentSize.width
        }
        var reviewLeading = badgeLeading
        if displayState.showsReviewCount {
            let size = reviewLabel.sizeThatFits(
                NSSize(width: CGFloat.greatestFiniteMagnitude, height: titleLineHeight)
            )
            reviewLeading -= gap + size.width
        }
        let clusterLeading = min(reviewLeading, badgeLeading)
        return (
            leading: clusterLeading,
            reviewLeading: reviewLeading,
            badgeLeading: badgeLeading,
            trailingSlot: NSRect(
                x: slotLeading,
                y: 6 * sidebarFontScale,
                width: slotWidth,
                height: titleLineHeight
            )
        )
    }

    private var sidebarFontScale: CGFloat {
        CGFloat(fontSize / AppSettings.defaultSidebarFontSize)
    }

    private var supportingFontSize: CGFloat {
        10 * sidebarFontScale
    }

    private var projectTitleFontSize: CGFloat {
        11.5 * sidebarFontScale
    }

    private var titleLineHeight: CGFloat {
        16 * sidebarFontScale
    }

    private var rowHeight: CGFloat {
        displayState.subtitle == nil
            ? 12 + titleLineHeight
            : 13 + titleLineHeight + supportingFontSize + 2
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func rootCoordinate(for event: NSEvent) -> CGPoint {
        guard let contentView = window?.contentView else {
            return event.locationInWindow
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: point.x,
            y: contentView.bounds.height - point.y
        )
    }

    @objc private func beginRenameAction() {
        guard let project else { return }
        isRenaming = true
        renameField.stringValue = project.name
        refreshFromModel()
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    @objc private func commitRenameAction() {
        commitRename()
    }

    private func commitRename() {
        guard let project else { return }
        project.customName = Project.normalizedCustomName(renameField.stringValue)
        isRenaming = false
        suppressEndEditing = true
        window?.makeFirstResponder(nil)
        suppressEndEditing = false
        refreshFromModel()
    }

    private func cancelRename() {
        guard isRenaming else { return }
        isRenaming = false
        suppressEndEditing = true
        window?.makeFirstResponder(nil)
        suppressEndEditing = false
        refreshFromModel()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isRenaming, !suppressEndEditing else { return }
        commitRename()
    }

    @objc private func useAutomaticNameAction() {
        project?.customName = nil
    }

    @objc private func setDirectoryAction() {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the directory for “\(project.name)”.")
        if let current = project.customDirectory
            ?? project.selectedSession?.currentDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { [weak project] response in
            guard response == .OK, let project, let url = panel.url else { return }
            project.customDirectory = url.path
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    @objc private func useAutomaticDirectoryAction() {
        project?.customDirectory = nil
    }

    @objc private func closeAction() {
        onClose?()
    }
}

/// AppKit owns the activity strip's phase observation and pixel. SwiftUI
/// only hosts this view inside the existing legacy pane header.
enum AppKitPaneActivityBarStyle: Equatable {
    case hidden
    case progress
    case attention

    static func style(for phase: KeroAgentPhase?) -> Self {
        switch phase {
        case .working, .created, .done:
            return .progress
        case .blocked:
            return .attention
        default:
            return .hidden
        }
    }
}

final class AppKitPaneActivityBarView: NSView {
    private weak var session: TerminalSession?
    private var observation: AnyCancellable?
    private var refreshQueued = false
    private let activityLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(activityLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func layout() {
        super.layout()
        activityLayer.frame = NSRect(
            x: 6,
            y: 0,
            width: max(0, bounds.width - 12),
            height: 1
        )
    }

    func update(session: TerminalSession?) {
        if self.session !== session {
            self.session = session
            observation?.cancel()
            if let session {
                observation = session.objectWillChange.sink { [weak self] _ in
                    self?.scheduleRefresh()
                }
            }
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func refresh() {
        let style = AppKitPaneActivityBarStyle.style(for: session?.agentStatus?.phase)
        let color: NSColor? = switch style {
        case .progress: Theme.chromeProgress
        case .attention: Theme.chromeAccent
        case .hidden: nil
        }
        activityLayer.backgroundColor = color?.cgColor
        activityLayer.isHidden = style == .hidden
    }
}

struct AppKitPaneActivityBarRepresentable: NSViewRepresentable {
    let content: PaneContent

    func makeNSView(context: Context) -> AppKitPaneActivityBarView {
        let view = AppKitPaneActivityBarView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ view: AppKitPaneActivityBarView, context: Context) {
        update(view)
    }

    private func update(_ view: AppKitPaneActivityBarView) {
        if case .session(let session) = content {
            view.update(session: session)
        } else {
            view.update(session: nil)
        }
    }
}
