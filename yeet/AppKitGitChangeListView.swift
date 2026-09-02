//
//  AppKitGitChangeListView.swift
//  yeet
//

import AppKit

enum AppKitGitSection: Equatable {
    case merge, staged, changes, history
}

func inspectorCopyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

final class AppKitGitPlaceholderView: NSView {
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = inspectorLabel()
    private let detailLabel = inspectorLabel()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let progress = AppKitMiniProgressView()
    var onInitialize: (() -> Void)?
    var onRetry: (() -> Void)?
    private var mode = Mode.message

    private enum Mode {
        case message
        case notRepository
        case statusFailure
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 5
        detailLabel.lineBreakMode = .byWordWrapping
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(handleAction)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(actionButton)
        addSubview(progress)
    }

    required init?(coder: NSCoder) { nil }

    func showMessage(icon: String, text: String, showsInitialize: Bool, showsRetry: Bool) {
        mode = .message
        iconView.image = inspectorSymbolImage(icon, size: 24, weight: .light)
        iconView.contentTintColor = .quaternaryLabelColor
        titleLabel.stringValue = text
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .tertiaryLabelColor
        detailLabel.isHidden = true
        actionButton.isHidden = !showsInitialize && !showsRetry
        progress.isHidden = true
        needsLayout = true
    }

    func showNotRepository(disabled: Bool, isLoading: Bool) {
        mode = .notRepository
        iconView.image = inspectorSymbolImage("arrow.triangle.branch", size: 24, weight: .light)
        iconView.contentTintColor = .quaternaryLabelColor
        titleLabel.stringValue = String(localized: "No Git Repository")
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = Theme.chromePrimaryText
        detailLabel.isHidden = false
        detailLabel.stringValue = String(
            localized: "Initialize the terminal’s current directory to start tracking changes."
        )
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .tertiaryLabelColor
        actionButton.isHidden = false
        actionButton.title = String(localized: "Initialize Repository")
        actionButton.isEnabled = !disabled
        actionButton.contentTintColor = Theme.accent
        progress.setLoading(isLoading)
        needsLayout = true
    }

    func showStatusFailure(_ message: String, isBusy: Bool) {
        mode = .statusFailure
        iconView.image = inspectorSymbolImage("exclamationmark.triangle", size: 24, weight: .light)
        iconView.contentTintColor = NSColor(red: 0.88, green: 0.42, blue: 0.36, alpha: 1)
        titleLabel.stringValue = String(localized: "Git Status Unavailable")
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = Theme.chromePrimaryText
        detailLabel.isHidden = false
        detailLabel.stringValue = message
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        actionButton.isHidden = false
        actionButton.title = String(localized: "Retry")
        actionButton.isEnabled = !isBusy
        progress.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        iconView.frame = NSRect(x: (bounds.width - 28) / 2, y: midY - 48, width: 28, height: 28)
        titleLabel.frame = NSRect(x: 18, y: midY - 14, width: max(0, bounds.width - 36), height: 18)
        detailLabel.frame = NSRect(x: 18, y: midY + 6, width: max(0, bounds.width - 36), height: 36)
        actionButton.sizeToFit()
        actionButton.frame = NSRect(
            x: (bounds.width - actionButton.bounds.width - 16) / 2,
            y: midY + 48,
            width: actionButton.bounds.width + 16,
            height: 24
        )
        progress.frame = NSRect(x: actionButton.frame.minX - 16, y: actionButton.frame.midY - 6, width: 12, height: 12)
    }

    @objc private func handleAction() {
        switch mode {
        case .notRepository: onInitialize?()
        case .statusFailure: onRetry?()
        case .message: break
        }
    }
}

final class AppKitGitChangeListView: NSView {
    struct RowHandlers {
        var openDiff: () -> Void
        var openFile: () -> Void
        var openToSide: () -> Void
        var stage: () -> Void
        var unstage: () -> Void
        var discard: () -> Void
        var copyRelativePath: () -> Void
        var insertInTerminal: (() -> Void)?
        var absolutePath: String
    }

    var preferredWidth: CGFloat = 240
    private(set) var requiredHeight: CGFloat = 0
    var onToggleSection: ((AppKitGitSection) -> Void)?
    var onToggleCommit: ((String) -> Void)?

