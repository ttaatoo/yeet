//
//  AppKitChromePresentationTests.swift
//  yeetTests
//

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import yeet

@MainActor
final class AppKitChromePresentationTests: XCTestCase {
    func testSidebarRowSubtitleUsesStringCatalog() {
        let expected = String(
            localized: "2 sessions",
            comment: "Number of sessions in a project row."
        )

        XCTAssertEqual(SidebarRowDisplayState.subtitle(for: 2), expected)
        XCTAssertNil(SidebarRowDisplayState.subtitle(for: 1))
    }

    func testSidebarRowHidesTransientTrailingContentWhileRenaming() {
        let state = SidebarRowDisplayState(
            title: "workspace",
            sessionCount: 2,
            pendingReviewCount: 4,
            agentRollup: KeroAgentRollup(phase: .working, count: 1),
            index: 0,
            isRenaming: true,
            directory: "/tmp/workspace"
        )

        XCTAssertEqual(state.subtitle, "2 sessions")
        XCTAssertFalse(state.showsReviewCount)
        XCTAssertFalse(state.showsAgentBadge)
        XCTAssertEqual(state.trailingContent, .none)
    }

    func testSidebarRowUsesStableShortcutSlotForFirstNineProjects() {
        let state = SidebarRowDisplayState(
            title: "workspace",
            sessionCount: 1,
            pendingReviewCount: nil,
            agentRollup: nil,
            index: 8,
            isRenaming: false,
            directory: ""
        )

        XCTAssertEqual(state.trailingContent, .shortcut("⌘9"))
        XCTAssertEqual(state.accessibilityLabel, "workspace")
    }

    func testSidebarRowOmitsShortcutAfterTheNinthProject() {
        let state = SidebarRowDisplayState(
            title: "workspace",
            sessionCount: 1,
            pendingReviewCount: nil,
            agentRollup: nil,
            index: 9,
            isRenaming: false,
            directory: ""
        )

        XCTAssertEqual(state.trailingContent, .none)
    }

