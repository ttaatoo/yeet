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

    func testRecursiveRestorePassesHistoryAndKeysToEachTerminal() throws {
        let settings = AppSettings.shared
        let previousRestore = settings.restoreTerminalHistory
        let previousConfig: Data?
        if FileManager.default.fileExists(atPath: AppSettings.configURL.path) {
            previousConfig = try Data(contentsOf: AppSettings.configURL)
        } else {
            previousConfig = nil
        }
        settings.restoreTerminalHistory = true
        defer {
            settings.restoreTerminalHistory = previousRestore
            if let previousConfig {
                try? previousConfig.write(to: AppSettings.configURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: AppSettings.configURL)
            }
        }
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
        XCTAssertEqual(
            tab.sessions.map { $0.serializedHistory(captureLive: false) },
            ["first transcript", "second transcript"]
        )
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

    func testMarkdownPreviewOpensBesideThenReusesTheSamePane() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-md-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = root.appendingPathComponent("plan.md")
        try Data("# Plan\n".utf8).write(to: markdown)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project(fallbackName: "markdown", createInitialSession: false)
        let session = project.newSession(
            directory: root.path,
            commandArguments: ["/bin/sh", "-c", "sleep 2"]
        )
        defer { session.terminate() }

        guard case .markdown(let classified) = session.terminalLinkTarget(for: "plan.md")
        else {
            return XCTFail("an existing relative .md path must classify as markdown")
        }
        XCTAssertTrue(MarkdownPreviewRouting.pathsEqual(classified.path, markdown.path))
        guard case .markdown = session.terminalLinkTarget(for: "plan.md:12") else {
            return XCTFail("trailing :line must still resolve to the markdown file")
        }

        let notes = root.appendingPathComponent("notes.txt")
        try Data("plain\n".utf8).write(to: notes)
        guard case .file(let textURL) = session.terminalLinkTarget(for: "notes.txt") else {
            return XCTFail("non-markdown local files stay the Finder target")
        }
        XCTAssertTrue(MarkdownPreviewRouting.pathsEqual(textURL.path, notes.path))

        guard case .url(let web) = session.terminalLinkTarget(for: "https://example.com")
        else {
            return XCTFail("http(s) stays on the existing browser URL path")
        }
        XCTAssertEqual(web.scheme, "https")

        project.openMarkdownPreviewToSide(markdown.path)
        XCTAssertEqual(project.selectedTab?.allPanes.count, 2)
        guard case .markdownPreview(let preview) = project.focusedContent else {
            return XCTFail("expected a markdown preview beside the terminal")
        }
        XCTAssertTrue(MarkdownPreviewRouting.pathsEqual(preview.path, markdown.path))

        project.openMarkdownPreviewToSide(markdown.path)
        XCTAssertEqual(project.selectedTab?.allPanes.count, 2)
        guard case .markdownPreview = project.focusedContent else {
            return XCTFail("the existing preview should be focused, not stacked")
        }
    }

    func testRestoreMarkdownPreviewPane() {
        let project = Project(fallbackName: "restore-md", createInitialSession: false)
        let pane = SessionSnapshot.ProjectSnapshot.PaneSnapshot(
            content: .markdownPreview(path: "/tmp/plan.md"),
            weight: 1
        )
        let snapshot = SessionSnapshot.ProjectSnapshot.TabSnapshot(
            layout: .pane(pane), focusedPaneIndex: 0
        )
        guard let tab = project.restoreTab(from: snapshot) else {
            return XCTFail("markdown preview tab should restore")
        }
        guard case .markdownPreview(let preview) = tab.focusedContent else {
            return XCTFail("restored content should be a markdown preview")
        }
        XCTAssertEqual(preview.path, "/tmp/plan.md")
        XCTAssertFalse(project.canReplace)
        XCTAssertFalse(project.canFind)
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
