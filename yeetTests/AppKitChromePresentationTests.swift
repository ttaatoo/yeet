//
//  AppKitChromePresentationTests.swift
//  yeetTests
//

import AppKit
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

        let children = row.accessibilityAttributeValue(.children) as? [Any]
        XCTAssertTrue(
            children?.contains { child in
                (child as? NSCell)?.stringValue == "2"
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

    func testGitFilterDoesNotStartAGitRefresh() {
        let git = GitStatusModel()
        let panel = AppKitGitPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        panel.configure(
            model: git,
            session: nil,
            fontScale: 1,
            openFile: { _ in },
            openToSide: { _ in },
            openDiff: { _, _ in },
            openCommitDiff: { _, _ in }
        )
        XCTAssertFalse(git.isRefreshing)
        panel.debugSetFilter("main.swift")
        XCTAssertEqual(panel.debugFilterText, "main.swift")
        XCTAssertFalse(git.isRefreshing)
    }

    func testDiscardFingerprintsKeepOneKeyForEquivalentPaths() {
        let composed = "caf\u{e9}.txt"
        let decomposed = "cafe\u{301}.txt"
        let entry = GitStatusModel.Entry(
            path: composed,
            staged: ".",
            unstaged: "R",
            origPath: decomposed
        )
        let fingerprints = GitStatusModel.discardFingerprints(for: entry) { $0 }
        XCTAssertEqual(fingerprints.count, 1)
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