    func testPaneActivityBarOnlyPaintsLiveAgentPhases() {
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .created),
            .progress
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .working),
            .progress
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .done),
            .progress
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .blocked),
            .attention
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .idle),
            .hidden
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: nil),
            .hidden
        )
    }

    func testSidebarRowAccessibilityPressSelectsTheProject() {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        var selected = false
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: { selected = true },
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertTrue(selected)
    }

    func testSidebarRowSupportsFullKeyboardActivationAndFocus() {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        var activationCount = 0
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: { activationCount += 1 },
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        XCTAssertTrue(row.acceptsFirstResponder, "row must accept first responder")
        XCTAssertTrue(row.canBecomeKeyView, "row must be in the key-view loop")
        XCTAssertEqual(row.focusRingType, .default, "row must draw a focus ring")

        row.keyDown(with: Self.keyEvent(keyCode: 36, characters: "\r"))
        row.keyDown(with: Self.keyEvent(keyCode: 49, characters: " "))

        XCTAssertEqual(activationCount, 2)
    }

    func testSidebarRowExposesReviewCountAsAnAccessibilityChild() {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        project.pendingReview = PendingReview(fileCount: 2, sessionID: nil)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: {},
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        let children = row.accessibilityChildren()
        XCTAssertTrue(
            children?.contains { child in
                (child as? NSTextField)?.stringValue == "2"
                    || (child as? NSCell)?.stringValue == "2"
            } == true
        )
    }

    func testSidebarRowRepaintsSelectionStripeWhenChromeAccentChanges() async {
        Theme.reloadChromeAccent(.coral)
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            project: project,
            index: 0,
            isSelected: true,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: {},
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        let coral = row.debugSelectionStripeColor
        XCTAssertNotNil(coral)

        Theme.reloadChromeAccent(.vividPurple)
        await Self.drainMainQueue(times: 2)

        let purple = row.debugSelectionStripeColor
        XCTAssertNotNil(purple)
        XCTAssertNotEqual(coral, purple)

        Theme.reloadChromeAccent(.coral)
    }

    func testSidebarRowRefreshesAfterPublishedProjectValueIsWritten() async {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: {},
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        project.customName = "renamed"
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        XCTAssertEqual(row.accessibilityLabel(), "renamed")
    }

    func testInspectorTabsExposeFilesGitAndInfo() {
        let states = InspectorTabDisplayState.all(selected: .files)
        XCTAssertEqual(states.map(\.panel), [.info, .files, .git])
        XCTAssertEqual(states.first { $0.panel == .files }?.isSelected, true)
        XCTAssertEqual(states.first { $0.panel == .git }?.isSelected, false)
        XCTAssertEqual(
            states.first { $0.panel == .files }?.accessibilityValue,
            "Selected"
        )
    }

    func testInspectorTabBarSelectsGit() {
        let bar = AppKitInspectorTabBar(frame: NSRect(x: 0, y: 0, width: 240, height: 38))
        var selected: RightPanel?
        bar.configure(selected: .files, fontSize: AppSettings.defaultSidebarFontSize) {
            selected = $0
        }
        XCTAssertEqual(bar.debugTabTitles, ["Info", "Files", "Git"])
        bar.debugSelect(.git)
        XCTAssertEqual(selected, .git)
    }

    func testInspectorResizeHandleClampsAndResetsWidth() {
        let handle = AppKitSidebarResizeHandle(frame: NSRect(x: 0, y: 0, width: 7, height: 100))
        handle.edge = .leading
        handle.range = InspectorMetrics.widthRange
        handle.defaultWidth = InspectorMetrics.defaultWidth
        handle.width = 240
        var latest = handle.width
        handle.onWidthChange = { latest = $0 }

        handle.debugApplyDrag(delta: 400)
        XCTAssertEqual(latest, InspectorMetrics.widthRange.upperBound)

        handle.debugApplyDrag(delta: -1000)
        XCTAssertEqual(latest, InspectorMetrics.widthRange.lowerBound)

        handle.width = 300
        handle.mouseDown(with: Self.mouseEvent(clickCount: 2))
        XCTAssertEqual(latest, InspectorMetrics.defaultWidth)
    }

    func testFileTreeRowAccessibilityIncludesGitDecoration() {
        let state = FileTreeRowDisplayState(
            name: "main.swift",
            path: "/tmp/main.swift",
            isDirectory: false,
            isDraft: false,
            isRenaming: false,
            isCurrent: true,
            isExpanded: false,
            depth: 0,
            gitDecoration: .modified
        )
        XCTAssertEqual(state.accessibilityLabel, "main.swift, Modified")
        XCTAssertEqual(state.gitDecoration?.badge, "M")
    }

    func testFileTreeRowPressOpensFile() {
        let item = FileTreeModel.Item(
            name: "main.swift",
            path: "/tmp/main.swift",
            isDirectory: false,
            depth: 0
        )
        let state = FileTreeRowDisplayState(
            name: item.name,
            path: item.path,
            isDirectory: false,
            isDraft: false,
            isRenaming: false,
            isCurrent: false,
            isExpanded: false,
            depth: 0,
            gitDecoration: nil
        )
        let row = AppKitFileTreeRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        var opened = false
        row.configure(
            item: item,
            state: state,
            fontScale: 1,
            fontFamily: "",
            onActivate: { opened = true },
            onRenameCommit: { _ in },
            onRenameCancel: {},
            onDraftCommit: { _ in },
            onDraftCancel: {},
            menu: { NSMenu() }
        )
        XCTAssertTrue(row.acceptsFirstResponder)
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertTrue(opened)
    }

    func testGitEntryRowDisplayStateShowsDiscardOnlyWhenUnstaged() {
        let unstaged = GitEntryRowDisplayState(
            fileName: "a.txt",
            directory: "",
            status: "M",
            kind: .unstaged,
            disabled: false,
            isStageLoading: false,
            isUnstageLoading: false,
            isDiscardLoading: false
        )
        XCTAssertTrue(unstaged.showsDiscard)
        XCTAssertTrue(unstaged.showsStage)
        XCTAssertFalse(unstaged.showsUnstage)

        let staged = GitEntryRowDisplayState(
            fileName: "a.txt",
            directory: "",
            status: "M",
            kind: .staged,
            disabled: false,
            isStageLoading: false,
            isUnstageLoading: false,
            isDiscardLoading: false
        )
        XCTAssertTrue(staged.showsUnstage)
        XCTAssertFalse(staged.showsDiscard)
        XCTAssertEqual(unstaged.accessibilityLabel, "a.txt, Modified")
    }

    func testGitEntryRowStageAndDiscardActionsFire() {
        let entry = GitStatusModel.Entry(
            path: "a.txt",
            staged: ".",
            unstaged: "M"
        )
        let state = GitEntryRowDisplayState(
            fileName: "a.txt",
            directory: "",
            status: "M",
            kind: .unstaged,
            disabled: false,
            isStageLoading: false,
            isUnstageLoading: false,
            isDiscardLoading: false
        )
        let row = AppKitGitEntryRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        var staged = false
        var discarded = false
        var openedDiff = false
        row.configure(
            entry: entry,
            state: state,
            fontScale: 1,
            handlers: .init(
                openDiff: { openedDiff = true },
                openFile: {},
                openToSide: {},
                stage: { staged = true },
                unstage: {},
                discard: { discarded = true },
                copyRelativePath: {},
                insertInTerminal: nil,
                absolutePath: "/tmp/a.txt"
            )
        )
        row.debugClickStage()
        row.debugClickDiscard()
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertTrue(staged)
        XCTAssertTrue(discarded)
        XCTAssertTrue(openedDiff)
        XCTAssertTrue(row.acceptsFirstResponder)
    }

    func testGitChangeListReusesRowsAcrossFilterAndReconfigure() throws {
        let list = AppKitGitChangeListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        let keep = GitStatusModel.Entry(path: "keep.swift", staged: ".", unstaged: "M")
        let skip = GitStatusModel.Entry(path: "skip.txt", staged: ".", unstaged: "M")
        configureGitList(list, changes: [keep, skip], totalChangeCount: 2)
        let original = try XCTUnwrap(list.debugEntryRow(named: "keep.swift"))
        let window = attachToWindow(list)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(original))

        configureGitList(list, changes: [keep, skip], totalChangeCount: 2)
        let again = try XCTUnwrap(list.debugEntryRow(named: "keep.swift"))
        XCTAssertIdentical(original, again)
        XCTAssertIdentical(window.firstResponder, original)
        XCTAssertEqual(list.debugEntryRows.count, 2)

        configureGitList(
            list,
            changes: [keep],
            filterText: "keep",
            totalChangeCount: 2
        )
        let filtered = try XCTUnwrap(list.debugEntryRow(named: "keep.swift"))
        XCTAssertIdentical(original, filtered)
        XCTAssertEqual(list.debugEntryRows.count, 1)
        XCTAssertNil(list.debugEntryRow(named: "skip.txt"))
        XCTAssertIdentical(window.firstResponder, original)
    }

    func testGitPanelReusesRowsAcrossFilterAndSecondConfigure() async throws {
        let directory = try makeGitRepo(
            prefix: "yeet-git-row-reuse",
            files: ["keep.swift": "keep\n", "skip.txt": "skip\n"]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let git = GitStatusModel()
        try await loadGit(git, root: directory.path)
        XCTAssertTrue(git.isRepo)
        XCTAssertGreaterThanOrEqual(git.changedEntries.count, 2)

        let panel = AppKitGitPanelView(frame: NSRect(x: 0, y: 0, width: 280, height: 480))
        let window = attachToWindow(panel)
        defer { window.close() }
        configureGitPanel(panel, model: git)
        XCTAssertFalse(git.isRefreshing)

        let original = try await waitUntil(timeout: 2) {
            panel.debugEntryRow(named: "keep.swift")
        } satisfies: { $0 != nil }
        let originalRow = try XCTUnwrap(original)
        XCTAssertTrue(window.makeFirstResponder(originalRow))
        let scrollOrigin = panel.debugScrollOrigin
        let configureCount = panel.debugChangeListConfigureCount
        XCTAssertGreaterThanOrEqual(configureCount, 1)

        configureGitPanel(panel, model: git)
        XCTAssertEqual(panel.debugChangeListConfigureCount, configureCount)
        let again = try XCTUnwrap(panel.debugEntryRow(named: "keep.swift"))
        XCTAssertIdentical(originalRow, again)
        XCTAssertIdentical(window.firstResponder, originalRow)
        XCTAssertEqual(panel.debugScrollOrigin, scrollOrigin)

        panel.debugSetFilter("keep")
        XCTAssertEqual(panel.debugFilterText, "keep")
        XCTAssertFalse(git.isRefreshing)
        XCTAssertGreaterThan(panel.debugChangeListConfigureCount, configureCount)
        let filtered = try XCTUnwrap(panel.debugEntryRow(named: "keep.swift"))
        XCTAssertIdentical(originalRow, filtered)
        XCTAssertEqual(panel.debugVisibleFileNames, ["keep.swift"])
        XCTAssertIdentical(window.firstResponder, originalRow)
    }

    func testInspectorTabsHideInactivePanels() {
        let inspector = WorkspaceInspectorView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        XCTAssertFalse(inspector.debugFilesPanel.isHidden)
        XCTAssertTrue(inspector.debugGitPanel.isHidden)
        XCTAssertTrue(inspector.debugInfoIsHidden)
        XCTAssertEqual(inspector.debugSelectedTab, .files)

        inspector.debugSelectTab(.git)
        XCTAssertEqual(inspector.debugSelectedTab, .git)
        XCTAssertTrue(inspector.debugFilesPanel.isHidden)
        XCTAssertFalse(inspector.debugGitPanel.isHidden)
        XCTAssertTrue(inspector.debugInfoIsHidden)

        inspector.debugSelectTab(.info)
        XCTAssertEqual(inspector.debugSelectedTab, .info)
        XCTAssertTrue(inspector.debugFilesPanel.isHidden)
        XCTAssertTrue(inspector.debugGitPanel.isHidden)
        XCTAssertFalse(inspector.debugInfoIsHidden)

        inspector.debugSelectTab(.files)
        XCTAssertEqual(inspector.debugSelectedTab, .files)
        XCTAssertFalse(inspector.debugFilesPanel.isHidden)
        XCTAssertTrue(inspector.debugGitPanel.isHidden)
        XCTAssertTrue(inspector.debugInfoIsHidden)
    }

    func testInspectorConfigureDoesNotRepublishSelectedTab() {
        let manager = TerminalManager()
        manager.panelTab = .files
        let inspector = WorkspaceInspectorView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 400)
        )
        var publicationCount = 0
        let observation = manager.objectWillChange.sink {
            publicationCount += 1
        }

        inspector.configure(
            manager: manager,
            git: GitStatusModel(),
            fileTree: FileTreeModel(),
            info: SessionInfoModel(),
            placement: .trailing,
            width: 240,
            onWidthChange: { _ in }
        )

        XCTAssertEqual(publicationCount, 0)
        inspector.debugSelectTab(.git)
        XCTAssertEqual(manager.panelTab, .git)
        XCTAssertEqual(publicationCount, 1)
        withExtendedLifetime(observation) {}
    }

    func testInspectorFollowsProjectFocusWithoutManagerRelay() async throws {
        let root = try makeTempDirectory(prefix: "yeet-inspector-project-focus")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.swift", "beta.swift"] {
            try "print(1)\n".write(
                to: root.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }
        let project = Project(fallbackName: "focus", createInitialSession: false)
        let first = PaneTab(content: .file(FileTab(path: root.appendingPathComponent("alpha.swift").path)))
        let second = PaneTab(content: .file(FileTab(path: root.appendingPathComponent("beta.swift").path)))
        project.append(first)
        project.append(second)
        let manager = TerminalManager()
        manager.projects = [project]
        manager.selectedProjectID = project.id
        manager.isPanelVisible = true
        manager.panelTab = .files
        let git = GitStatusModel()
        let tree = FileTreeModel()
        let info = SessionInfoModel()
        tree.sync(root: root.path)
        _ = try await waitUntil(timeout: 5) { tree.items.count } satisfies: { $0 == 2 }

        let inspector = WorkspaceInspectorView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 400)
        )
        inspector.configure(
            manager: manager, git: git, fileTree: tree, info: info,
            placement: .trailing, width: 240, onWidthChange: { _ in }
        )
        let alphaRow = try XCTUnwrap(inspector.debugFilesPanel.debugRow(at: 0))
        let betaRow = try XCTUnwrap(inspector.debugFilesPanel.debugRow(at: 1))
        XCTAssertFalse(try XCTUnwrap(alphaRow.debugState).isCurrent)
        XCTAssertTrue(try XCTUnwrap(betaRow.debugState).isCurrent)
        var managerPublications = 0
        let observation = manager.objectWillChange.sink { managerPublications += 1 }

        project.selectedTabID = first.id
        await Self.drainMainQueue(times: 3)

        XCTAssertTrue(try XCTUnwrap(alphaRow.debugState).isCurrent)
        XCTAssertFalse(try XCTUnwrap(betaRow.debugState).isCurrent)
        XCTAssertEqual(managerPublications, 0)
        withExtendedLifetime(observation) {}
    }

    func testInspectorFollowsProjectDirectoryWithoutManagerRelay() async throws {
        let root = try makeTempDirectory(prefix: "yeet-inspector-project-directory")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let project = Project(fallbackName: "directory", createInitialSession: false)
        let session = project.newSession(directory: root.path)
        defer { session.terminate() }
        project.customDirectory = first.path
        let manager = TerminalManager()
        manager.projects = [project]
        manager.selectedProjectID = project.id
        manager.isPanelVisible = true
        manager.panelTab = .files
        let git = GitStatusModel()
        let tree = FileTreeModel()
        let info = SessionInfoModel()
        let inspector = WorkspaceInspectorView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 400)
        )
        inspector.configure(
            manager: manager, git: git, fileTree: tree, info: info,
            placement: .trailing, width: 240, onWidthChange: { _ in }
        )
        _ = try await waitUntil(timeout: 5) { tree.rootPath } satisfies: { $0 == first.path }
        var managerPublications = 0
        let observation = manager.objectWillChange.sink { managerPublications += 1 }

        project.customDirectory = second.path
        _ = try await waitUntil(timeout: 5) { tree.rootPath } satisfies: { $0 == second.path }

        XCTAssertEqual(managerPublications, 0)
        withExtendedLifetime(observation) {}
    }

    func testFileTreeRowsKeepIdentityAcrossReconfigure() async throws {
        let root = try makeTempDirectory(prefix: "yeet-files-row-reuse")
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello\n".write(
            to: root.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tree = FileTreeModel()
        tree.sync(root: root.path)
        _ = try await waitUntil(timeout: 5) {
            tree.items
        } satisfies: { items in
            items.contains { $0.name == "alpha.txt" }
        }

        let panel = AppKitFileTreePanel(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        configureFileTree(panel, model: tree)
        let original = try XCTUnwrap(panel.debugRow(at: 0))
        let configureCount = panel.debugConfigureCount
        configureFileTree(panel, model: tree)
        XCTAssertEqual(panel.debugConfigureCount, configureCount)
        XCTAssertIdentical(original, panel.debugRow(at: 0))
    }

    func testGitPanelDiscardUsesFingerprintUniquing() async throws {
        let directory = try makeGitRepo(
            prefix: "yeet-git-panel-discard",
            files: ["gone.txt": "temp\n"]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let git = GitStatusModel()
        try await loadGit(git, root: directory.path)
        XCTAssertTrue(git.changedEntries.contains { $0.path == "gone.txt" })

        let panel = AppKitGitPanelView(frame: NSRect(x: 0, y: 0, width: 280, height: 480))
        configureGitPanel(panel, model: git)
        _ = try await waitUntil(timeout: 2) {
            panel.debugEntryRow(named: "gone.txt")
        } satisfies: { $0 != nil }

        let composed = "caf\u{e9}.txt"
        let decomposed = "cafe\u{301}.txt"
        let colliding = GitStatusModel.Entry(
            path: composed,
            staged: ".",
            unstaged: "R",
            origPath: decomposed,
            repositoryRoot: git.repoRoot
        )
        XCTAssertEqual(
            panel.debugDiscardFingerprintCount(for: colliding),
            1
        )

        panel.debugAutomaticallyConfirmDiscard = true
        panel.debugRequestDiscard(named: "gone.txt")
        try await waitForGitStatus(git)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("gone.txt").path
            )
        )
        XCTAssertFalse(git.changedEntries.contains { $0.path == "gone.txt" })
    }

    private func configureGitList(
        _ list: AppKitGitChangeListView,
        merge: [GitStatusModel.Entry] = [],
        staged: [GitStatusModel.Entry] = [],
        changes: [GitStatusModel.Entry] = [],
        filterText: String = "",
        totalChangeCount: Int? = nil
    ) {
        list.configure(
            merge: merge,
            staged: staged,
            changes: changes,
            commits: [],
            mergeCollapsed: false,
            stagedCollapsed: false,
            changesCollapsed: false,
            historyCollapsed: true,
            expandedCommitIDs: [],
            filterText: filterText,
            totalChangeCount: totalChangeCount ?? (merge.count + staged.count + changes.count),
            ahead: 0,
            behind: 0,
            isBusy: false,
            fontScale: 1,
            hasMoreCommits: false,
            isLoadingMore: false,
            stageAllLoading: false,
            unstageAllLoading: false,
            discardAllLoading: false,
            loadingEntry: nil,
            loadMore: { false },
            openCommitDiff: { _, _ in },
            rowHandler: { entry, _ in
                .init(
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
            onStageAll: {},
            onUnstageAll: {},
            onDiscardAll: {}
        )
    }

    private func configureGitPanel(_ panel: AppKitGitPanelView, model: GitStatusModel) {
        panel.configure(
            model: model,
            session: nil,
            fontScale: 1,
            openFile: { _ in },
            openToSide: { _ in },
            openDiff: { _, _ in },
            openCommitDiff: { _, _ in }
        )
        panel.layoutSubtreeIfNeeded()
    }

    private func configureFileTree(_ panel: AppKitFileTreePanel, model: FileTreeModel) {
        panel.configure(
            model: model,
            git: GitStatusModel(),
            session: nil,
            rootBadge: nil,
            currentFilePath: nil,
            openFile: { _ in },
            openToSide: { _ in },
            onRename: { _, _ in },
            refreshGitStatus: {}
        )
        panel.layoutSubtreeIfNeeded()
    }

    private func attachToWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: max(view.bounds.width, 280),
                height: max(view.bounds.height, 400)
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeGitRepo(prefix: String, files: [String: String]) throws -> URL {
        let directory = try makeTempDirectory(prefix: prefix)
        let initGit = GitStatusModel.runGit(["init", "-b", "main"], in: directory.path)
        XCTAssertEqual(initGit.status, 0, initGit.stderr)
        for (name, contents) in files {
            try contents.write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        return directory
    }

    private static func mouseEvent(clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private static func drainMainQueue(times: Int) async {
        for _ in 0..<times {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    private static func keyEvent(keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

}
