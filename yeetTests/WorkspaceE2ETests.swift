//
//  WorkspaceE2ETests.swift
//  yeetTests
//

import XCTest
@testable import yeet

/// Live PTY, file-tree, and Git paths that unit fixtures cannot reach.
@MainActor
final class WorkspaceE2ETests: XCTestCase {
    func testTerminalPtyPrintsOnTheVisibleGrid() async throws {
        let directory = try makeTempDirectory(prefix: "yeet-e2e-term")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Keep the child alive after printf. A one-shot command fires EXIT
        // and `TerminalSession` detaches the surface before the read.
        let session = TerminalSession(
            initialDirectory: directory.path,
            commandArguments: [
                "/bin/zsh", "-f", "-c",
                "printf %s\\n YEET_E2E_OK; exec sleep 60",
            ]
        )
        defer { session.terminate() }

        // A terminal starts only after AppKit attaches it at a stable pane
        // size. Exercise the production lifecycle instead of creating a PTY
        // for a detached, zero-sized test view.
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host
        let surface = session.surface
        surface.frame = host.bounds
        host.addSubview(surface)
        window.orderFront(nil)
        surface.setSurfaceVisible(true)
        defer {
            surface.removeFromSuperview()
            window.contentView = nil
            window.close()
        }

        let text = try await waitUntil(timeout: 8) {
            session.surface.readVisibleText(maxLines: 8, maxColumns: 80)
        } satisfies: { $0?.contains("YEET_E2E_OK") == true }

        XCTAssertTrue(
            text?.contains("YEET_E2E_OK") == true,
            "visible grid was \(text ?? "nil")"
        )
    }

    func testFileTreeListsTheProjectRoot() async throws {
        let directory = try makeTempDirectory(prefix: "yeet-e2e-tree")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hello".write(
            to: directory.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )

        let tree = FileTreeModel()
        tree.sync(root: directory.path)
        let items = try await waitUntil(timeout: 5) {
            tree.items
        } satisfies: { items in
            items.contains { $0.name == "alpha.txt" && !$0.isDirectory }
                && items.contains { $0.name == "src" && $0.isDirectory }
        }

        XCTAssertEqual(tree.rootPath, directory.path)
        XCTAssertTrue(items.contains { $0.name == "alpha.txt" })
        XCTAssertTrue(items.contains { $0.name == "src" && $0.isDirectory })
        XCTAssertFalse(items.contains { $0.name == ".git" })
    }

    func testGitStatusReadsALiveRepository() async throws {
        let directory = try makeTempDirectory(prefix: "yeet-e2e-git")
        defer { try? FileManager.default.removeItem(at: directory) }

        let initGit = GitStatusModel.runGit(["init", "-b", "main"], in: directory.path)
        XCTAssertEqual(initGit.status, 0, initGit.stderr)
        try "change".write(
            to: directory.appendingPathComponent("work.txt"),
            atomically: true,
            encoding: .utf8
        )

        let git = GitStatusModel()
        try await loadGit(git, root: directory.path)

        XCTAssertTrue(git.isRepo)
        XCTAssertEqual(git.branch, "main")
        XCTAssertTrue(
            git.changedEntries.contains { $0.path == "work.txt" && $0.isUntracked },
            "changed entries were \(git.changedEntries.map(\.path))"
        )
        XCTAssertEqual(git.fileDecorations["work.txt"], .untracked)
    }

    func testGitStatusMarksAPlainDirectory() async throws {
        let directory = try makeTempDirectory(prefix: "yeet-e2e-nongit")
        defer { try? FileManager.default.removeItem(at: directory) }

        let git = GitStatusModel()
        try await loadGit(git, root: directory.path)

        XCTAssertFalse(git.isRepo)
        XCTAssertTrue(git.changedEntries.isEmpty)
    }

    func testPanelRootFollowsLinkedAgentWorktree() throws {
        let repo = try makeTempGitRepository(prefix: "yeet-e2e-wt")
        defer { try? FileManager.default.removeItem(at: repo) }

        let checkout = try KeroAgentWorktree.prepare(alias: "iso", cwd: repo.path).get()
        defer {
            _ = KeroAgentWorktree.remove(path: checkout.path, in: repo.path)
            try? FileManager.default.removeItem(atPath: checkout.path)
        }
        XCTAssertTrue(GitRepositoryLocator.isLinkedWorktree(checkout.path))

        let project = Project(fallbackName: "e2e-wt", createInitialSession: false)
        let shared = project.panelRoot(followingSessionAt: repo.path)
        XCTAssertEqual(shared.source, .shell)

        let (root, source) = project.panelRoot(
            followingSessionAt: repo.path,
            foregroundAt: checkout.path
        )
        XCTAssertEqual(
            (root as NSString).standardizingPath,
            (checkout.path as NSString).standardizingPath
        )
        XCTAssertEqual(source, .foreground(isWorktree: true))
    }

    func testPaneSplitThenRemoveCollapses() {
        let first = Pane(content: .file(FileTab(path: "/tmp/yeet-e2e-a.swift")))
        let second = Pane(content: .file(FileTab(path: "/tmp/yeet-e2e-b.swift")))
        var node = PaneNode.pane(first)
        node = node.inserting(second, toward: .bottom, beside: first.id)
        XCTAssertEqual(node.allPanes.count, 2)
        guard case .split(let split) = node else {
            return XCTFail("insert should create a split")
        }
        XCTAssertEqual(split.axis, .vertical)

        let removed = node.removingPane(first.id)
        guard case .pane(let remaining) = removed.node else {
            return XCTFail("removing one side should collapse the split")
        }
        XCTAssertEqual(remaining.id, second.id)
    }
}

private extension WorkspaceE2ETests {
    func makeTempDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func makeTempGitRepository(prefix: String) throws -> URL {
        let directory = try makeTempDirectory(prefix: prefix)
        let initGit = GitStatusModel.runGit(["init", "-b", "main"], in: directory.path)
        XCTAssertEqual(initGit.status, 0, initGit.stderr)
        try "init\n".write(
            to: directory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GitStatusModel.runGit(["add", "README.md"], in: directory.path).status, 0)
        let commit = GitStatusModel.runGit(
            [
                "-c", "user.name=Yeet Test",
                "-c", "user.email=yeet@test.local",
                "-c", "commit.gpgsign=false",
                "commit", "-m", "init",
            ],
            in: directory.path
        )
        XCTAssertEqual(commit.status, 0, commit.stderr)
        return directory
    }
}