    private var ordered: [NSView] = []
    private let commitsView = RecentCommitsNSView()
    private var fileNames: [String] = []

    override var isFlipped: Bool { true }

    var debugFileNames: [String] { fileNames }

    func configure(
        merge: [GitStatusModel.Entry],
        staged: [GitStatusModel.Entry],
        changes: [GitStatusModel.Entry],
        commits: [GitStatusModel.RecentCommit],
        mergeCollapsed: Bool,
        stagedCollapsed: Bool,
        changesCollapsed: Bool,
        historyCollapsed: Bool,
        expandedCommitIDs: Set<String>,
        filterText: String,
        totalChangeCount: Int,
        ahead: Int,
        behind: Int,
        isBusy: Bool,
        fontScale: CGFloat,
        hasMoreCommits: Bool,
        isLoadingMore: Bool,
        stageAllLoading: Bool,
        unstageAllLoading: Bool,
        discardAllLoading: Bool,
        loadingEntry: (path: String, operation: AppKitGitPanelView.EntryOperationDebug)?,
        loadMore: @escaping () -> Bool,
        openCommitDiff: @escaping (
            GitStatusModel.RecentCommit,
            GitStatusModel.RecentCommit.FileChange
        ) -> Void,
        rowHandler: @escaping (GitStatusModel.Entry, AppKitGitEntryKind) -> RowHandlers,
        onStageAll: @escaping () -> Void,
        onUnstageAll: @escaping () -> Void,
        onDiscardAll: @escaping () -> Void
    ) {
        ordered.forEach { $0.removeFromSuperview() }
        ordered.removeAll(keepingCapacity: true)
        fileNames.removeAll(keepingCapacity: true)

        let visible = merge.count + staged.count + changes.count
        if totalChangeCount == 0 {
            addArranged(inlinePlaceholder(
                icon: ahead > 0 || behind > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                text: ahead > 0 || behind > 0
                    ? String(localized: "Working tree clean, sync is pending")
                    : String(localized: "Working tree clean"),
                fontScale: fontScale
            ))
        } else if visible == 0 {
            addArranged(inlinePlaceholder(
                icon: "line.3.horizontal.decrease",
                text: String(localized: "No changed files match “\(filterText)”"),
                fontScale: fontScale
            ))
        }

        func addSection(
            _ section: AppKitGitSection,
            title: String,
            count: Int,
            collapsed: Bool,
            actions: [AppKitGitSectionHeaderView.Action],
            entries: [GitStatusModel.Entry],
            kind: AppKitGitEntryKind
        ) {
            guard !entries.isEmpty else { return }
            let header = AppKitGitSectionHeaderView(frame: .zero)
            header.configure(
                title: title,
                count: count,
                isCollapsed: collapsed,
                actions: actions,
                actionsDisabled: isBusy,
                fontScale: fontScale
            )
            header.onToggle = { [weak self] in self?.onToggleSection?(section) }
            addArranged(header)
            guard !collapsed else { return }
            for entry in entries {
                let handlers = rowHandler(entry, kind)
                let status: Character = {
                    switch kind {
                    case .merge: return "U"
                    case .staged: return entry.staged
                    case .unstaged: return entry.unstaged
                    }
                }()
                let loading = loadingEntry
                let state = GitEntryRowDisplayState(
                    fileName: entry.fileName,
                    directory: entry.directory,
                    status: status,
                    kind: kind,
                    disabled: isBusy,
                    isStageLoading: loading?.path == entry.path && loading?.operation == .stage,
                    isUnstageLoading: loading?.path == entry.path && loading?.operation == .unstage,
                    isDiscardLoading: loading?.path == entry.path && loading?.operation == .discard
                )
                let row = AppKitGitEntryRowView(frame: .zero)
                row.configure(
                    entry: entry,
                    state: state,
                    fontScale: fontScale,
                    handlers: handlers
                )
                addArranged(row)
                fileNames.append(entry.fileName)
            }
        }

        addSection(
            .merge,
            title: String(localized: "MERGE CHANGES"),
            count: merge.count,
            collapsed: mergeCollapsed,
            actions: [],
            entries: merge,
            kind: .merge
        )
        addSection(
            .staged,
            title: String(localized: "STAGED CHANGES"),
            count: staged.count,
            collapsed: stagedCollapsed,
            actions: filterText.isEmpty ? [
                .init(
                    systemImage: "minus",
                    help: String(localized: "Unstage All Changes"),
                    isLoading: unstageAllLoading,
                    perform: onUnstageAll
                )
            ] : [],
            entries: staged,
            kind: .staged
        )
        addSection(
            .changes,
            title: String(localized: "CHANGES"),
            count: changes.count,
            collapsed: changesCollapsed,
            actions: filterText.isEmpty ? [
                .init(
                    systemImage: "arrow.uturn.backward",
                    help: String(localized: "Discard All Changes"),
                    isLoading: discardAllLoading,
                    perform: onDiscardAll
                ),
                .init(
                    systemImage: "plus",
                    help: String(localized: "Stage All Changes"),
                    isLoading: stageAllLoading,
                    perform: onStageAll
                ),
            ] : [],
            entries: changes,
            kind: .unstaged
        )

        if filterText.isEmpty, !commits.isEmpty {
            let header = AppKitGitSectionHeaderView(frame: .zero)
            header.configure(
                title: String(localized: "RECENT COMMITS"),
                count: commits.count,
                isCollapsed: historyCollapsed,
                actions: [],
                actionsDisabled: isBusy,
                fontScale: fontScale
            )
            header.onToggle = { [weak self] in self?.onToggleSection?(.history) }
            addArranged(header)
            if !historyCollapsed {
                commitsView.onToggleCommit = { [weak self] id in self?.onToggleCommit?(id) }
                commitsView.onOpenDiff = openCommitDiff
                commitsView.onLoadMore = loadMore
                commitsView.configure(
                    commits: commits,
                    expandedCommitIDs: expandedCommitIDs,
                    fontScale: fontScale,
                    hasMoreCommits: hasMoreCommits,
                    isLoadingMore: isLoadingMore
                )
                addArranged(commitsView)
            }
        }

        layoutList()
    }

