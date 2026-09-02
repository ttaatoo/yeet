//
//  WorkspaceInspectorHost.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// AppKit Files / Git / Info inspector. Hide/show and width live on this
/// NSView so they are not a SwiftUI layout pass on the whole window. Info
/// stays a hosted SwiftUI panel; Files and Git are native.
final class WorkspaceInspectorView: NSView {
    private let divider = NSView()
    private let bodyView = NSView()
    private let leadingHeader = NSView()
    private let leadingDrag = AppKitWindowDragView()
    private let collapseButton = AppKitChromeIconButton(
        systemImage: "sidebar.left",
        help: String(localized: "Toggle Inspector (⇧⌘B)")
    )
    private let tabBar = AppKitInspectorTabBar()
    private let filesPanel = AppKitFileTreePanel()
    private let gitPanel = AppKitGitPanelView()
    private let infoContainer = NSView()
    private var infoHost: NSHostingView<InfoPanelRoot>?
    private let resizeHandle = AppKitSidebarResizeHandle()
    private let headerHairline = NSView()

    private weak var manager: TerminalManager?
    private weak var git: GitStatusModel?
    private weak var fileTree: FileTreeModel?
    private weak var info: SessionInfoModel?

    private var selectedTab: RightPanel = .files
    private var placement: HorizontalEdge = .trailing
    private(set) var width: Double = InspectorMetrics.defaultWidth
    var onWidthChange: ((Double) -> Void)?

    private var rootSource = Project.PanelRootSource.shell
    private var lastSyncKey: SyncKey?
    private var lastFilesKey: FilesPanelKey?
    private var lastGitKey: GitPanelKey?
    private var lastInfoKey: InfoPanelKey?
    private var applicationIsActive = NSApp.isActive
    private var infoPoll: Timer?
    private var themeObservation: AnyCancellable?
    private var activeObservers: [NSObjectProtocol] = []
    private var refreshQueued = false

    private struct SyncKey: Equatable {
        var tab: RightPanel
        var sessionID: UUID?
        var cwd: String?
        var foreground: String?
        var customDirectory: String?
        var completions: [UUID: UInt64]
    }

    private struct FilesPanelKey: Equatable {
        var rootPath: String
        var itemPaths: [String]
        var renamingPath: String?
        var draft: FileTreeModel.Draft?
        var currentFilePath: String?
        var sessionID: UUID?
        var fontSize: Double
        var fontFamily: String
        var themeToken: String
        var rootBadge: String?
    }

    private struct GitPanelKey: Equatable {
        var tab: RightPanel
        var sessionID: UUID?
        var fontSize: Double
        var themeToken: String
        var rootPath: String
        var repositoryIdentity: String
        var isRepo: Bool
        var statusError: String?
        var branch: String?
        var headOID: String?
        var ahead: Int
        var behind: Int
        var hasUpstream: Bool
        var isBusy: Bool
        var isRefreshing: Bool
        var isResolvingInitialStatus: Bool
        var merge: [GitStatusModel.Entry]
        var staged: [GitStatusModel.Entry]
        var changes: [GitStatusModel.Entry]
        var commits: [GitStatusModel.RecentCommit]
        var hasMoreCommits: Bool
        var isLoadingMore: Bool
        var stashCount: Int
        var repositoryOperation: String?
    }

    private struct InfoPanelKey: Equatable {
        var sessionID: UUID?
        var fontScale: CGFloat
        var fontSize: Double
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.chromeDivider.cgColor
        headerHairline.wantsLayer = true
        headerHairline.layer?.backgroundColor = Theme.chromeDivider.cgColor
        bodyView.wantsLayer = true
        bodyView.layer?.backgroundColor = Theme.sidebar.cgColor
        leadingHeader.wantsLayer = true
        leadingHeader.layer?.backgroundColor = Theme.chromeHeader.cgColor

        addSubview(divider)
        addSubview(bodyView)
        addSubview(resizeHandle)
        bodyView.addSubview(leadingHeader)
        leadingHeader.addSubview(leadingDrag)
        leadingHeader.addSubview(collapseButton)
        bodyView.addSubview(tabBar)
        bodyView.addSubview(headerHairline)
        bodyView.addSubview(filesPanel)
        bodyView.addSubview(gitPanel)
        bodyView.addSubview(infoContainer)

        tabBar.configure(
            selected: .files,
            fontSize: AppSettings.shared.sidebarFontSize
        ) { [weak self] panel in
            self?.selectTab(panel)
        }
        selectTab(.files)

