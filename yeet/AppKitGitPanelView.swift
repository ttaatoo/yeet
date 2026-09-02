//
//  AppKitGitPanelView.swift
//  yeet
//

import AppKit

enum AppKitGitEntryKind: Equatable {
    case merge, staged, unstaged
}

struct GitEntryRowDisplayState: Equatable {
    let fileName: String
    let directory: String
    let status: Character
    let kind: AppKitGitEntryKind
    let disabled: Bool
    let isStageLoading: Bool
    let isUnstageLoading: Bool
    let isDiscardLoading: Bool

    var accessibilityLabel: String { "\(fileName), \(gitStatusName(for: status))" }

    var showsStage: Bool { kind != .staged }
    var showsUnstage: Bool { kind == .staged }
    var showsDiscard: Bool { kind == .unstaged }

    var stageHelp: String {
        kind == .merge
            ? String(localized: "Mark Resolved (Stage)")
            : String(localized: "Stage Changes")
    }

    var unstageHelp: String { String(localized: "Unstage Changes") }

    var discardHelp: String { String(localized: "Discard Changes") }

    var destructiveMenuTitle: String {
        switch kind {
        case .unstaged:
            return String(localized: "Discard Changes…")
        default:
            return stageHelp
        }
    }
}

final class AppKitGitPanelView: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    private enum EntryOperation: Equatable {
        case stage, unstage, discard
    }

    private enum OperationTrigger: Equatable {
        case branchMenu, moreMenu, primaryAction, commitMenu, syncButton
        case stageAll, unstageAll, discardAll
        case entry(path: String, operation: EntryOperation)
        case initializeRepository
    }

    private struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }

    private struct PendingDiscard {
        let entry: GitStatusModel.Entry
        let fingerprints: [String: FileFingerprint]
        let branch: String?
        let headOID: String?
    }

    private weak var model: GitStatusModel?
    private weak var session: TerminalSession?
    private var openFile: ((String) -> Void)?
    private var openToSide: ((String) -> Void)?
    private var openDiff: ((GitStatusModel.Entry, Bool) -> Void)?
    private var openCommitDiff: ((
        GitStatusModel.RecentCommit,
        GitStatusModel.RecentCommit.FileChange
    ) -> Void)?

    private var fontScale: CGFloat = 1
    private var commitMessage = ""
    private var pendingDiscard: PendingDiscard?
    private var pendingDiscardAll: [PendingDiscard] = []
    private var mergeCollapsed = false
    private var stagedCollapsed = false
    private var changesCollapsed = false
    private var historyCollapsed = false
    private var expandedCommitIDs: Set<String> = []
    private var filterText = ""
    private var showFilter = false
    private var operationExpanded = false
    private var operationTrigger: OperationTrigger?
    private var lastRootPath = ""
    private var lastRepositoryIdentity = ""

    private let header = NSView()
    private let branchIcon = NSImageView(frame: .zero)
    private let branchProgress = AppKitMiniProgressView()
    private let headerLabel = AppKitInspectorHeaderLabel()
    private let branchButton = NSButton(frame: .zero)
    private let filterToggle = AppKitChromeIconButton(
        systemImage: "line.3.horizontal.decrease",
        help: String(localized: "Filter Changed Files"),
        iconSize: 10
    )
    private let refreshButton = AppKitChromeIconButton(
        systemImage: "arrow.clockwise",
        help: String(localized: "Refresh Git Status"),
        iconSize: 10
    )
    private let moreButton = AppKitChromeIconButton(
        systemImage: "ellipsis",
        help: String(localized: "More Actions…"),
        iconSize: 10
    )
    private let moreProgress = AppKitMiniProgressView()
    private let statusProgress = AppKitMiniProgressView()

    private let trackingBar = NSView()
    private let trackingIcon = NSImageView(frame: .zero)
    private let trackingLabel = inspectorLabel()
    private let behindBadge = inspectorLabel()
    private let aheadBadge = inspectorLabel()

    private let repoOpBanner = NSView()
    private let repoOpIcon = NSImageView(frame: .zero)
    private let repoOpTitle = inspectorLabel()
    private let repoOpSubtitle = inspectorLabel()

    private let failureBanner = NSView()
    private let failureIcon = NSImageView(frame: .zero)
    private let failureTitle = inspectorLabel()
    private let failureToggle = AppKitChromeIconButton(
        systemImage: "chevron.right",
        help: String(localized: "Show Git Output"),
        iconSize: 8
    )
    private let failureDismiss = AppKitChromeIconButton(
        systemImage: "xmark",
        help: String(localized: "Dismiss"),
        iconSize: 8
    )
    private let failureOutput = NSScrollView()
    private let failureText = NSTextView()

    private let commitBox = NSView()
    private let commitScroll = NSScrollView()
    private let commitText = CommitMessageTextView()
    private let commitButton = AppKitAccentButton()
    private let commitMenuButton = AppKitChromeIconButton(
        systemImage: "chevron.down",
        help: String(localized: "Commit Options"),
        iconSize: 8
    )
    private let commitMenuProgress = AppKitMiniProgressView()
    private let syncButton = AppKitAccentButton()

    private let filterBar = NSView()
    private let filterIcon = NSImageView(frame: .zero)
    private let filterField = NSTextField(string: "")
    private let filterClear = AppKitChromeIconButton(
        systemImage: "xmark.circle.fill",
        help: String(localized: "Clear Filter"),
        iconSize: 10
    )

    private let placeholder = AppKitGitPlaceholderView()
    private let scrollView = NSScrollView()
    private let changeList = AppKitGitChangeListView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupChrome()
        setupBanners()
        setupCommitBox()
        setupFilterBar()
        setupList()
        placeholder.onInitialize = { [weak self] in
            self?.performOperation(.initializeRepository) {
                self?.model?.initializeRepository()
            }
        }
        placeholder.onRetry = { [weak self] in self?.model?.refresh() }
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        model: GitStatusModel,
        session: TerminalSession?,
        fontScale: CGFloat,
        openFile: @escaping (String) -> Void,
        openToSide: @escaping (String) -> Void,
        openDiff: @escaping (GitStatusModel.Entry, Bool) -> Void,
        openCommitDiff: @escaping (
            GitStatusModel.RecentCommit,
            GitStatusModel.RecentCommit.FileChange
        ) -> Void
    ) {
        self.model = model
        self.session = session
        self.fontScale = fontScale
        self.openFile = openFile
        self.openToSide = openToSide
        self.openDiff = openDiff
        self.openCommitDiff = openCommitDiff

        if lastRootPath != model.rootPath {
            lastRootPath = model.rootPath
            pendingDiscard = nil
            pendingDiscardAll = []
        }
        if lastRepositoryIdentity != model.repositoryIdentity {
            lastRepositoryIdentity = model.repositoryIdentity
            resetRepositoryDrafts()
        }
        if !model.isBusy { operationTrigger = nil }
        refresh()
    }

    var debugVisibleFileNames: [String] { changeList.debugFileNames }
    var debugFilterText: String { filterText }
    var debugCommitMessage: String { commitMessage }
    var debugShowsFilter: Bool { showFilter }

    func debugSetFilter(_ text: String) {
        showFilter = true
        filterText = text
        filterField.stringValue = text
        refresh()
    }

    func debugSetCommitMessage(_ text: String) {
        commitMessage = text
        commitText.string = text
        refresh()
    }

    func debugStageVisibleEntry(named name: String) {
        guard let entry = filteredChangedEntries.first(where: { $0.fileName == name })
                ?? filteredMergeEntries.first(where: { $0.fileName == name })
        else { return }
        performOperation(.entry(path: entry.path, operation: .stage)) {
            model?.stage(entry)
        }
    }

    func debugUnstageVisibleEntry(named name: String) {
        guard let entry = filteredStagedEntries.first(where: { $0.fileName == name }) else { return }
        performOperation(.entry(path: entry.path, operation: .unstage)) {
            model?.unstage(entry)
        }
    }

    func debugRequestDiscard(named name: String) {
        guard let entry = filteredChangedEntries.first(where: { $0.fileName == name }) else { return }
        pendingDiscard = makePendingDiscard(entry)
        confirmPendingDiscard()
    }

    func debugClickCommit() {
        performPrimaryAction()
    }

    override func layout() {
        super.layout()
        layoutInspector()
    }

    // MARK: - Setup

    private func setupChrome() {
        addSubview(header)
        branchIcon.imageScaling = .scaleProportionallyDown
        header.addSubview(branchIcon)
        header.addSubview(branchProgress)
        header.addSubview(headerLabel)
        header.addSubview(statusProgress)
        header.addSubview(filterToggle)
        header.addSubview(refreshButton)
        header.addSubview(moreButton)
        header.addSubview(moreProgress)
        moreButton.setAccessibilityLabel(String(localized: "More Git Actions"))
        filterToggle.onAction = { [weak self] in
            guard let self else { return }
            self.showFilter.toggle()
            if !self.showFilter { self.filterText = ""; self.filterField.stringValue = "" }
            self.refresh()
        }
        refreshButton.onAction = { [weak self] in self?.model?.refresh() }
        moreButton.onAction = { [weak self] in self?.popMoreMenu() }
        branchButton.isBordered = false
        branchButton.title = ""
        branchButton.target = self
        branchButton.action = #selector(popBranchMenu)
        header.addSubview(branchButton)
    }

    private func setupBanners() {
        addSubview(trackingBar)
        trackingIcon.imageScaling = .scaleProportionallyDown
        trackingBar.addSubview(trackingIcon)
        trackingBar.addSubview(trackingLabel)
        trackingBar.addSubview(behindBadge)
        trackingBar.addSubview(aheadBadge)
        for badge in [behindBadge, aheadBadge] {
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 8
            badge.alignment = .center
        }

        addSubview(repoOpBanner)
        repoOpBanner.wantsLayer = true
        repoOpBanner.layer?.cornerRadius = 6
        repoOpBanner.addSubview(repoOpIcon)
        repoOpBanner.addSubview(repoOpTitle)
        repoOpBanner.addSubview(repoOpSubtitle)
        repoOpTitle.maximumNumberOfLines = 1
        repoOpSubtitle.maximumNumberOfLines = 2

        addSubview(failureBanner)
        failureBanner.wantsLayer = true
        failureBanner.layer?.cornerRadius = 6
        failureBanner.addSubview(failureIcon)
        failureBanner.addSubview(failureTitle)
        failureBanner.addSubview(failureToggle)
        failureBanner.addSubview(failureDismiss)
        failureOutput.drawsBackground = false
        failureOutput.hasVerticalScroller = true
        failureOutput.hasHorizontalScroller = true
        failureOutput.autohidesScrollers = true
        failureText.isEditable = false
        failureText.isSelectable = true
        failureText.drawsBackground = false
        failureText.setAccessibilityLabel(String(localized: "Git Output"))
        failureOutput.documentView = failureText
        failureBanner.addSubview(failureOutput)
        failureToggle.onAction = { [weak self] in
            self?.operationExpanded.toggle()
            self?.refresh()
        }
        failureDismiss.onAction = { [weak self] in
            self?.operationExpanded = false
            self?.model?.dismissOperation()
        }
        failureDismiss.setAccessibilityLabel(String(localized: "Dismiss Git Error"))
    }

    private func setupCommitBox() {
        addSubview(commitBox)
        commitScroll.drawsBackground = false
        commitScroll.hasVerticalScroller = false
        commitScroll.borderType = .noBorder
        commitScroll.wantsLayer = true
        commitScroll.layer?.cornerRadius = 6
        commitText.isRichText = false
        commitText.font = .systemFont(ofSize: 11.5)
        commitText.delegate = self
        commitText.drawsBackground = false
        commitText.onCommandReturn = { [weak self] in self?.performPrimaryAction() }
        commitScroll.documentView = commitText
        commitBox.addSubview(commitScroll)
        commitBox.addSubview(commitButton)
        commitBox.addSubview(commitMenuButton)
        commitBox.addSubview(commitMenuProgress)
        commitBox.addSubview(syncButton)
        commitButton.onAction = { [weak self] in self?.performPrimaryAction() }
        commitMenuButton.onAction = { [weak self] in self?.popCommitMenu() }
        commitMenuButton.setAccessibilityLabel(String(localized: "Commit Options"))
        syncButton.onAction = { [weak self] in
            self?.performOperation(.syncButton) { self?.model?.syncChanges() }
        }
    }

    private func setupFilterBar() {
        addSubview(filterBar)
        filterBar.wantsLayer = true
        filterBar.layer?.cornerRadius = 6
        filterIcon.image = inspectorSymbolImage("magnifyingglass", size: 10)
        filterIcon.contentTintColor = .tertiaryLabelColor
        filterField.isBordered = false
        filterField.focusRingType = .none
        filterField.placeholderString = String(localized: "Filter changed files")
        filterField.delegate = self
        filterClear.onAction = { [weak self] in
            self?.filterText = ""
            self?.filterField.stringValue = ""
            self?.refresh()
        }
        filterClear.setAccessibilityLabel(String(localized: "Clear Git Filter"))
        filterBar.addSubview(filterIcon)
        filterBar.addSubview(filterField)
        filterBar.addSubview(filterClear)
    }

    private func setupList() {
        addSubview(placeholder)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = changeList
        addSubview(scrollView)
        changeList.onToggleSection = { [weak self] section in
            guard let self else { return }
            switch section {
            case .merge: self.mergeCollapsed.toggle()
            case .staged: self.stagedCollapsed.toggle()
            case .changes: self.changesCollapsed.toggle()
            case .history: self.historyCollapsed.toggle()
            }
            self.refresh()
        }
        changeList.onToggleCommit = { [weak self] id in
            guard let self else { return }
            if self.expandedCommitIDs.contains(id) {
                self.expandedCommitIDs.remove(id)
            } else {
                self.expandedCommitIDs.insert(id)
            }
            self.refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        guard let model else { return }
        let scale = fontScale
        headerLabel.configure(
            title: model.isRepo
                ? (model.branch ?? String(localized: "Detached HEAD"))
                : String(localized: "Git"),
            subtitle: model.isRepo ? model.rootPath : model.rootPath,
            fontScale: scale
        )
        branchIcon.image = inspectorSymbolImage(
            "arrow.triangle.branch",
            size: 11 * scale,
            accessibilityDescription: String(localized: "Git")
        )
        branchIcon.contentTintColor = Theme.accent
        let branchLoading = operationIsLoading(.branchMenu)
        branchIcon.isHidden = branchLoading
        branchProgress.setLoading(branchLoading)
        statusProgress.setLoading(model.isResolvingInitialStatus)
        statusProgress.setAccessibilityLabel(String(localized: "Refreshing Git status"))
        filterToggle.isHidden = !model.isRepo
        refreshButton.isHidden = !model.isRepo
        moreButton.isHidden = !model.isRepo
        moreProgress.setLoading(operationIsLoading(.moreMenu))
        moreButton.alphaValue = operationIsLoading(.moreMenu) ? 0 : 1
        refreshButton.alphaValue = (model.isBusy || model.isResolvingInitialStatus) ? 0.4 : 1
        branchButton.toolTip = String(localized: "Switch or Create Branch")
        branchButton.setAccessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD"))")
        )
        branchButton.isHidden = !model.isRepo

        refreshTracking(model)
        refreshRepoOperation(model)
        refreshFailure(model)
        refreshCommitBox(model)
        refreshFilterBar()

        let isRepoContent = model.statusError == nil && model.isRepo
        scrollView.isHidden = !isRepoContent
        placeholder.isHidden = isRepoContent
        if let statusError = model.statusError {
            placeholder.showStatusFailure(statusError, isBusy: model.isBusy || model.isResolvingInitialStatus)
        } else if !model.isRepo {
            if model.isResolvingInitialStatus {
                placeholder.showMessage(
                    icon: "arrow.clockwise",
                    text: String(localized: "Finding repository…"),
                    showsInitialize: false,
                    showsRetry: false
                )
            } else {
                placeholder.showNotRepository(
                    disabled: model.rootPath.isEmpty || model.isBusy,
                    isLoading: operationIsLoading(.initializeRepository)
                )
            }
        } else {
            refreshChangeList(model)
        }
        needsLayout = true
    }

    private func refreshTracking(_ model: GitStatusModel) {
        guard model.isRepo, let branch = model.branch else {
            trackingBar.isHidden = true
            return
        }
        trackingBar.isHidden = false
        trackingIcon.image = inspectorSymbolImage(
            model.hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash",
            size: 9 * fontScale
        )
        trackingIcon.contentTintColor = .secondaryLabelColor
        trackingLabel.stringValue = model.upstream ?? (branch == "detached HEAD"
            ? String(localized: "Detached HEAD")
            : String(localized: "Unpublished branch"))
        trackingLabel.font = .systemFont(ofSize: 9.5 * fontScale)
        trackingLabel.textColor = .secondaryLabelColor
        trackingLabel.lineBreakMode = .byTruncatingMiddle
        configureBadge(behindBadge, text: model.behind > 0 ? "↓\(model.behind)" : nil)
        behindBadge.setAccessibilityLabel(String(localized: "\(model.behind) incoming commits"))
        configureBadge(aheadBadge, text: model.ahead > 0 ? "↑\(model.ahead)" : nil)
        aheadBadge.setAccessibilityLabel(String(localized: "\(model.ahead) outgoing commits"))
        trackingBar.setAccessibilityElement(true)
        trackingBar.setAccessibilityRole(.group)
    }

    private func refreshRepoOperation(_ model: GitStatusModel) {
        guard let current = model.repositoryOperation else {
            repoOpBanner.isHidden = true
            return
        }
        repoOpBanner.isHidden = false
        let color = NSColor(red: 0.74, green: 0.55, blue: 1.0, alpha: 1)
        repoOpBanner.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        repoOpIcon.image = inspectorSymbolImage("arrow.triangle.merge", size: 10 * fontScale, weight: .semibold)
        repoOpIcon.contentTintColor = color
        repoOpTitle.stringValue = current
        repoOpTitle.font = .systemFont(ofSize: 10.5 * fontScale, weight: .medium)
        repoOpTitle.textColor = color
        repoOpSubtitle.stringValue = model.mergeEntries.isEmpty
            ? String(localized: "Finish or abort from the terminal")
            : String(
                localized: "Resolve and stage \(model.mergeEntries.count) conflicted files",
                comment: "Git merge guidance. The placeholder is the number of conflicted files."
            )
        repoOpSubtitle.font = .systemFont(ofSize: 9.5 * fontScale)
        repoOpSubtitle.textColor = .secondaryLabelColor
    }

    private func refreshFailure(_ model: GitStatusModel) {
        guard let operation = model.operation, case .failed = operation.state else {
            failureBanner.isHidden = true
            return
        }
        failureBanner.isHidden = false
        let color = NSColor(red: 0.88, green: 0.42, blue: 0.36, alpha: 1)
        failureBanner.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        failureIcon.image = inspectorSymbolImage("exclamationmark.triangle.fill", size: 10 * fontScale)
        failureIcon.contentTintColor = color
        failureTitle.stringValue = operation.statusLabel
        failureTitle.font = .systemFont(ofSize: 10.5 * fontScale, weight: .medium)
        failureTitle.textColor = color
        failureToggle.isHidden = operation.output.isEmpty
        failureToggle.configure(
            systemImage: "chevron.right",
            help: operationExpanded
                ? String(localized: "Hide Git Output")
                : String(localized: "Show Git Output"),
            iconSize: 8
        )
        failureOutput.isHidden = !operationExpanded || operation.output.isEmpty
        if operationExpanded {
            failureText.string = operation.output
            failureText.font = .monospacedSystemFont(ofSize: 9 * fontScale, weight: .regular)
            failureText.textColor = color
        }
    }

    private func refreshCommitBox(_ model: GitStatusModel) {
        commitBox.isHidden = !model.isRepo || model.statusError != nil
        if commitText.string != commitMessage {
            commitText.string = commitMessage
        }
        commitText.font = .systemFont(ofSize: 11.5 * fontScale)
        commitScroll.layer?.backgroundColor = Theme.chromeHover.cgColor
        commitText.insertionPointColor = Theme.chromePrimaryText
        let placeholder = commitFieldPlaceholder(model)
        commitText.setAccessibilityLabel(placeholder)

        let showSync = showSyncButton(model)
        let showCommit = !showSync || canCommit(includeAll: false)
        commitButton.isHidden = !showCommit
        commitMenuButton.isHidden = !showCommit
        commitButton.configure(
            icon: "checkmark",
            title: commitButtonTitle(model),
            enabled: canCommit(includeAll: false),
            isLoading: operationIsLoading(.primaryAction),
            help: String(localized: "Commit staged changes (⌘Return)"),
            fontScale: fontScale
        )
        commitMenuProgress.setLoading(operationIsLoading(.commitMenu))
        commitMenuButton.alphaValue = operationIsLoading(.commitMenu) ? 0 : 1
        syncButton.isHidden = !showSync
        syncButton.configure(
            icon: "arrow.triangle.2.circlepath",
            title: syncButtonTitle(model),
            enabled: !model.isBusy,
            isLoading: operationIsLoading(.syncButton),
            help: String(localized: "Pull remote commits, then push local ones"),
            fontScale: fontScale
        )
    }

    private func refreshFilterBar() {
        filterBar.isHidden = !showFilter || scrollView.isHidden
        filterBar.layer?.backgroundColor = Theme.chromeHover.cgColor
        filterField.font = .systemFont(ofSize: 11 * fontScale)
        filterClear.isHidden = filterText.isEmpty
    }

    private func refreshChangeList(_ model: GitStatusModel) {
        changeList.configure(
            merge: filteredMergeEntries,
            staged: filteredStagedEntries,
            changes: filteredChangedEntries,
            commits: filterText.isEmpty ? model.recentCommits : [],
            mergeCollapsed: mergeCollapsed,
            stagedCollapsed: stagedCollapsed,
            changesCollapsed: changesCollapsed,
            historyCollapsed: historyCollapsed,
            expandedCommitIDs: expandedCommitIDs,
            filterText: filterText,
            totalChangeCount: model.totalChangeCount,
            ahead: model.ahead,
            behind: model.behind,
            isBusy: model.isBusy,
            fontScale: fontScale,
            hasMoreCommits: model.hasMoreRecentCommits,
            isLoadingMore: model.isLoadingMoreCommits,
            stageAllLoading: operationIsLoading(.stageAll),
            unstageAllLoading: operationIsLoading(.unstageAll),
            discardAllLoading: operationIsLoading(.discardAll),
            loadingEntry: loadingEntryDebug(),
            loadMore: { [weak model] in model?.loadMoreCommits() ?? false },
            openCommitDiff: { [weak self] commit, file in self?.openCommitDiff?(commit, file) },
            rowHandler: { [weak self] entry, kind in
                self?.handlers(for: entry, kind: kind) ?? AppKitGitChangeListView.RowHandlers(
                    openDiff: {},
                    openFile: {},
                    openToSide: {},
                    stage: {},
                    unstage: {},
                    discard: {},
                    copyRelativePath: {},
                    insertInTerminal: nil,
                    absolutePath: entry.path
                )
            },
            onStageAll: { [weak self] in
                self?.performOperation(.stageAll) { self?.model?.stageAll() }
            },
            onUnstageAll: { [weak self] in
                self?.performOperation(.unstageAll) { self?.model?.unstageAll() }
            },
            onDiscardAll: { [weak self] in self?.requestDiscardAll() }
        )
    }

    private func currentLoadingEntry() -> (path: String, operation: EntryOperation)? {
        if case .entry(let path, let operation) = operationTrigger, model?.isBusy == true {
            return (path, operation)
        }
        return nil
    }

    private func loadingEntryDebug() -> (path: String, operation: EntryOperationDebug)? {
        guard let loading = currentLoadingEntry() else { return nil }
        let operation: EntryOperationDebug
        switch loading.operation {
        case .stage: operation = .stage
        case .unstage: operation = .unstage
        case .discard: operation = .discard
        }
        return (loading.path, operation)
    }

    // MARK: - Layout

    private func layoutInspector() {
        let scale = fontScale
        var y: CGFloat = 0
        header.frame = NSRect(x: 0, y: y, width: bounds.width, height: 36)
        layoutHeader()
        y += 36

        if !failureBanner.isHidden {
            let extra: CGFloat = failureOutput.isHidden ? 0 : 96
            failureBanner.frame = NSRect(x: 10, y: y, width: max(0, bounds.width - 20), height: 32 + extra)
            layoutFailure()
            y += 32 + extra + 7
        }
        if !trackingBar.isHidden {
            trackingBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: 17)
            layoutTracking()
            y += 23
        }
        if !repoOpBanner.isHidden {
            repoOpBanner.frame = NSRect(x: 10, y: y, width: max(0, bounds.width - 20), height: 44)
            layoutRepoOp()
            y += 51
        }
        if !commitBox.isHidden {
            let commitHeight = commitBoxHeight()
            commitBox.frame = NSRect(x: 0, y: y, width: bounds.width, height: commitHeight)
            layoutCommitBox()
            y += commitHeight + 8
        }
        if !filterBar.isHidden {
            filterBar.frame = NSRect(x: 10, y: y, width: max(0, bounds.width - 20), height: 26)
            layoutFilterBar()
            y += 30
        }

        let remaining = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        placeholder.frame = remaining
        scrollView.frame = remaining
        changeList.preferredWidth = remaining.width
        changeList.layoutList()
        let docHeight = max(changeList.requiredHeight, remaining.height)
        changeList.frame = NSRect(x: 0, y: 0, width: remaining.width, height: docHeight)
        _ = scale
    }

    private func layoutHeader() {
        var x = bounds.width - 12
        func place(_ view: NSView, size: CGFloat = 18, hidden: Bool) {
            if hidden {
                view.frame = .zero
                return
            }
            x -= size
            view.frame = NSRect(x: x, y: 9, width: size, height: 18)
            x -= 4
        }
        place(moreProgress, size: 12, hidden: moreProgress.isHidden)
        place(moreButton, hidden: moreButton.isHidden)
        place(refreshButton, hidden: refreshButton.isHidden)
        place(filterToggle, hidden: filterToggle.isHidden)
        place(statusProgress, size: 12, hidden: statusProgress.isHidden)
        branchIcon.frame = NSRect(x: 12, y: 12, width: 14, height: 14)
        branchProgress.frame = branchIcon.frame
        headerLabel.frame = NSRect(x: 32, y: 4, width: max(0, x - 36), height: 28)
        branchButton.frame = headerLabel.frame
    }

    private func layoutTracking() {
        trackingIcon.frame = NSRect(x: 12, y: 2, width: 12, height: 12)
        var trailing = bounds.width - 12
        func placeBadge(_ badge: NSTextField) {
            guard !badge.isHidden else { return }
            badge.sizeToFit()
            let width = badge.bounds.width + 10
            badge.frame = NSRect(x: trailing - width, y: 0, width: width, height: 17)
            trailing -= width + 4
        }
        placeBadge(aheadBadge)
        placeBadge(behindBadge)
        trackingLabel.frame = NSRect(x: 30, y: 0, width: max(0, trailing - 34), height: 17)
    }

    private func layoutRepoOp() {
        repoOpIcon.frame = NSRect(x: 8, y: 14, width: 14, height: 14)
        repoOpTitle.frame = NSRect(x: 28, y: 22, width: max(0, repoOpBanner.bounds.width - 36), height: 14)
        repoOpSubtitle.frame = NSRect(x: 28, y: 6, width: max(0, repoOpBanner.bounds.width - 36), height: 14)
    }

    private func layoutFailure() {
        failureIcon.frame = NSRect(x: 8, y: failureBanner.bounds.height - 22, width: 14, height: 14)
        failureDismiss.frame = NSRect(
            x: failureBanner.bounds.width - 24,
            y: failureBanner.bounds.height - 24,
            width: 16, height: 16
        )
        failureToggle.frame = NSRect(
            x: failureBanner.bounds.width - 44,
            y: failureBanner.bounds.height - 24,
            width: 16, height: 16
        )
        failureTitle.frame = NSRect(
            x: 28,
            y: failureBanner.bounds.height - 24,
            width: max(0, failureBanner.bounds.width - 80),
            height: 16
        )
        failureOutput.frame = failureOutput.isHidden
            ? .zero
            : NSRect(x: 8, y: 6, width: max(0, failureBanner.bounds.width - 16), height: 90)
        failureText.frame = NSRect(
            x: 0, y: 0,
            width: max(failureOutput.contentSize.width, 200),
            height: 90
        )
    }

    private func commitBoxHeight() -> CGFloat {
        var height: CGFloat = 44
        if !commitButton.isHidden { height += 30 }
        if !syncButton.isHidden { height += 30 }
        return height
    }

    private func layoutCommitBox() {
        commitScroll.frame = NSRect(x: 10, y: 0, width: max(0, bounds.width - 20), height: 36)
        commitText.frame = NSRect(x: 8, y: 4, width: max(0, commitScroll.bounds.width - 16), height: 28)
        var y: CGFloat = 42
        if !commitButton.isHidden {
            commitMenuButton.frame = NSRect(x: bounds.width - 34, y: y, width: 24, height: 24)
            commitMenuProgress.frame = commitMenuButton.frame
            commitButton.frame = NSRect(x: 10, y: y, width: max(0, bounds.width - 48), height: 24)
            y += 30
        } else {
            commitButton.frame = .zero
            commitMenuButton.frame = .zero
        }
        syncButton.frame = syncButton.isHidden
            ? .zero
            : NSRect(x: 10, y: y, width: max(0, bounds.width - 20), height: 24)
    }

    private func layoutFilterBar() {
        filterIcon.frame = NSRect(x: 8, y: 6, width: 12, height: 12)
        filterClear.frame = filterClear.isHidden
            ? .zero
            : NSRect(x: filterBar.bounds.width - 22, y: 4, width: 18, height: 18)
        let trailing = filterClear.isHidden ? filterBar.bounds.width - 8 : filterClear.frame.minX - 4
        filterField.frame = NSRect(x: 26, y: 4, width: max(0, trailing - 26), height: 18)
    }

    // MARK: - Filtering / commit helpers

    private var filteredMergeEntries: [GitStatusModel.Entry] {
        (model?.mergeEntries ?? []).filter(matchesFilter)
    }

    private var filteredStagedEntries: [GitStatusModel.Entry] {
        (model?.stagedEntries ?? []).filter(matchesFilter)
    }

    private var filteredChangedEntries: [GitStatusModel.Entry] {
        (model?.changedEntries ?? []).filter(matchesFilter)
    }

    private func matchesFilter(_ entry: GitStatusModel.Entry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)
    }

    private func showSyncButton(_ model: GitStatusModel) -> Bool {
        model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0)
    }

    private func syncButtonTitle(_ model: GitStatusModel) -> String {
        var title = String(localized: "Sync Changes")
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }

    private func commitButtonTitle(_ model: GitStatusModel) -> String {
        guard !model.stagedEntries.isEmpty else {
            return String(localized: "Commit Staged")
        }
        return String(
            localized: "Commit \(model.stagedEntries.count) Staged Files",
            comment: "Commit button title. The placeholder is the number of staged files."
        )
    }

    private func commitFieldPlaceholder(_ model: GitStatusModel) -> String {
        if model.stagedEntries.isEmpty {
            return model.recentCommits.isEmpty
                ? String(localized: "Message (stage changes to use ⌘⏎)")
                : String(localized: "Message (stage changes to use ⌘⏎, or choose Amend)")
        }
        if let branch = model.branch {
            return String(
                localized: "Message (⌘⏎ to commit on “\(branch)”)",
                comment: "Commit message placeholder. The placeholder is the current branch name."
            )
        }
        return String(localized: "Message (⌘⏎ to commit)")
    }

    private func canCommit(includeAll: Bool) -> Bool {
        guard let model else { return false }
        let hasEligibleChanges = includeAll
            ? (!model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
            : !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func canAmend(includeAll: Bool) -> Bool {
        guard let model else { return false }
        let hasCommit = !model.recentCommits.isEmpty
        let hasEligibleChanges = !includeAll
            || !model.changedEntries.isEmpty
            || !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func performPrimaryAction() {
        performCommit(includeAll: false, trigger: .primaryAction)
    }

    private func performCommit(
        includeAll: Bool,
        amend: Bool = false,
        trigger: OperationTrigger
    ) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        performOperation(trigger) { [weak self] in
            self?.model?.commit(message: submittedMessage, includeAll: includeAll, amend: amend) { success in
                if success, self?.commitMessage == submittedMessage {
                    self?.commitMessage = ""
                    self?.commitText.string = ""
                }
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        commitMessage = commitText.string
        if let model {
            refreshCommitBox(model)
            needsLayout = true
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === filterField {
            filterText = filterField.stringValue
            refresh()
        }
    }

    // MARK: - Row actions

    private func handlers(
        for entry: GitStatusModel.Entry,
        kind: AppKitGitEntryKind
    ) -> AppKitGitChangeListView.RowHandlers {
        let stageTrigger = OperationTrigger.entry(path: entry.path, operation: .stage)
        let unstageTrigger = OperationTrigger.entry(path: entry.path, operation: .unstage)
        let discardTrigger = OperationTrigger.entry(path: entry.path, operation: .discard)
        return AppKitGitChangeListView.RowHandlers(
            openDiff: { [weak self] in
                guard let self, let model = self.model, model.isCurrent(entry) else { return }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") {
                    diffEntry.origPath = nil
                }
                self.openDiff?(diffEntry, kind == .staged)
            },
            openFile: { [weak self] in self?.openIfPossible(entry) },
            openToSide: { [weak self] in self?.openIfPossible(entry, toSide: true) },
            stage: { [weak self] in
                self?.performOperation(stageTrigger) { self?.model?.stage(entry) }
            },
            unstage: { [weak self] in
                self?.performOperation(unstageTrigger) { self?.model?.unstage(entry) }
            },
            discard: { [weak self] in
                self?.pendingDiscard = self?.makePendingDiscard(entry)
                self?.confirmPendingDiscard()
            },
            copyRelativePath: { copyToPasteboard(entry.path) },
            insertInTerminal: session.map { session in
                { [weak self] in
                    guard let self, let model = self.model else { return }
                    session.sendCommand(POSIXShell.quote(model.absolutePath(for: entry)) + " ")
                }
            },
            absolutePath: model?.absolutePath(for: entry) ?? entry.path
        )
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry, toSide: Bool = false) {
        guard let model, model.isCurrent(entry) else { return }
        let path = model.absolutePath(for: entry)
        guard FileManager.default.fileExists(atPath: path) else { return }
        if toSide { openToSide?(path) } else { openFile?(path) }
    }

    // MARK: - Discard

    private func discardTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "" }
        if entry.isUntracked {
            return String(
                localized: "Delete \(entry.fileName)? Its contents will move to the Trash.",
                comment: "Discard confirmation. The placeholder is an untracked file name."
            )
        }
        if entry.isWorktreeRename, let original = entry.origPath {
            return String(
                localized: "Undo this rename? \(entry.fileName) will move to the Trash and \((original as NSString).lastPathComponent) will be restored.",
                comment: "Rename discard confirmation. The placeholders are the new and old file names."
            )
        }
        if entry.isWorktreeCopy {
            return String(
                localized: "Discard this copy? \(entry.fileName) will move to the Trash.",
                comment: "Copy discard confirmation. The placeholder is a file name."
            )
        }
        return String(
            localized: "Discard changes in \(entry.fileName)?",
            comment: "Discard confirmation. The placeholder is a file name."
        )
    }

    private func discardActionTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return String(localized: "Discard Changes") }
        if entry.isUntracked || entry.isWorktreeCopy {
            return String(localized: "Move to Trash")
        }
        if entry.isWorktreeRename { return String(localized: "Undo Rename") }
        return String(localized: "Discard Changes")
    }

    private func makePendingDiscard(_ entry: GitStatusModel.Entry) -> PendingDiscard {
        PendingDiscard(
            entry: entry,
            fingerprints: GitStatusModel.discardFingerprints(for: entry) { path in
                fileFingerprint(at: absolutePath(path, for: entry))
            },
            branch: model?.branch,
            headOID: model?.headOID
        )
    }

    private func discardSnapshotIsCurrent(_ pending: PendingDiscard) -> Bool {
        guard let model else { return false }
        return model.isCurrent(pending.entry)
            && model.branch == pending.branch
            && model.headOID == pending.headOID
            && model.changedEntries.contains(pending.entry)
            && pending.fingerprints.allSatisfy { path, fingerprint in
                fileFingerprint(at: absolutePath(path, for: pending.entry)) == fingerprint
            }
    }

    private func absolutePath(_ path: String, for entry: GitStatusModel.Entry) -> String {
        let root = entry.repositoryRoot.isEmpty ? (model?.repoRoot ?? "") : entry.repositoryRoot
        return (root as NSString).appendingPathComponent(path)
    }

    private func fileFingerprint(at path: String) -> FileFingerprint {
        let fm = FileManager.default
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: path)
        guard linkDestination != nil || fm.fileExists(atPath: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        return FileFingerprint(
            exists: true,
            size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            symbolicLinkDestination: linkDestination
        )
    }

    private func confirmPendingDiscard() {
        guard let pending = pendingDiscard else { return }
        Task { @MainActor in
            let approved = await WorkspaceAlert.confirm(
                message: discardTitle(for: pending.entry),
                informative: "",
                confirmTitle: discardActionTitle(for: pending.entry),
                on: window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
            if approved {
                if discardSnapshotIsCurrent(pending) {
                    performOperation(
                        .entry(path: pending.entry.path, operation: .discard)
                    ) {
                        model?.discard(pending.entry)
                    }
                } else {
                    model?.cancelStaleDiscard()
                }
            }
            pendingDiscard = nil
        }
    }

    private func requestDiscardAll() {
        pendingDiscardAll = (model?.changedEntries ?? []).map(makePendingDiscard)
        guard !pendingDiscardAll.isEmpty else { return }
        let count = pendingDiscardAll.count
        Task { @MainActor in
            let approved = await WorkspaceAlert.confirm(
                message: String(
                    localized: "Discard the \(count) reviewed changes? Untracked and moved files go to the Trash."
                ),
                informative: "",
                confirmTitle: String(localized: "Discard All Changes"),
                on: window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
            let snapshot = pendingDiscardAll
            if approved {
                if !snapshot.isEmpty && snapshot.allSatisfy(discardSnapshotIsCurrent) {
                    performOperation(.discardAll) {
                        model?.discardChanges(snapshot.map(\.entry))
                    }
                } else {
                    model?.cancelStaleDiscard()
                }
            }
            pendingDiscardAll = []
        }
    }

    // MARK: - Menus / operations

    @objc private func popBranchMenu() {
        guard let model, !model.isBusy else { return }
        let menu = NSMenu()
        for branch in model.branches {
            let item = NSMenuItem(
                title: branch,
                action: #selector(switchBranchAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = branch
            item.state = branch == model.branch ? .on : .off
            item.isEnabled = branch != model.branch && !model.isBusy
            menu.addItem(item)
        }
        if !model.branches.isEmpty { menu.addItem(.separator()) }
        let create = NSMenuItem(
            title: String(localized: "Create New Branch…"),
            action: #selector(createBranchAction),
            keyEquivalent: ""
        )
        create.target = self
        create.isEnabled = !model.isBusy
        menu.addItem(create)
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: header.bounds.height), in: header)
    }

    @objc private func switchBranchAction(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String else { return }
        confirmSwitchBranch(branch)
    }

    @objc private func createBranchAction() {
        presentCreateBranchDialog()
    }

    private func popMoreMenu() {
        guard let model else { return }
        let menu = NSMenu()
        addMenuItem(menu, String(localized: "Fetch"), enabled: !model.isBusy && !model.remotes.isEmpty) { [weak self] in
            self?.performOperation(.moreMenu) { self?.model?.fetch() }
        }
        addMenuItem(
            menu,
            String(localized: "Pull (Fast-forward Only)"),
            enabled: !model.isBusy && model.hasUpstream
        ) { [weak self] in
            self?.performOperation(.moreMenu) { self?.model?.pull() }
        }
        if model.hasUpstream {
            addMenuItem(menu, String(localized: "Push"), enabled: !model.isBusy) { [weak self] in
                self?.performOperation(.moreMenu) { self?.model?.push() }
            }
        } else if model.remotes.count > 1 {
            let publish = NSMenuItem(title: String(localized: "Publish Branch to"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for remote in model.remotes {
                addMenuItem(submenu, remote, enabled: !model.isBusy) { [weak self] in
                    self?.performOperation(.moreMenu) { self?.model?.publish(to: remote) }
                }
            }
            publish.submenu = submenu
            publish.isEnabled = !model.isBusy && model.branch != "detached HEAD"
            menu.addItem(publish)
        } else {
            addMenuItem(
                menu,
                String(localized: "Publish Branch"),
                enabled: !model.isBusy && !model.remotes.isEmpty && model.branch != "detached HEAD"
            ) { [weak self] in
                self?.performOperation(.moreMenu) { self?.model?.push() }
            }
        }
        addMenuItem(
            menu,
            String(localized: "Sync Changes"),
            enabled: !model.isBusy && !model.remotes.isEmpty
                && (model.hasUpstream || model.remotes.count == 1)
                && model.branch != "detached HEAD"
        ) { [weak self] in
            self?.confirmSyncChanges()
        }
        menu.addItem(.separator())
        addMenuItem(
            menu,
            String(localized: "Stash All Changes"),
            enabled: !model.isBusy && model.totalChangeCount > 0
        ) { [weak self] in
            self?.performOperation(.moreMenu) { self?.model?.stash(includeUntracked: true) }
        }
        let popTitle = model.stashCount == 1
            ? String(localized: "Pop Stash")
            : String(localized: "Pop Stash (\(model.stashCount))")
        addMenuItem(menu, popTitle, enabled: !model.isBusy && model.stashCount > 0) { [weak self] in
            self?.confirmStashPop()
        }
        menu.addItem(.separator())
        addMenuItem(
            menu,
            String(localized: "Copy Changed Paths"),
            enabled: model.totalChangeCount > 0
        ) { [weak self] in self?.copyChangedPaths() }
        addMenuItem(menu, String(localized: "Copy Repository Path")) { [weak self] in
            copyToPasteboard(self?.model?.repoRoot ?? "")
        }
        addMenuItem(menu, String(localized: "Reveal Repository in Finder")) { [weak self] in
            guard let root = self?.model?.repoRoot, !root.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    private func popCommitMenu() {
        let menu = NSMenu()
        addMenuItem(menu, String(localized: "Commit Staged"), enabled: canCommit(includeAll: false)) { [weak self] in
            self?.performCommit(includeAll: false, trigger: .commitMenu)
        }
        addMenuItem(menu, String(localized: "Stage All & Commit"), enabled: canCommit(includeAll: true)) { [weak self] in
            self?.performCommit(includeAll: true, trigger: .commitMenu)
        }
        menu.addItem(.separator())
        addMenuItem(menu, String(localized: "Amend Last Commit"), enabled: canAmend(includeAll: false)) { [weak self] in
            self?.performCommit(includeAll: false, amend: true, trigger: .commitMenu)
        }
        addMenuItem(menu, String(localized: "Stage All & Amend"), enabled: canAmend(includeAll: true)) { [weak self] in
            self?.performCommit(includeAll: true, amend: true, trigger: .commitMenu)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: commitMenuButton.bounds.height), in: commitMenuButton)
    }

    private func addMenuItem(
        _ menu: NSMenu,
        _ title: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        let item = NSMenuItem(title: title, action: #selector(AppKitMenuTrampoline.run), keyEquivalent: "")
        let trampoline = AppKitMenuTrampoline(action)
        item.target = trampoline
        item.representedObject = trampoline
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func presentCreateBranchDialog() {
        guard let model, !model.isBusy else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Create New Branch")
        alert.informativeText = String(localized: "Enter a name for the new branch.")
        let field = NSTextField(string: "")
        field.placeholderString = String(localized: "Branch name")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        let create = alert.addButton(withTitle: String(localized: "Create"))
        create.keyEquivalent = "\r"
        create.isEnabled = false
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        let validator = NonemptyTextFieldValidator(button: create)
        field.delegate = validator
        alert.window.initialFirstResponder = field
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            _ = validator
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            guard GitRefName.isAcceptableUserInput(name) else { return }
            Task { @MainActor in
                if (self?.model?.totalChangeCount ?? 0) > 0 {
                    let approved = await WorkspaceAlert.confirm(
                        message: String(localized: "Create branch \(name)?"),
                        informative: String(
                            localized: "This worktree has uncommitted changes. The new branch will include them."
                        ),
                        confirmTitle: String(localized: "Create"),
                        on: self?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                    )
                    guard approved else { return }
                }
                self?.performOperation(.branchMenu) { self?.model?.createBranch(named: name) }
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func confirmSwitchBranch(_ branch: String) {
        Task { @MainActor in
            if (model?.totalChangeCount ?? 0) > 0 {
                let approved = await WorkspaceAlert.confirm(
                    message: String(localized: "Switch to \(branch)?"),
                    informative: String(
                        localized: "This worktree has uncommitted changes. Switching branches may fail or carry those changes with you."
                    ),
                    confirmTitle: String(localized: "Switch"),
                    on: window ?? NSApp.keyWindow ?? NSApp.mainWindow
                )
                guard approved else { return }
            }
            performOperation(.branchMenu) { model?.switchBranch(to: branch) }
        }
    }

    private func confirmSyncChanges() {
        guard let model else { return }
        Task { @MainActor in
            let informative: String
            if model.hasUpstream {
                informative = String(
                    localized: "Pull (fast-forward only) then push.\nThis branch is ahead by \(model.ahead) and behind by \(model.behind)."
                )
            } else {
                informative = String(localized: "This branch has no upstream. Sync will publish it to the remote.")
            }
            let approved = await WorkspaceAlert.confirm(
                message: String(localized: "Sync changes?"),
                informative: informative,
                confirmTitle: String(localized: "Sync"),
                on: window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
            guard approved else { return }
            performOperation(.moreMenu) { self.model?.syncChanges() }
        }
    }

    private func confirmStashPop() {
        Task { @MainActor in
            if (model?.totalChangeCount ?? 0) > 0 {
                let approved = await WorkspaceAlert.confirm(
                    message: String(localized: "Pop the latest stash?"),
                    informative: String(
                        localized: "This worktree already has uncommitted changes. Popping a stash may conflict with them."
                    ),
                    confirmTitle: String(localized: "Pop Stash"),
                    on: window ?? NSApp.keyWindow ?? NSApp.mainWindow
                )
                guard approved else { return }
            }
            performOperation(.moreMenu) { model?.stashPop() }
        }
    }

    private func performOperation(_ trigger: OperationTrigger, _ action: () -> Void) {
        operationExpanded = false
        operationTrigger = trigger
        action()
        if model?.isBusy != true { operationTrigger = nil }
        refresh()
    }

    private func operationIsLoading(_ trigger: OperationTrigger) -> Bool {
        model?.isBusy == true && operationTrigger == trigger
    }

    private func copyChangedPaths() {
        guard let model else { return }
        let paths = Set(
            (model.mergeEntries + model.stagedEntries + model.changedEntries).map(\.path)
        ).sorted()
        copyToPasteboard(paths.joined(separator: "\n"))
    }

    private func resetRepositoryDrafts() {
        commitMessage = ""
        commitText.string = ""
        filterText = ""
        filterField.stringValue = ""
        showFilter = false
        operationExpanded = false
        operationTrigger = nil
        pendingDiscard = nil
        pendingDiscardAll = []
        mergeCollapsed = false
        stagedCollapsed = false
        changesCollapsed = false
        historyCollapsed = false
        expandedCommitIDs.removeAll()
    }

    private func configureBadge(_ badge: NSTextField, text: String?) {
        guard let text else {
            badge.isHidden = true
            return
        }
        badge.isHidden = false
        badge.stringValue = text
        badge.font = .systemFont(ofSize: 10 * fontScale, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.layer?.backgroundColor = Theme.chromeHover.cgColor
    }
}

final class NonemptyTextFieldValidator: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?

    init(button: NSButton) {
        self.button = button
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        button?.isEnabled = GitRefName.isAcceptableUserInput(field.stringValue)
    }
}

final class CommitMessageTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

final class AppKitAccentButton: NSView {
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = inspectorLabel()
    private let progress = AppKitMiniProgressView()
    var onAction: (() -> Void)?
    private var enabled = true

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(progress)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        focusRingType = .default
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        icon: String,
        title: String,
        enabled: Bool,
        isLoading: Bool,
        help: String,
        fontScale: CGFloat
    ) {
        self.enabled = enabled
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11 * fontScale, weight: .medium)
        titleLabel.textColor = .white
        iconView.image = inspectorSymbolImage(icon, size: 10 * fontScale, weight: .semibold)
        iconView.contentTintColor = .white
        iconView.isHidden = isLoading
        progress.setLoading(isLoading)
        alphaValue = (enabled || isLoading) ? 1 : 0.45
        layer?.backgroundColor = Theme.accent.withAlphaComponent(enabled || isLoading ? 0.85 : 0.3).cgColor
        toolTip = help
        setAccessibilityLabel(isLoading ? String(localized: "\(title), in progress") : title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        titleLabel.sizeToFit()
        let content = 14 + 5 + titleLabel.bounds.width
        var x = max(8, (bounds.width - content) / 2)
        iconView.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: 12, height: 12)
        progress.frame = iconView.frame
        x += 17
        titleLabel.frame = NSRect(
            x: x,
            y: (bounds.height - titleLabel.bounds.height) / 2,
            width: titleLabel.bounds.width,
            height: titleLabel.bounds.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        window?.makeFirstResponder(self)
        onAction?()
    }

    override func keyDown(with event: NSEvent) {
        if enabled, event.keyCode == 36 || event.keyCode == 49 {
            onAction?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        onAction?()
        return true
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