    func layoutList() {
        var y: CGFloat = 0
        let width = max(preferredWidth - 12, 0)
        for view in ordered {
            let height: CGFloat
            if view === commitsView {
                height = commitsView.requiredHeight
            } else {
                var measured = view.intrinsicContentSize.height
                if measured == NSView.noIntrinsicMetric || measured <= 0 {
                    measured = 22
                }
                height = measured
            }
            view.frame = NSRect(x: 6, y: y, width: width, height: height)
            y += height
        }
        let nextHeight = y + 8
        if requiredHeight != nextHeight {
            requiredHeight = nextHeight
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: requiredHeight)
    }

    override func layout() {
        super.layout()
        layoutList()
    }

    private func addArranged(_ view: NSView) {
        addSubview(view)
        ordered.append(view)
    }

    private func inlinePlaceholder(icon: String, text: String, fontScale: CGFloat) -> NSView {
        let view = AppKitInlinePlaceholderView(frame: .zero)
        view.configure(icon: icon, text: text, fontScale: fontScale)
        return view
    }
}

extension AppKitGitPanelView {
    enum EntryOperationDebug: Equatable {
        case stage, unstage, discard
    }
}

final class AppKitInlinePlaceholderView: NSView {
    private let iconView = NSImageView(frame: .zero)
    private let label = inspectorLabel()
    private var fontScale: CGFloat = 1

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 72 * fontScale)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        label.alignment = .center
        label.maximumNumberOfLines = 3
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func configure(icon: String, text: String, fontScale: CGFloat) {
        self.fontScale = fontScale
        iconView.image = inspectorSymbolImage(icon, size: 18 * fontScale, weight: .light)
        iconView.contentTintColor = .quaternaryLabelColor
        label.stringValue = text
        label.font = .systemFont(ofSize: 10.5 * fontScale)
        label.textColor = .tertiaryLabelColor
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: (bounds.width - 20) / 2, y: 12, width: 20, height: 20)
        label.frame = NSRect(x: 12, y: 34, width: max(0, bounds.width - 24), height: 32)
    }
}

