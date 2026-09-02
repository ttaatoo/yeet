import XCTest
@testable import yeet

@MainActor
final class ProjectWorkspaceTests: XCTestCase {
    func testFocusedContentCapabilitiesStayOwnedByProject() {
        let empty = Project(fallbackName: "empty", createInitialSession: false)
        XCTAssertFalse(empty.canFind)
        XCTAssertFalse(empty.canReplace)
        XCTAssertFalse(empty.canClearActiveTerminal)
        XCTAssertFalse(empty.canSplit)
        XCTAssertFalse(empty.hasSelectedBrowser)

        let fileProject = Project(fallbackName: "file", createInitialSession: false)
        let fileTab = PaneTab(content: .file(FileTab(path: "/tmp/example.swift")))
        fileProject.append(fileTab)
        XCTAssertTrue(fileProject.canFind)
        XCTAssertTrue(fileProject.canReplace)
        XCTAssertFalse(fileProject.canClearActiveTerminal)
        XCTAssertTrue(fileProject.canSplit)
        XCTAssertFalse(fileProject.hasSelectedBrowser)

        let browserProject = Project(fallbackName: "browser", createInitialSession: false)
        let browserTab = PaneTab(content: .browser(BrowserTab(initialURL: nil, initialFocus: .none)))
        browserProject.append(browserTab)
        XCTAssertFalse(browserProject.canFind)
        XCTAssertFalse(browserProject.canReplace)
        XCTAssertFalse(browserProject.canClearActiveTerminal)
        XCTAssertTrue(browserProject.canSplit)
        XCTAssertTrue(browserProject.hasSelectedBrowser)

        let sessionProject = Project(fallbackName: "terminal", createInitialSession: false)
        let session = sessionProject.newSession(
            directory: "/tmp",
            commandArguments: ["/bin/sh", "-c", "sleep 2"]
        )
        defer { session.terminate() }
        XCTAssertTrue(sessionProject.canFind)
        XCTAssertFalse(sessionProject.canReplace)
        XCTAssertTrue(sessionProject.canClearActiveTerminal)
        XCTAssertTrue(sessionProject.canSplit)
        XCTAssertFalse(sessionProject.hasSelectedBrowser)
    }

    func testRecursiveRestorePassesHistoryKeysToEachTerminal() {
        let project = Project(fallbackName: "restore", createInitialSession: false)
        let first = SessionSnapshot.ProjectSnapshot.PaneSnapshot(
            content: .session(workingDirectory: "/tmp", agentKind: nil, agentSessionID: nil),
            weight: 0.5,
            historyKey: "first-history"
        )
        let second = SessionSnapshot.ProjectSnapshot.PaneSnapshot(
            content: .session(workingDirectory: "/tmp", agentKind: nil, agentSessionID: nil),
            weight: 0.5,
            historyKey: "second-history"
        )
        let snapshot = SessionSnapshot.ProjectSnapshot.TabSnapshot(
            layout: .split(
                axis: .horizontal,
                fraction: 0.5,
                first: .pane(first),
                second: .pane(second)
            ),
            focusedPaneIndex: 1
        )

        guard let tab = project.restoreTab(
            from: snapshot,
            histories: [
                "first-history": "first transcript",
                "second-history": "second transcript"
            ]
        ) else {
            return XCTFail("recursive tab should restore")
        }
        defer { project.terminateAll() }

        XCTAssertEqual(tab.sessions.map(\.historyKey), ["first-history", "second-history"])
    }

    func testMenuCapabilitiesFollowFocusWithinOneSplitTab() {
        let project = Project(fallbackName: "split", createInitialSession: false)
        let editor = Pane(content: .file(FileTab(path: "/tmp/yeet-focus.swift")))
        let browser = Pane(content: .browser(BrowserTab(initialURL: nil, initialFocus: .none)))
        let layout = PaneNode.pane(editor).inserting(browser, toward: .right, beside: editor.id)
        let tab = PaneTab(layout: layout, focusedPaneID: editor.id)
        project.append(tab)

        XCTAssertTrue(project.canFind)
        XCTAssertTrue(project.canReplace)
        XCTAssertFalse(project.hasSelectedBrowser)
        XCTAssertTrue(project.hasSplitPanes)

        tab.focusNext()
        XCTAssertFalse(project.canFind)
        XCTAssertFalse(project.canReplace)
        XCTAssertTrue(project.hasSelectedBrowser)
        XCTAssertFalse(project.canClearActiveTerminal)

        tab.focusPrevious()
        XCTAssertTrue(project.canFind)
        XCTAssertTrue(project.canReplace)
        XCTAssertFalse(project.hasSelectedBrowser)
    }

    func testRestoreLeavesAbsentHistoryUnattached() {
        let project = Project(fallbackName: "restore", createInitialSession: false)
        let pane = SessionSnapshot.ProjectSnapshot.PaneSnapshot(
            content: .session(workingDirectory: "/tmp", agentKind: nil, agentSessionID: nil),
            weight: 1,
            historyKey: "missing"
        )
        let snapshot = SessionSnapshot.ProjectSnapshot.TabSnapshot(
            layout: .pane(pane), focusedPaneIndex: 0
        )

        guard let tab = project.restoreTab(from: snapshot, histories: [:]) else {
            return XCTFail("tab should restore without optional history")
        }
        defer { project.terminateAll() }
        XCTAssertEqual(tab.sessions.first?.historyKey, "missing")
        XCTAssertNil(tab.sessions.first?.serializedHistory(captureLive: false))
    }
}
