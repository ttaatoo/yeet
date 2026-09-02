//
//  GitInspectorE2ETests.swift
//  yeetTests
//
//  Live Git / file-tree / diff-tab contract for the inspector. These paths
//  are what a Git panel performance rewrite must preserve: porcelain buckets,
//  mutations, decorations, history paging, and both sides of a file diff.

import XCTest
@testable import yeet

@MainActor
final class GitInspectorE2ETests: XCTestCase {
    func testStatusWaitRejectsAFailedRefresh() async throws {
        let directory = try GitInspectorFixtures.makeTempDirectory(prefix: "yeet-git-broken")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"), withIntermediateDirectories: false
        )

        let git = GitStatusModel()
        do {
            try await loadGit(git, root: directory.path)
            XCTFail("a completed refresh with a Git error must not satisfy the status wait")
        } catch let error as GitStatusLoadFailed {
            XCTAssertEqual(error.message, git.statusError)
        }
        XCTAssertTrue(git.hasResolvedStatus)
        XCTAssertFalse(git.isRefreshing)
        XCTAssertFalse(git.isRepo)
    }

    func testStatusSplitsStagedUnstagedUntrackedAndIgnored() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-status",
            files: [
                "README.md": "hello\n",
                ".gitignore": "*.ignored\nbuild/\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }

        try repo.write("README.md", "hello world\n")
        try repo.write("staged.swift", "print(1)\n")
        try repo.git(["add", "staged.swift"])
        try repo.write("unstaged.txt", "raw\n")
        try repo.write("secret.ignored", "nope\n")
        try repo.write("build/out.txt", "artifact\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)

        XCTAssertTrue(git.isRepo)
        XCTAssertEqual(git.branch, "main")
        XCTAssertEqual(
            (git.repoRoot as NSString).standardizingPath,
            (repo.path as NSString).standardizingPath
        )
        XCTAssertTrue(git.mergeEntries.isEmpty)
        XCTAssertTrue(
            git.stagedEntries.contains { $0.path == "staged.swift" && $0.staged == "A" }
        )
        XCTAssertTrue(
            git.changedEntries.contains { $0.path == "README.md" && $0.unstaged == "M" }
        )
        XCTAssertTrue(
            git.changedEntries.contains { $0.path == "unstaged.txt" && $0.isUntracked }
        )
        XCTAssertEqual(git.fileDecorations["staged.swift"], .added)
        XCTAssertEqual(git.fileDecorations["README.md"], .modified)
        XCTAssertEqual(git.fileDecorations["unstaged.txt"], .untracked)
        XCTAssertEqual(
            git.fileDecoration(for: repo.url("secret.ignored").path, isDirectory: false),
            .ignored
        )
        XCTAssertEqual(
            git.fileDecoration(for: repo.url("build").path, isDirectory: true),
            .ignored
        )
        XCTAssertEqual(
            git.fileDecoration(for: repo.url("build/out.txt").path, isDirectory: false),
            .ignored
        )
        XCTAssertNil(
            git.fileDecoration(for: "/tmp/yeet-not-in-repo.txt", isDirectory: false)
        )
        XCTAssertGreaterThanOrEqual(git.lineAdditions, 1)
        XCTAssertEqual(GitStatusModel.dirtyFileCount(in: repo.path), git.uniqueDirtyPathCount)
    }

    func testModifiedFileSitsInStagedAndChangedWithOneDirtyPath() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-mm",
            files: ["tracked.txt": "v1\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("tracked.txt", "v2\n")
        try repo.git(["add", "tracked.txt"])
        try repo.write("tracked.txt", "v3\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)

        XCTAssertTrue(git.stagedEntries.contains { $0.path == "tracked.txt" && $0.staged == "M" })
        XCTAssertTrue(git.changedEntries.contains { $0.path == "tracked.txt" && $0.unstaged == "M" })
        XCTAssertEqual(git.uniqueDirtyPathCount, 1)
        XCTAssertEqual(git.totalChangeCount, 2)
        let staged = try XCTUnwrap(git.stagedEntries.first { $0.path == "tracked.txt" })
        let changed = try XCTUnwrap(git.changedEntries.first { $0.path == "tracked.txt" })
        XCTAssertNotEqual(staged.stagedRowID, changed.changedRowID)
    }

    func testDirectoryDecorationRollsUpFromNestedFile() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-dir",
            files: ["src/app/main.swift": "print(1)\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("src/app/main.swift", "print(2)\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)

        XCTAssertEqual(
            git.fileDecoration(for: repo.url("src/app/main.swift").path, isDirectory: false),
            .modified
        )
        XCTAssertEqual(
            git.fileDecoration(for: repo.url("src/app").path, isDirectory: true),
            .modified
        )
        XCTAssertEqual(
            git.fileDecoration(for: repo.url("src").path, isDirectory: true),
            .modified
        )
    }

    func testFileTreeListsDecoratedPathsAndExpandsDirectories() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-tree",
            files: [
                "README.md": "hello\n",
                "src/main.swift": "print(1)\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("src/main.swift", "print(2)\n")

        let git = GitStatusModel()
        let tree = FileTreeModel()
        try await loadGit(git, root: repo.path)
        tree.sync(root: repo.path)
        let items = try await waitUntil(description: "file tree root") {
            tree.items
        } satisfies: { items in
            items.contains { $0.name == "README.md" }
                && items.contains { $0.name == "src" && $0.isDirectory }
        }
        XCTAssertFalse(items.contains { $0.name == ".git" })
        let folder = try XCTUnwrap(items.first { $0.name == "src" })
        XCTAssertEqual(
            git.fileDecoration(for: folder.path, isDirectory: true),
            .modified
        )

        tree.toggle(folder)
        let expanded = try await waitUntil(description: "expanded src") {
            tree.items
        } satisfies: { $0.contains { $0.name == "main.swift" } }
        let file = try XCTUnwrap(expanded.first { $0.name == "main.swift" })
        XCTAssertEqual(
            git.fileDecoration(for: file.path, isDirectory: false),
            .modified
        )
    }

    func testStageUnstageAndStageAllRoundTrip() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-stage")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("one.txt", "1\n")
        try repo.write("two.txt", "2\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        let one = try XCTUnwrap(git.changedEntries.first { $0.path == "one.txt" })
        git.stage(one)
        try await waitForGitStatus(git)
        XCTAssertTrue(git.stagedEntries.contains { $0.path == "one.txt" })
        XCTAssertTrue(git.changedEntries.contains { $0.path == "two.txt" })

        let staged = try XCTUnwrap(git.stagedEntries.first { $0.path == "one.txt" })
        git.unstage(staged)
        try await waitForGitStatus(git)
        XCTAssertTrue(git.stagedEntries.isEmpty)
        XCTAssertEqual(Set(git.changedEntries.map(\.path)), ["one.txt", "two.txt"])

        git.stageAll()
        try await waitForGitStatus(git)
        XCTAssertEqual(Set(git.stagedEntries.map(\.path)), ["one.txt", "two.txt"])
        XCTAssertTrue(git.changedEntries.isEmpty)

        git.unstageAll()
        try await waitForGitStatus(git)
        XCTAssertTrue(git.stagedEntries.isEmpty)
        XCTAssertEqual(Set(git.changedEntries.map(\.path)), ["one.txt", "two.txt"])
    }

    func testCommitRequiresMessageAndStagedFilesThenClearsIndex() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-commit")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("ready.txt", "go\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)

        git.commit(message: "   ", includeAll: false)
        XCTAssertEqual(git.lastError, "Enter a commit message")

        git.commit(message: "no staged files", includeAll: false)
        XCTAssertEqual(git.lastError, "Stage changes before committing")

        git.stageAll()
        try await waitForGitStatus(git)
        git.commit(message: "add ready", includeAll: false)
        try await waitForGitStatus(git)
        XCTAssertNil(git.lastError)
        XCTAssertEqual(git.totalChangeCount, 0)
        XCTAssertEqual(git.recentCommits.first?.subject, "add ready")
    }

    func testCommitIncludeAllStagesUntrackedThenCreatesCommit() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-commit-all")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("extra.txt", "all\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        git.commit(message: "include all", includeAll: true)
        try await waitForGitStatus(git)
        XCTAssertEqual(git.totalChangeCount, 0)
        XCTAssertEqual(git.recentCommits.first?.subject, "include all")
    }

    func testDiscardRestoresTrackedFileAndTrashesUntrackedFile() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-discard",
            files: ["kept.txt": "original\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("kept.txt", "edited\n")
        try repo.write("gone.txt", "temp\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        let tracked = try XCTUnwrap(git.changedEntries.first { $0.path == "kept.txt" })
        git.discard(tracked)
        try await waitForGitStatus(git)
        XCTAssertEqual(try String(contentsOf: repo.url("kept.txt"), encoding: .utf8), "original\n")
        XCTAssertFalse(git.changedEntries.contains { $0.path == "kept.txt" })

        let untracked = try XCTUnwrap(git.changedEntries.first { $0.path == "gone.txt" })
        git.discard(untracked)
        try await waitForGitStatus(git)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url("gone.txt").path))
        XCTAssertFalse(git.changedEntries.contains { $0.path == "gone.txt" })
    }

    func testRenameKeepsOriginalPathForStagedRow() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-rename",
            files: ["old name.txt": "body\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.git(["mv", "old name.txt", "new name.txt"])

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        let entry = try XCTUnwrap(git.stagedEntries.first { $0.path == "new name.txt" })
        XCTAssertEqual(entry.staged, Character("R"))
        XCTAssertEqual(entry.origPath, "old name.txt")
        XCTAssertEqual(git.fileDecorations["new name.txt"], .renamed)
    }

    func testIntentToAddIsUntrackedForDestructiveActions() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-intent")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("intent.txt", "seed\n")
        try repo.git(["add", "-N", "intent.txt"])

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        let entry = try XCTUnwrap(git.changedEntries.first { $0.path == "intent.txt" })
        XCTAssertTrue(entry.isIntentToAdd)
        XCTAssertTrue(entry.isUntracked)
    }

    func testMergeConflictLandsInMergeEntries() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-merge",
            files: ["conflict.txt": "base\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.git(["switch", "-c", "other"])
        try repo.write("conflict.txt", "other\n")
        try repo.git(["commit", "-am", "other side"])
        try repo.git(["switch", "main"])
        try repo.write("conflict.txt", "main\n")
        try repo.git(["commit", "-am", "main side"])
        let merge = repo.gitAllowingFailure(["merge", "other"])
        XCTAssertNotEqual(merge.status, 0)

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        XCTAssertTrue(git.mergeEntries.contains { $0.path == "conflict.txt" && $0.isConflict })
        XCTAssertEqual(git.fileDecorations["conflict.txt"], .conflict)
        XCTAssertEqual(
            git.fileDecoration(for: repo.url("conflict.txt").path, isDirectory: false),
            .conflict
        )
    }

    func testUntrackedLineCountAddsToToolbarTotals() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-lines")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("new.txt", "a\nb\nc\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        XCTAssertGreaterThanOrEqual(git.lineAdditions, 3)
        XCTAssertEqual(git.lineDeletions, 0)
    }

    func testRecentCommitsIncludeFilesAndLoadMorePages() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-log",
            files: ["seed.txt": "0\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        for index in 1...32 {
            try repo.git(["commit", "--allow-empty", "-m", "empty \(index)"])
        }

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path, timeout: 12)
        XCTAssertEqual(git.recentCommits.count, 30)
        XCTAssertTrue(git.hasMoreRecentCommits)
        XCTAssertEqual(git.recentCommits.first?.subject, "empty 32")
        XCTAssertFalse(git.recentCommits.contains { $0.subject == "initial" })

        XCTAssertTrue(git.loadMoreCommits())
        try await waitForGitStatus(git, timeout: 12)
        XCTAssertEqual(git.recentCommits.count, 33)
        XCTAssertFalse(git.hasMoreRecentCommits)
        XCTAssertEqual(git.recentCommits.last?.subject, "initial")
        XCTAssertTrue(
            git.recentCommits.last?.files.contains { $0.path == "seed.txt" && $0.status == "A" } == true
        )
    }

    func testCreateAndSwitchBranch() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-branch")
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        git.createBranch(named: "topic")
        try await waitForGitStatus(git)
        XCTAssertEqual(git.branch, "topic")
        // The details cache keys on HEAD oid, not the branch name. `switch -c`
        // keeps the same oid, so the picker list may still be ["main"] until
        // a later commit. Porcelain `branch.head` is the inspector contract.

        git.switchBranch(to: "main")
        try await waitForGitStatus(git)
        XCTAssertEqual(git.branch, "main")
    }

    func testStashThenPopRestoresUntrackedFile() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-stash")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("stashed.txt", "hold\n")

        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        git.stash(includeUntracked: true)
        try await waitForGitStatus(git)
        XCTAssertEqual(git.totalChangeCount, 0)
        XCTAssertEqual(git.stashCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url("stashed.txt").path))

        git.stashPop()
        try await waitForGitStatus(git)
        XCTAssertEqual(git.stashCount, 0)
        XCTAssertTrue(git.changedEntries.contains { $0.path == "stashed.txt" && $0.isUntracked })
    }

    func testInitializeRepositoryOnPlainDirectory() async throws {
        let directory = try GitInspectorFixtures.makeTempDirectory(prefix: "yeet-git-init")
        defer { try? FileManager.default.removeItem(at: directory) }

        let git = GitStatusModel()
        try await loadGit(git, root: directory.path)
        XCTAssertFalse(git.isRepo)

        git.initializeRepository()
        try await waitForGitStatus(git)
        XCTAssertTrue(git.isRepo)
    }

    func testSwitchingRepositoryRejectsStaleEntriesAndRestoresCache() async throws {
        let first = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-a",
            files: ["a.txt": "a\n"]
        )
        let second = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-b",
            files: ["b.txt": "b\n"]
        )
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        try first.write("dirty-a.txt", "a-new\n")
        try second.write("dirty-b.txt", "b-new\n")

        let git = GitStatusModel()
        try await loadGit(git, root: first.path)
        let stale = try XCTUnwrap(git.changedEntries.first { $0.path == "dirty-a.txt" })
        XCTAssertTrue(git.isCurrent(stale))

        try await loadGit(git, root: second.path)
        XCTAssertTrue(git.changedEntries.contains { $0.path == "dirty-b.txt" })
        XCTAssertFalse(git.changedEntries.contains { $0.path == "dirty-a.txt" })
        XCTAssertFalse(git.isCurrent(stale))
        git.stage(stale)
        XCTAssertEqual(
            git.lastError,
            "Repository changed; refresh and try the Git action again"
        )

        git.sync(root: first.path)
        XCTAssertTrue(git.changedEntries.contains { $0.path == "dirty-a.txt" })
        try await waitForGitStatus(git)
        XCTAssertTrue(git.changedEntries.contains { $0.path == "dirty-a.txt" })
    }

    func testCancelStaleDiscardSetsError() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-stale")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        git.cancelStaleDiscard()
        XCTAssertEqual(
            git.lastError,
            "Files changed while the confirmation was open. Review them and try again."
        )
    }

    func testSyncEmptyRootClearsRepositoryState() async throws {
        let repo = try GitInspectorFixtures.makeRepository(prefix: "yeet-git-clear")
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let git = GitStatusModel()
        try await loadGit(git, root: repo.path)
        XCTAssertTrue(git.isRepo)

        git.sync(root: "")
        XCTAssertFalse(git.isRepo)
        XCTAssertTrue(git.stagedEntries.isEmpty)
        XCTAssertTrue(git.changedEntries.isEmpty)
        XCTAssertTrue(git.recentCommits.isEmpty)
    }

    func testDiffTabLoadsUntrackedStagedUnstagedAndSavesEdits() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-diff",
            files: ["README.md": "hello\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("new.txt", "untracked-body\n")
        try repo.write("README.md", "worktree\n")
        try repo.git(["add", "README.md"])
        try repo.write("README.md", "worktree-edit\n")

        let untracked = DiffTab(
            repoRoot: repo.path, path: "new.txt",
            staged: false, untracked: true, origPath: nil
        )
        try await waitUntil(description: "untracked diff") { !untracked.isLoading } satisfies: { $0 }
        XCTAssertNil(untracked.error)
        XCTAssertEqual(untracked.web.oldContent, "")
        XCTAssertEqual(untracked.web.newContent, "untracked-body\n")
        XCTAssertTrue(untracked.isEditable)

        let staged = DiffTab(
            repoRoot: repo.path, path: "README.md",
            staged: true, untracked: false, origPath: nil
        )
        try await waitUntil(description: "staged diff") { !staged.isLoading } satisfies: { $0 }
        XCTAssertEqual(staged.web.oldContent, "hello\n")
        XCTAssertEqual(staged.web.newContent, "worktree\n")
        XCTAssertFalse(staged.isEditable)

        let unstaged = DiffTab(
            repoRoot: repo.path, path: "README.md",
            staged: false, untracked: false, origPath: nil
        )
        try await waitUntil(description: "unstaged diff") { !unstaged.isLoading } satisfies: { $0 }
        XCTAssertEqual(unstaged.web.oldContent, "worktree\n")
        XCTAssertEqual(unstaged.web.newContent, "worktree-edit\n")
        XCTAssertTrue(unstaged.isEditable)

        unstaged.updateEditedContent(fileID: "README.md", contents: "saved\n")
        XCTAssertTrue(unstaged.isDirty)
        unstaged.save()
        XCTAssertFalse(unstaged.isDirty)
        XCTAssertEqual(try String(contentsOf: repo.url("README.md"), encoding: .utf8), "saved\n")
    }

    func testDiffTabHistoricalBlobSkipsReloadOnReselect() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-diff-hist",
            files: ["file.txt": "before\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("file.txt", "after\n")
        try repo.git(["commit", "-am", "change file"])
        let head = try repo.git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = try repo.git(["rev-parse", "HEAD^"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let diff = DiffTab(
            repoRoot: repo.path, path: "file.txt",
            staged: false, untracked: false, origPath: nil,
            commitHash: head, commitParentHash: parent, commitStatus: "M"
        )
        try await waitUntil(description: "historical diff") { !diff.isLoading } satisfies: { $0 }
        XCTAssertEqual(diff.web.oldContent, "before\n")
        XCTAssertEqual(diff.web.newContent, "after\n")
        XCTAssertFalse(diff.isEditable)
        diff.refreshWhenSelected()
        XCTAssertFalse(diff.isLoading)
        XCTAssertEqual(diff.web.oldContent, "before\n")
        XCTAssertEqual(diff.web.newContent, "after\n")
    }

    func testDiffTabReportsBinaryAndUsesRenameOrigPath() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-diff-bin",
            files: ["old.txt": "same\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.writeData("blob.bin", Data([0x00, 0x01, 0x00, 0xFF]))
        try repo.git(["add", "blob.bin"])
        try repo.git(["commit", "-m", "binary"])
        try repo.git(["mv", "old.txt", "new.txt"])

        let binary = DiffTab(
            repoRoot: repo.path, path: "blob.bin",
            staged: false, untracked: false, origPath: nil
        )
        try await waitUntil(description: "binary diff") { !binary.isLoading } satisfies: { $0 }
        XCTAssertEqual(binary.error, "Binary file")

        let renamed = DiffTab(
            repoRoot: repo.path, path: "new.txt",
            staged: true, untracked: false, origPath: "old.txt"
        )
        try await waitUntil(description: "rename diff") { !renamed.isLoading } satisfies: { $0 }
        XCTAssertNil(renamed.error)
        XCTAssertEqual(renamed.web.oldContent, "same\n")
        XCTAssertEqual(renamed.web.newContent, "same\n")
    }

    func testRecentCommitsViewHeightGrowsWhenExpanded() {
        let commits = GitInspectorFixtures.recentCommits(count: 4, filesInFirst: 8, filesInOthers: 1)
        let view = RecentCommitsNSView()
        view.configure(
            commits: commits,
            expandedCommitIDs: [],
            fontScale: 1,
            hasMoreCommits: false,
            isLoadingMore: false
        )
        let collapsed = view.requiredHeight
        XCTAssertGreaterThan(collapsed, 0)

        view.configure(
            commits: commits,
            expandedCommitIDs: [commits[0].id],
            fontScale: 1,
            hasMoreCommits: false,
            isLoadingMore: false
        )
        XCTAssertGreaterThan(view.requiredHeight, collapsed)
    }

    func testLiveUnstagedDiffReloadsWhenSelectedAgain() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-diff-reload",
            files: ["live.txt": "one\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try repo.write("live.txt", "two\n")

        let diff = DiffTab(
            repoRoot: repo.path, path: "live.txt",
            staged: false, untracked: false, origPath: nil
        )
        try await waitUntil(description: "first live diff") { !diff.isLoading } satisfies: { $0 }
        XCTAssertEqual(diff.web.newContent, "two\n")

        // Reload deliberately preserves the editor's buffer in edit mode.
        // This test covers review-mode navigation, independent of the user's
        // saved Debug preference, and restores that preference afterwards.
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: "diffView.mode")
        defer {
            diff.setEditing(previousMode == "edit")
            if let previousMode {
                defaults.set(previousMode, forKey: "diffView.mode")
            } else {
                defaults.removeObject(forKey: "diffView.mode")
            }
        }
        diff.setEditing(false)

        try repo.write("live.txt", "three\n")
        diff.refreshWhenSelected()
        try await waitUntil(description: "reloaded live diff") {
            !diff.isLoading && diff.web.newContent == "three\n"
        } satisfies: { $0 }
        XCTAssertEqual(diff.web.newContent, "three\n")
    }

    func testDiscardDoesNotCrashOnCanonicallyEquivalentPaths() async throws {
        let directory = try GitInspectorFixtures.makeTempDirectory(prefix: "yeet-git-discard-unicode")
        defer { try? FileManager.default.removeItem(at: directory) }

        let initGit = GitStatusModel.runGit(["init", "-b", "main"], in: directory.path)
        XCTAssertEqual(initGit.status, 0, initGit.stderr)
        for args in [
            ["config", "user.name", "Yeet Test"],
            ["config", "user.email", "yeet.test@example.com"],
            ["config", "commit.gpgsign", "false"],
        ] {
            let config = GitStatusModel.runGit(args, in: directory.path)
            XCTAssertEqual(config.status, 0, config.stderr)
        }

        let composedPath = "caf\u{e9}.txt"
        let decomposedPath = "cafe\u{301}.txt"
        XCTAssertEqual(composedPath, decomposedPath)
        XCTAssertNotEqual(
            Array(composedPath.unicodeScalars), Array(decomposedPath.unicodeScalars)
        )
        try "original\n".write(
            to: directory.appendingPathComponent(composedPath),
            atomically: true,
            encoding: .utf8
        )
        let add = GitStatusModel.runGit(
            ["--literal-pathspecs", "add", "--", composedPath],
            in: directory.path
        )
        XCTAssertEqual(add.status, 0, add.stderr)
        let commit = GitStatusModel.runGit(["commit", "-m", "initial"], in: directory.path)
        XCTAssertEqual(commit.status, 0, commit.stderr)
        try "edited\n".write(
            to: directory.appendingPathComponent(composedPath),
            atomically: true,
            encoding: .utf8
        )
        try "temp\n".write(
            to: directory.appendingPathComponent("gone.txt"),
            atomically: true,
            encoding: .utf8
        )

        let git = GitStatusModel()
        try await loadGit(git, root: directory.path)

        let tracked = try XCTUnwrap(
            git.changedEntries.first { $0.path == composedPath || $0.path == decomposedPath }
        )
        let collidingRename = GitStatusModel.Entry(
            path: composedPath,
            staged: ".",
            unstaged: "R",
            origPath: decomposedPath,
            repositoryRoot: tracked.repositoryRoot
        )
        let fingerprints = GitStatusModel.discardFingerprints(for: collidingRename) { path in
            (directory.path as NSString).appendingPathComponent(path)
        }
        XCTAssertEqual(fingerprints.count, 1)
        XCTAssertEqual(
            Array(collidingRename.path.unicodeScalars),
            Array(composedPath.unicodeScalars)
        )
        XCTAssertEqual(
            Array(collidingRename.origPath!.unicodeScalars),
            Array(decomposedPath.unicodeScalars)
        )

        git.discard(tracked)
        try await waitForGitStatus(git)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(composedPath),
                encoding: .utf8
            ),
            "original\n"
        )
        XCTAssertFalse(
            git.changedEntries.contains { $0.path == composedPath || $0.path == decomposedPath }
        )

        let untracked = try XCTUnwrap(git.changedEntries.first { $0.path == "gone.txt" })
        git.discard(untracked)
        try await waitForGitStatus(git)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("gone.txt").path
            )
        )
        XCTAssertFalse(git.changedEntries.contains { $0.path == "gone.txt" })
    }
}