final class AppKitGitSectionHeaderView: NSView {
    struct Action {
        let systemImage: String
        let help: String
        let isLoading: Bool
        let perform: () -> Void
    }

    var onToggle: (() -> Void)?
    private let chevron = NSImageView(frame: .zero)
    private let titleLabel = inspectorLabel()
    private let countLabel = inspectorLabel()
    private var actionButtons: [AppKitChromeIconButton] = []
    private var actionSpinners: [AppKitMiniProgressView] = []
    private var actions: [Action] = []
    private var isCollapsed = false
    private var isHovering = false
    private var trackingAreaReference: NSTrackingArea?
    private var fontScale: CGFloat = 1
    private var count = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 27)
    }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.imageScaling = .scaleProportionallyDown
        chevron.setAccessibilityElement(false)
        countLabel.wantsLayer = true
        countLabel.layer?.cornerRadius = 8
        countLabel.alignment = .center
        addSubview(chevron)
        addSubview(titleLabel)
        addSubview(countLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        focusRingType = .default
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        count: Int,
        isCollapsed: Bool,
        actions: [Action],
        actionsDisabled: Bool,
        fontScale: CGFloat
    ) {
        self.isCollapsed = isCollapsed
        self.actions = actions
        self.fontScale = fontScale
        self.count = count
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 9.5 * fontScale, weight: .medium)
        titleLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        chevron.image = inspectorSymbolImage("chevron.right", size: 7 * fontScale, weight: .semibold)
        chevron.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        countLabel.isHidden = count <= 0
        countLabel.stringValue = "\(count)"
        countLabel.font = .systemFont(ofSize: 9 * fontScale, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.layer?.backgroundColor = Theme.chromeHover.cgColor
        setAccessibilityLabel("\(title), \(count) items")
        setAccessibilityValue(isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded"))

        actionButtons.forEach { $0.removeFromSuperview() }
        actionSpinners.forEach { $0.removeFromSuperview() }
        actionButtons = []
        actionSpinners = []
        for action in actions {
            let button = AppKitChromeIconButton(
                systemImage: action.systemImage,
                help: action.help,
                iconSize: 9
            )
            button.alphaValue = action.isLoading ? 1 : (actionsDisabled ? 0.3 : (isHovering ? 1 : 0.55))
            button.isEnabled = !actionsDisabled
            button.onAction = action.perform
            button.setAccessibilityLabel(
                action.isLoading
                    ? String(localized: "\(action.help), in progress")
                    : action.help
            )
            let spinner = AppKitMiniProgressView()
            spinner.setLoading(action.isLoading)
            button.alphaValue = action.isLoading ? 0 : button.alphaValue
            addSubview(button)
            addSubview(spinner)
            actionButtons.append(button)
            actionSpinners.append(spinner)
        }
        needsLayout = true
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
        for (button, action) in zip(actionButtons, actions) where !action.isLoading {
            button.alphaValue = button.isEnabled ? 1 : 0.3
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        for (button, action) in zip(actionButtons, actions) where !action.isLoading {
            button.alphaValue = button.isEnabled ? 0.55 : 0.3
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onToggle?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onToggle?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !actions.isEmpty else { return nil }
        let menu = NSMenu()
        for action in actions {
            let item = NSMenuItem(
                title: action.help,
                action: #selector(AppKitMenuTrampoline.run),
                keyEquivalent: ""
            )
            let trampoline = AppKitMenuTrampoline(action.perform)
            item.target = trampoline
            item.representedObject = trampoline
            menu.addItem(item)
        }
        return menu
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 8, y: 11, width: 8, height: 8)
        chevron.frameRotation = isCollapsed ? 0 : 90
        var x: CGFloat = 20
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: x, y: 8, width: titleLabel.bounds.width, height: 14)
        x = titleLabel.frame.maxX + 4
        for (button, spinner) in zip(actionButtons, actionSpinners) {
            button.frame = NSRect(x: x, y: 6, width: 16, height: 16)
            spinner.frame = button.frame
            x += 18
        }
        if !countLabel.isHidden {
            countLabel.sizeToFit()
            let width = countLabel.bounds.width + 10
            countLabel.frame = NSRect(
                x: bounds.width - width - 8,
                y: 8,
                width: width,
                height: 14
            )
        }
    }
}