        collapseButton.onAction = { [weak self] in
            self?.manager?.toggleSidebar()
        }
        resizeHandle.range = InspectorMetrics.widthRange
        resizeHandle.defaultWidth = InspectorMetrics.defaultWidth
        resizeHandle.onWidthChange = { [weak self] newWidth in
            guard let self else { return }
            self.width = newWidth
            self.onWidthChange?(newWidth)
            self.invalidateIntrinsicContentSize()
            self.needsLayout = true
        }

        themeObservation = Theme.observeChanges { [weak self] in
            self?.scheduleRefresh()
        }
        activeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            assumeMainActor {
                self?.applicationIsActive = true
                self?.syncModels(force: true)
                self?.updateInfoPolling()
            }
        })
        activeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            assumeMainActor {
                self?.applicationIsActive = false
                self?.updateInfoPolling()
            }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        infoPoll?.invalidate()
        for observer in activeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var preferredWidth: CGFloat {
        CGFloat(width) + InspectorMetrics.dividerWidth
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: NSView.noIntrinsicMetric)
    }

    func configure(
        manager: TerminalManager,
        git: GitStatusModel,
        fileTree: FileTreeModel,
        info: SessionInfoModel,
        placement: HorizontalEdge,
        width: Double,
        onWidthChange: @escaping (Double) -> Void
    ) {
        self.manager = manager
        self.git = git
        self.fileTree = fileTree
        self.info = info
        self.placement = placement
        self.width = min(max(width, InspectorMetrics.widthRange.lowerBound), InspectorMetrics.widthRange.upperBound)
        self.onWidthChange = onWidthChange
        resizeHandle.width = self.width
        resizeHandle.edge = placement == .leading ? .trailing : .leading

        let settings = AppSettings.shared
        let sidebarScale = CGFloat(settings.sidebarFontSize / AppSettings.defaultSidebarFontSize)
        let themeToken = inspectorThemeToken()
        tabBar.configure(selected: manager.panelTab, fontSize: settings.sidebarFontSize) { [weak self] panel in
            self?.selectTab(panel)
        }
        collapseButton.configure(
            systemImage: "sidebar.left",
            help: String(localized: "Toggle Inspector (⇧⌘B)")
        )

        let openFilePath: String? = {
            if case .file(let file)? = manager.selectedProject?.focusedContent {
                return file.path
            }
            return nil
        }()
        // SwiftUI ticks updateNSView on every ObservedObject. Rebuild Files
        // only when the tree, root, or theme actually changed; Git only when
        // the change set, theme, or tab did. Filter keystrokes stay inside
        // the Git panel.
        let filesKey = FilesPanelKey(
            rootPath: fileTree.rootPath,
            itemPaths: fileTree.items.map(\.path),
            renamingPath: fileTree.renamingPath,
            draft: fileTree.draft,
            currentFilePath: openFilePath,
            sessionID: manager.selectedSession?.id,
            fontSize: settings.filesFontSize,
            fontFamily: settings.filesFontFamily,
            themeToken: themeToken,
            rootBadge: rootBadge?.text
        )
        if filesKey != lastFilesKey {
            lastFilesKey = filesKey
            filesPanel.configure(
                model: fileTree,
                git: git,
                session: manager.selectedSession,
                rootBadge: rootBadge,
                currentFilePath: openFilePath,
                openFile: { [weak manager] path in manager?.openFile(path) },
                openToSide: { [weak manager] path in manager?.openFileToSide(path) },
                onRename: { [weak manager] old, new in manager?.fileRenamed(from: old, to: new) },
                refreshGitStatus: { [weak git] in git?.refresh() }
            )
        }
        let gitKey = GitPanelKey(
            tab: manager.panelTab,
            sessionID: manager.selectedSession?.id,
            fontSize: settings.sidebarFontSize,
            themeToken: themeToken,
            rootPath: git.rootPath,
            repositoryIdentity: git.repositoryIdentity,
            isRepo: git.isRepo,
            statusError: git.statusError,
            branch: git.branch,
            headOID: git.headOID,
            ahead: git.ahead,
            behind: git.behind,
            hasUpstream: git.hasUpstream,
            isBusy: git.isBusy,
            isRefreshing: git.isRefreshing,
            isResolvingInitialStatus: git.isResolvingInitialStatus,
            merge: git.mergeEntries,
            staged: git.stagedEntries,
            changes: git.changedEntries,
            commits: git.recentCommits,
            hasMoreCommits: git.hasMoreRecentCommits,
            isLoadingMore: git.isLoadingMoreCommits,
            stashCount: git.stashCount,
            repositoryOperation: git.repositoryOperation
        )
        if gitKey != lastGitKey {
            lastGitKey = gitKey
            gitPanel.configure(
                model: git,
                session: manager.selectedSession,
                fontScale: sidebarScale,
                openFile: { [weak manager] path in manager?.openFile(path) },
                openToSide: { [weak manager] path in manager?.openFileToSide(path) },
                openDiff: { [weak manager, weak git] entry, staged in
                    guard let git else { return }
                    manager?.openDiff(
                        repoRoot: git.repoRoot,
                        path: entry.path,
                        staged: staged,
                        untracked: entry.isUntracked,
                        origPath: entry.origPath
                    )
                },
                openCommitDiff: { [weak manager, weak git] commit, file in
                    guard let git else { return }
                    manager?.openCommitDiff(
                        repoRoot: git.repoRoot,
                        path: file.path,
                        commitHash: commit.hash,
                        parentHash: commit.parentHash,
                        status: file.status,
                        origPath: file.originalPath
                    )
                }
            )
        }
        let infoKey = InfoPanelKey(
            sessionID: manager.selectedSession?.id,
            fontScale: sidebarScale,
            fontSize: settings.sidebarFontSize
        )
        if infoKey != lastInfoKey {
            lastInfoKey = infoKey
            let infoRoot = InfoPanelRoot(
                model: info,
                session: manager.selectedSession,
                fontScale: sidebarScale,
                fontSize: settings.sidebarFontSize
            )
            if let infoHost {
                infoHost.rootView = infoRoot
            } else {
                let host = NSHostingView(rootView: infoRoot)
                host.safeAreaRegions = []
                infoContainer.addSubview(host)
                infoHost = host
            }
        }

        selectTab(manager.panelTab)
        leadingHeader.isHidden = placement != .leading

        afterViewUpdate { [weak self] in
            self?.syncModels(force: false)
            self?.updateInfoPolling()
        }
        refreshChrome()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    var debugSelectedTab: RightPanel { selectedTab }
    var debugWidth: Double { width }
    var debugTabTitles: [String] { tabBar.debugTabTitles }
    var debugFilesPanel: AppKitFileTreePanel { filesPanel }
    var debugGitPanel: AppKitGitPanelView { gitPanel }
    var debugInfoIsHidden: Bool { infoContainer.isHidden }
    var debugResizeHandle: AppKitSidebarResizeHandle { resizeHandle }

    func debugSelectTab(_ panel: RightPanel) {
        tabBar.debugSelect(panel)
    }

    private func selectTab(_ panel: RightPanel) {
        selectedTab = panel
        manager?.panelTab = panel
        filesPanel.isHidden = panel != .files
        gitPanel.isHidden = panel != .git
        infoContainer.isHidden = panel != .info
        updateInfoPolling()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let dividerWidth = InspectorMetrics.dividerWidth
        let bodyWidth = CGFloat(width)
        let isLeading = placement == .leading
        if isLeading {
            bodyView.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: bounds.height)
            divider.frame = NSRect(x: bodyWidth, y: 0, width: dividerWidth, height: bounds.height)
            resizeHandle.frame = NSRect(
                x: bodyWidth - InspectorMetrics.handleWidth / 2,
                y: 0,
                width: InspectorMetrics.handleWidth,
                height: bounds.height
            )
        } else {
            divider.frame = NSRect(x: 0, y: 0, width: dividerWidth, height: bounds.height)
            bodyView.frame = NSRect(x: dividerWidth, y: 0, width: bodyWidth, height: bounds.height)
            resizeHandle.frame = NSRect(
                x: dividerWidth - InspectorMetrics.handleWidth / 2,
                y: 0,
                width: InspectorMetrics.handleWidth,
                height: bounds.height
            )
        }

        var y: CGFloat = 0
        if isLeading {
            leadingHeader.frame = NSRect(
                x: 0, y: 0, width: bodyWidth, height: InspectorMetrics.chromeHeight
            )
            leadingDrag.frame = NSRect(
                x: 0, y: 0,
                width: max(0, bodyWidth - 32),
                height: InspectorMetrics.chromeHeight
            )
            collapseButton.frame = NSRect(
                x: bodyWidth - 32, y: 7, width: 24, height: 24
            )
            y = InspectorMetrics.chromeHeight
        } else {
            leadingHeader.frame = .zero
        }
        tabBar.frame = NSRect(
            x: 0, y: y, width: bodyWidth, height: InspectorMetrics.chromeHeight
        )
        headerHairline.frame = NSRect(
            x: 0,
            y: y + InspectorMetrics.chromeHeight - 1,
            width: bodyWidth,
            height: 1
        )
        y += InspectorMetrics.chromeHeight
        let content = NSRect(
            x: 0, y: y, width: bodyWidth, height: max(0, bounds.height - y)
        )
        filesPanel.frame = content
        gitPanel.frame = content
        infoContainer.frame = content
        infoHost?.frame = infoContainer.bounds
    }

    private func refreshChrome() {
        layer?.backgroundColor = Theme.sidebar.cgColor
        bodyView.layer?.backgroundColor = Theme.sidebar.cgColor
        divider.layer?.backgroundColor = Theme.chromeDivider.cgColor
        headerHairline.layer?.backgroundColor = Theme.chromeDivider.cgColor
        leadingHeader.layer?.backgroundColor = Theme.chromeHeader.cgColor
        tabBar.needsLayout = true
        needsDisplay = true
    }

    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshChrome()
            self.needsLayout = true
        }
    }

    private func commandCompletionSequences(in project: Project?) -> [UUID: UInt64] {
        Dictionary(
            project?.sessions.map {
                ($0.id, $0.commandLifecycle.completionSequence)
            } ?? [],
            uniquingKeysWith: { _, later in later }
        )
    }

    private func syncModels(force: Bool) {
        guard let manager, manager.isPanelVisible,
              let project = manager.selectedProject,
              let session = project.selectedSession
        else { return }
        let completions = commandCompletionSequences(in: project)
        let key = SyncKey(
            tab: manager.panelTab,
            sessionID: session.id,
            cwd: session.currentDirectoryPath,
            foreground: session.foregroundDirectoryPath,
            customDirectory: project.customDirectory,
            completions: completions
        )
        if !force, lastSyncKey == key { return }
        lastSyncKey = key

        let cwd = session.currentDirectoryPath
        let (root, source) = project.panelRoot(
            followingSessionAt: cwd, foregroundAt: session.foregroundDirectoryPath
        )
        if rootSource != source { rootSource = source }
        fileTree?.sync(root: root)
        if manager.panelTab == .info {
            info?.sync(
                root: cwd, projectRoot: root, projectRootSource: source,
                shellName: session.shellName, shellPid: session.shellPid
            )
        }
        filesPanel.updateRootBadge(rootBadge)
    }

    private func updateInfoPolling() {
        let shouldPoll = manager?.isPanelVisible == true
            && applicationIsActive
            && manager?.panelTab == .info
        if shouldPoll {
            if infoPoll == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    assumeMainActor { self?.syncModels(force: true) }
                }
                RunLoop.main.add(timer, forMode: .common)
                infoPoll = timer
            }
        } else {
            infoPoll?.invalidate()
            infoPoll = nil
        }
    }

    private var rootBadge: (text: String, description: String)? {
        guard case .foreground(let isWorktree) = rootSource else { return nil }
        if isWorktree {
            return (
                String(
                    localized: "worktree",
                    comment: "Files header badge: the panels follow a Git worktree the terminal’s foreground job moved to."
                ),
                String(localized: "Following the terminal job’s worktree")
            )
        }
        return (
            String(
                localized: "job",
                comment: "Files header badge: the panels follow a directory the terminal’s foreground job moved to, outside any worktree of the shell’s repository."
            ),
            String(localized: "Following the terminal job’s directory")
        )
    }
}

struct WorkspaceInspectorHost: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var git: GitStatusModel
    @ObservedObject var fileTree: FileTreeModel
    @ObservedObject var info: SessionInfoModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Binding var width: Double
    var placement: HorizontalEdge = .trailing

    func makeNSView(context: Context) -> WorkspaceInspectorView {
        WorkspaceInspectorView(frame: .zero)
    }

    func updateNSView(_ nsView: WorkspaceInspectorView, context: Context) {
        _ = themeChanges
        _ = settings.sidebarFontSize
        _ = settings.filesFontSize
        _ = settings.filesFontFamily
        nsView.configure(
            manager: manager,
            git: git,
            fileTree: fileTree,
            info: info,
            placement: placement,
            width: width,
            onWidthChange: { newWidth in
                width = newWidth
            }
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: WorkspaceInspectorView,
        context: Context
    ) -> CGSize? {
        CGSize(width: nsView.preferredWidth, height: proposal.height ?? nsView.bounds.height)
    }
}