final class AppKitGitEntryRowView: NSView {
    private let statusLabel = inspectorLabel()
    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = inspectorLabel()
    private let directoryLabel = inspectorLabel()
    private var actionButtons: [AppKitChromeIconButton] = []
    private var actionSpinners: [AppKitMiniProgressView] = []
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false
    private var isFocused = false
    private var fontScale: CGFloat = 1
    private(set) var state: GitEntryRowDisplayState?
    private var entry: GitStatusModel.Entry?
    private var handlers: AppKitGitChangeListView.RowHandlers?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        focusRingType = .default
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        directoryLabel.lineBreakMode = .byTruncatingHead
        addSubview(statusLabel)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(directoryLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }

    func configure(
        entry: GitStatusModel.Entry,
        state: GitEntryRowDisplayState,
        fontScale: CGFloat,
        handlers: AppKitGitChangeListView.RowHandlers
    ) {
        self.entry = entry
        self.state = state
        self.fontScale = fontScale
        self.handlers = handlers
        statusLabel.stringValue = String(state.status)
        statusLabel.font = .monospacedSystemFont(ofSize: 10 * fontScale, weight: .bold)
        statusLabel.textColor = gitStatusIndicatorColor(for: state.status)
        nameLabel.stringValue = state.fileName
        nameLabel.font = .systemFont(ofSize: 11.5 * fontScale)
        nameLabel.textColor = .secondaryLabelColor
        if state.status == "D" {
            let strike = NSAttributedString(
                string: state.fileName,
                attributes: [
                    .font: nameLabel.font as Any,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
            nameLabel.attributedStringValue = strike
        }
        directoryLabel.stringValue = state.directory
        directoryLabel.font = .systemFont(ofSize: 10 * fontScale)
        directoryLabel.textColor = .tertiaryLabelColor
        iconView.image = MaterialFileIcon.image(
            forPath: handlers.absolutePath,
            appearance: effectiveAppearance
        )
        iconView.alphaValue = state.status == "D" ? 0.6 : 1
        setAccessibilityLabel(state.accessibilityLabel)
        setAccessibilityHelp(
            state.kind == .merge
                ? String(localized: "Opens conflict changes")
                : String(localized: "Opens changes")
        )
        rebuildActions()
        refreshChrome()
        needsLayout = true
    }

    func debugClickStage() { handlers?.stage() }
    func debugClickUnstage() { handlers?.unstage() }
    func debugClickDiscard() { handlers?.discard() }
    func debugClickDiff() { handlers?.openDiff() }

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
        refreshChrome()
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshChrome()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isFocused = true
        handlers?.openDiff()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            handlers?.openDiff()
        } else {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        refreshChrome()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        refreshChrome()
        return super.resignFirstResponder()
    }

    override func accessibilityPerformPress() -> Bool {
        handlers?.openDiff()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let state, let handlers, let entry else { return nil }
        let menu = NSMenu()
        addItem(menu, String(localized: "Open Changes"), handlers.openDiff)
        if state.kind == .merge {
            addItem(menu, String(localized: "Open Conflicted File"), handlers.openFile)
        } else {
            addItem(menu, String(localized: "Open File"), handlers.openFile)
        }
        addItem(menu, String(localized: "Open File to the Side"), handlers.openToSide)
        menu.addItem(.separator())
        switch state.kind {
        case .merge:
            addItem(menu, String(localized: "Mark Resolved (Stage)"), handlers.stage, enabled: !state.disabled)
        case .staged:
            addItem(menu, String(localized: "Unstage Changes"), handlers.unstage, enabled: !state.disabled)
        case .unstaged:
            addItem(menu, String(localized: "Stage Changes"), handlers.stage, enabled: !state.disabled)
            let title: String
            if entry.isUntracked || entry.isWorktreeCopy {
                title = String(localized: "Move to Trash…")
            } else if entry.isWorktreeRename {
                title = String(localized: "Undo Rename…")
            } else {
                title = String(localized: "Discard Changes…")
            }
            addItem(menu, title, handlers.discard, enabled: !state.disabled)
        }
        menu.addItem(.separator())
        addItem(menu, String(localized: "Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: handlers.absolutePath)]
            )
        }
        addItem(menu, String(localized: "Copy Path")) {
            inspectorCopyToPasteboard(handlers.absolutePath)
        }
        addItem(menu, String(localized: "Copy Relative Path"), handlers.copyRelativePath)
        if let insert = handlers.insertInTerminal {
            addItem(menu, String(localized: "Insert Absolute Path in Terminal"), insert)
        }
        return menu
    }

    override func layout() {
        super.layout()
        statusLabel.frame = NSRect(x: 8, y: 3, width: 12, height: 16)
        iconView.frame = NSRect(x: 27, y: 4, width: 13, height: 13)
        var trailing = bounds.width - 8
        let showActions = isHovering || isFocused || state?.isStageLoading == true
            || state?.isUnstageLoading == true || state?.isDiscardLoading == true
        if showActions {
            for (button, spinner) in zip(actionButtons, actionSpinners).reversed() {
                trailing -= 18
                button.frame = NSRect(x: trailing, y: 3, width: 16, height: 16)
                spinner.frame = button.frame
            }
        } else {
            actionButtons.forEach { $0.frame = .zero }
            actionSpinners.forEach { $0.frame = .zero }
        }
        nameLabel.sizeToFit()
        let nameWidth = min(nameLabel.bounds.width, max(40, trailing - 48))
        nameLabel.frame = NSRect(x: 45, y: 2, width: nameWidth, height: 18)
        let hideDirectory = isHovering || isFocused
        directoryLabel.isHidden = hideDirectory || (state?.directory.isEmpty ?? true)
        directoryLabel.frame = directoryLabel.isHidden
            ? .zero
            : NSRect(
                x: nameLabel.frame.maxX + 6,
                y: 3,
                width: max(0, trailing - nameLabel.frame.maxX - 10),
                height: 16
            )
    }

    private func rebuildActions() {
        actionButtons.forEach { $0.removeFromSuperview() }
        actionSpinners.forEach { $0.removeFromSuperview() }
        actionButtons = []
        actionSpinners = []
        guard let state, let handlers else { return }
        func add(symbol: String, help: String, loading: Bool, action: @escaping () -> Void) {
            let button = AppKitChromeIconButton(systemImage: symbol, help: help, iconSize: 9)
            button.isEnabled = !state.disabled
            button.onAction = action
            button.setAccessibilityLabel(
                loading ? String(localized: "\(help), in progress") : help
            )
            let spinner = AppKitMiniProgressView()
            spinner.setLoading(loading)
            button.alphaValue = loading ? 0 : 1
            addSubview(button)
            addSubview(spinner)
            actionButtons.append(button)
            actionSpinners.append(spinner)
        }
        switch state.kind {
        case .merge:
            add(symbol: "plus", help: state.stageHelp, loading: state.isStageLoading, action: handlers.stage)
        case .staged:
            add(symbol: "minus", help: state.unstageHelp, loading: state.isUnstageLoading, action: handlers.unstage)
        case .unstaged:
            add(symbol: "arrow.uturn.backward", help: state.discardHelp, loading: state.isDiscardLoading, action: handlers.discard)
            add(symbol: "plus", help: state.stageHelp, loading: state.isStageLoading, action: handlers.stage)
        }
    }

    private func refreshChrome() {
        let active = isHovering || isFocused
        layer?.backgroundColor = (active ? Theme.chromeHover : .clear).cgColor
        let loading = state?.isStageLoading == true
            || state?.isUnstageLoading == true
            || state?.isDiscardLoading == true
        let alpha: CGFloat = loading || active ? 1 : 0.55
        zip(actionButtons, actionSpinners).forEach { button, spinner in
            if spinner.isHidden {
                button.alphaValue = alpha
            }
        }
    }

    private func addItem(
        _ menu: NSMenu,
        _ title: String,
        _ action: @escaping () -> Void,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: #selector(AppKitMenuTrampoline.run), keyEquivalent: "")
        let trampoline = AppKitMenuTrampoline(action)
        item.target = trampoline
        item.representedObject = trampoline
        item.isEnabled = enabled
        menu.addItem(item)
    }
}
