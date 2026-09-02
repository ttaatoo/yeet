//
//  GitPorcelainTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class GitPorcelainTests: XCTestCase {
    func testParseStatusOrdinaryAndUntracked() {
        let output = [
            "# branch.oid abcdef",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 MM N... 100644 100644 100644 0000000 0000000 file.swift",
            "? new.txt",
            "! ignored.bin",
        ].joined(separator: "\0") + "\0"

        let result = GitStatusModel.parseStatus(output)
        XCTAssertEqual(result.branch, "main")
        XCTAssertEqual(result.ahead, 2)
        XCTAssertEqual(result.behind, 1)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].path, "file.swift")
        XCTAssertEqual(result.entries[0].staged, Character("M"))
        XCTAssertEqual(result.entries[0].unstaged, Character("M"))
        XCTAssertEqual(result.entries[1].path, "new.txt")
        XCTAssertTrue(result.ignoredPaths.contains("ignored.bin"))
        XCTAssertEqual(GitStatusModel.dirtyFileCount(from: result), 2)
    }

    func testParseStatusRenameUsesFollowingToken() {
        let output = [
            "2 RM N... 100644 100644 100644 0000000 0000000 R100 new name.txt",
            "old name.txt",
        ].joined(separator: "\0") + "\0"

        let result = GitStatusModel.parseStatus(output)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].path, "new name.txt")
        XCTAssertEqual(result.entries[0].origPath, "old name.txt")
        XCTAssertEqual(result.entries[0].staged, Character("R"))
        XCTAssertEqual(result.entries[0].unstaged, Character("M"))
    }

    func testParseNumstatIgnoresBinaryDash() {
        let output = """
        3\t1\tfoo.swift
        -\t-\tphoto.png
        2\t0\tbar.swift
        """
        let totals = GitStatusModel.parseNumstat(output)
        XCTAssertEqual(totals.additions, 5)
        XCTAssertEqual(totals.deletions, 1)
    }

    func testDirectoryDecorationRollupPicksHighestPriority() {
        let decorations: [String: GitStatusModel.FileDecoration] = [
            "src/a.swift": .modified,
            "src/b.swift": .conflict,
            "docs/readme.md": .untracked,
        ]
        let dirs = GitStatusModel.rolledUpDirectoryDecorations(decorations)
        XCTAssertEqual(dirs["src"], .conflict)
        XCTAssertEqual(dirs["docs"], .untracked)
    }

    func testFileDecorationsMergeDuplicatePathsByPriority() {
        let entries = [
            GitStatusModel.Entry(path: "src/app.swift", staged: "M", unstaged: "."),
            GitStatusModel.Entry(
                path: "src/app.swift", staged: "U", unstaged: "U", isConflict: true
            ),
        ]

        let decorations = GitStatusModel.fileDecorations(for: entries)

        XCTAssertEqual(decorations.count, 1)
        XCTAssertEqual(decorations["src/app.swift"], .conflict)
    }

    func testFileDecorationsMergeCanonicallyEquivalentPathsByPriority() {
        let composedPath = "caf\u{e9}.txt"
        let decomposedPath = "cafe\u{301}.txt"
        XCTAssertEqual(composedPath, decomposedPath)
        XCTAssertNotEqual(
            Array(composedPath.unicodeScalars), Array(decomposedPath.unicodeScalars)
        )
        let entries = [
            GitStatusModel.Entry(path: composedPath, staged: "M", unstaged: "."),
            GitStatusModel.Entry(path: decomposedPath, staged: ".", unstaged: "D"),
        ]

        let decorations = GitStatusModel.fileDecorations(for: entries)

        XCTAssertEqual(decorations.count, 1)
        XCTAssertEqual(decorations[composedPath], .deleted)
        XCTAssertEqual(decorations[decomposedPath], .deleted)
    }

    func testDiscardFingerprintsMergeExactDuplicatePaths() {
        let entry = GitStatusModel.Entry(
            path: "src/app.swift",
            staged: ".",
            unstaged: "R",
            origPath: "src/app.swift"
        )
        var seen: [String] = []
        let fingerprints = GitStatusModel.discardFingerprints(for: entry) { path in
            seen.append(path)
            return "\(path)-fp"
        }

        XCTAssertEqual(GitStatusModel.discardFingerprintPaths(for: entry), [
            "src/app.swift", "src/app.swift",
        ])
        XCTAssertEqual(seen, ["src/app.swift", "src/app.swift"])
        XCTAssertEqual(fingerprints.count, 1)
        XCTAssertEqual(fingerprints["src/app.swift"], "src/app.swift-fp")
        XCTAssertEqual(entry.path, "src/app.swift")
        XCTAssertEqual(entry.origPath, "src/app.swift")
    }

    func testDiscardFingerprintsMergeCanonicallyEquivalentPathAndOrigPath() {
        let composedPath = "caf\u{e9}.txt"
        let decomposedPath = "cafe\u{301}.txt"
        XCTAssertEqual(composedPath, decomposedPath)
        XCTAssertNotEqual(
            Array(composedPath.unicodeScalars), Array(decomposedPath.unicodeScalars)
        )
        let entry = GitStatusModel.Entry(
            path: composedPath,
            staged: ".",
            unstaged: "R",
            origPath: decomposedPath
        )
        var seen: [[Unicode.Scalar]] = []
        let fingerprints = GitStatusModel.discardFingerprints(for: entry) { path in
            seen.append(Array(path.unicodeScalars))
            return Array(path.unicodeScalars)
        }

        let paths = GitStatusModel.discardFingerprintPaths(for: entry)
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(Array(paths[0].unicodeScalars), Array(composedPath.unicodeScalars))
        XCTAssertEqual(Array(paths[1].unicodeScalars), Array(decomposedPath.unicodeScalars))
        XCTAssertEqual(seen, [
            Array(composedPath.unicodeScalars),
            Array(decomposedPath.unicodeScalars),
        ])
        XCTAssertEqual(fingerprints.count, 1)
        XCTAssertEqual(fingerprints[composedPath], Array(composedPath.unicodeScalars))
        XCTAssertEqual(fingerprints[decomposedPath], Array(composedPath.unicodeScalars))
        XCTAssertEqual(Array(entry.path.unicodeScalars), Array(composedPath.unicodeScalars))
        XCTAssertEqual(Array(entry.origPath!.unicodeScalars), Array(decomposedPath.unicodeScalars))
    }

    func testDiscardFingerprintsKeepDistinctRenamePaths() {
        let entry = GitStatusModel.Entry(
            path: "new name.txt",
            staged: ".",
            unstaged: "R",
            origPath: "old name.txt"
        )
        let fingerprints = GitStatusModel.discardFingerprints(for: entry) { $0 }
        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertEqual(fingerprints["new name.txt"], "new name.txt")
        XCTAssertEqual(fingerprints["old name.txt"], "old name.txt")
    }

    func testShouldReuseCachedGitDetailsSameRootHeadAndLimit() {
        let key = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "abc123",
            recentCommitLimit: 30
        )
        XCTAssertTrue(GitStatusModel.shouldReuseCachedGitDetails(cached: key, current: key))
    }

    func testShouldReuseCachedGitDetailsWhenCachedLimitIsLarger() {
        let cached = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "abc123",
            recentCommitLimit: 60
        )
        let current = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "abc123",
            recentCommitLimit: 30
        )
        XCTAssertTrue(GitStatusModel.shouldReuseCachedGitDetails(cached: cached, current: current))
    }

    func testShouldReuseCachedGitDetailsFalseWhenHeadOIDChanges() {
        let cached = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "aaa",
            recentCommitLimit: 30
        )
        let current = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "bbb",
            recentCommitLimit: 30
        )
        XCTAssertFalse(GitStatusModel.shouldReuseCachedGitDetails(cached: cached, current: current))
    }

    func testShouldReuseCachedGitDetailsFalseWhenCachedLimitIsSmaller() {
        let cached = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "abc123",
            recentCommitLimit: 30
        )
        let current = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "abc123",
            recentCommitLimit: 60
        )
        XCTAssertFalse(GitStatusModel.shouldReuseCachedGitDetails(cached: cached, current: current))
    }

    func testShouldReuseCachedGitDetailsFalseOnNilCache() {
        let current = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo",
            headOID: "abc123",
            recentCommitLimit: 30
        )
        XCTAssertFalse(GitStatusModel.shouldReuseCachedGitDetails(cached: nil, current: current))
    }

    func testShouldReuseCachedGitDetailsFalseWhenRepositoryRootChanges() {
        let cached = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo-a",
            headOID: "abc123",
            recentCommitLimit: 30
        )
        let current = GitStatusModel.GitDetailsCacheKey(
            repositoryRoot: "/repo-b",
            headOID: "abc123",
            recentCommitLimit: 30
        )
        XCTAssertFalse(GitStatusModel.shouldReuseCachedGitDetails(cached: cached, current: current))
    }

    func testUntrackedLineCacheKeyEqualForSamePathMtimeAndSize() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = GitStatusModel.untrackedLineCacheKey(
            path: "/repo/new.txt", modificationDate: date, size: 12
        )
        let second = GitStatusModel.untrackedLineCacheKey(
            path: "/repo/new.txt", modificationDate: date, size: 12
        )
        XCTAssertEqual(first, second)
    }

    func testUntrackedLineCacheKeyUnequalWhenMtimeSizeOrPathDiffers() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_001)
        let base = GitStatusModel.untrackedLineCacheKey(
            path: "/repo/new.txt", modificationDate: date, size: 12
        )
        XCTAssertNotEqual(
            base,
            GitStatusModel.untrackedLineCacheKey(
                path: "/repo/new.txt", modificationDate: later, size: 12
            )
        )
        XCTAssertNotEqual(
            base,
            GitStatusModel.untrackedLineCacheKey(
                path: "/repo/new.txt", modificationDate: date, size: 13
            )
        )
        XCTAssertNotEqual(
            base,
            GitStatusModel.untrackedLineCacheKey(
                path: "/repo/other.txt", modificationDate: date, size: 12
            )
        )
    }

    func testParseStatusDetachedInitialAndConflict() {
        let output = [
            "# branch.oid (initial)",
            "# branch.head (detached)",
            "u UU N... 100644 100644 100644 100644 0 0 0 conflict.swift",
            "? path with space.txt",
        ].joined(separator: "\0") + "\0"

        let result = GitStatusModel.parseStatus(output)
        XCTAssertFalse(result.hasHead)
        XCTAssertNil(result.headOID)
        XCTAssertEqual(result.branch, "detached HEAD")
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries[0].isConflict)
        XCTAssertEqual(result.entries[0].path, "conflict.swift")
        XCTAssertEqual(result.entries[1].path, "path with space.txt")
        XCTAssertEqual(result.entries[1].staged, Character("?"))
    }

    func testParseRecentCommitsModifiedAndRename() {
        let modified = [
            "abc123", "abc", "fix bug", "Ada", "1700000000", "def456", "HEAD -> main",
        ].joined(separator: "\u{1f}") + "\nM\u{0}foo.swift"
        let renamed = [
            "aaa111", "aaa", "rename", "Ada", "1700000001", "abc123", "",
        ].joined(separator: "\u{1f}") + "\nR100\u{0}old.swift\u{0}new.swift"
        let commits = GitStatusModel.parseRecentCommits(modified + "\u{1e}" + renamed)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "abc123")
        XCTAssertEqual(commits[0].subject, "fix bug")
        XCTAssertEqual(commits[0].files.count, 1)
        XCTAssertEqual(commits[0].files[0].path, "foo.swift")
        XCTAssertEqual(commits[0].files[0].status, Character("M"))
        XCTAssertEqual(commits[0].parentHash, "def456")
        XCTAssertEqual(commits[0].references, ["HEAD -> main"])
        XCTAssertEqual(commits[1].files[0].status, Character("R"))
        XCTAssertEqual(commits[1].files[0].originalPath, "old.swift")
        XCTAssertEqual(commits[1].files[0].path, "new.swift")
    }

    func testDetectRepositoryOperationPrefersRebaseThenClears() throws {
        let git = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-git-op-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: git) }

        XCTAssertNil(GitStatusModel.detectRepositoryOperation(gitDirectory: git.path))

        try Data().write(to: git.appendingPathComponent("MERGE_HEAD"))
        XCTAssertNotNil(GitStatusModel.detectRepositoryOperation(gitDirectory: git.path))

        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("rebase-merge"),
            withIntermediateDirectories: true
        )
        let rebase = try XCTUnwrap(
            GitStatusModel.detectRepositoryOperation(gitDirectory: git.path)
        )
        XCTAssertTrue(rebase.localizedCaseInsensitiveContains("rebase"))
    }

    func testUntrackedLineCacheKeyNilWhenDateOrSizeMissing() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(
            GitStatusModel.untrackedLineCacheKey(
                path: "/repo/new.txt", modificationDate: nil, size: 12
            )
        )
        XCTAssertNil(
            GitStatusModel.untrackedLineCacheKey(
                path: "/repo/new.txt", modificationDate: date, size: nil
            )
        )
    }

    func testParseWorktreeListPorcelain() {
        let output = """
        worktree /repo
        HEAD abcdef
        branch refs/heads/main

        worktree /repo-yeet-tests
        HEAD fedcba
        branch refs/heads/yeet/agent/tests

        worktree /repo-detached
        HEAD 123456
        detached

        """
        let listed = KeroAgentWorktree.parseList(output)
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(listed[0].path, "/repo")
        XCTAssertEqual(listed[0].branch, "main")
        XCTAssertEqual(listed[1].path, "/repo-yeet-tests")
        XCTAssertEqual(listed[1].branch, "yeet/agent/tests")
        XCTAssertEqual(listed[2].path, "/repo-detached")
        XCTAssertTrue(listed[2].detached)
        XCTAssertNil(listed[2].branch)
        XCTAssertEqual(KeroAgentWorktree.branchName(alias: "tests"), "yeet/agent/tests")
    }

    func testWorktreePrepareAddRemoveAndAttach() throws {
        let repo = try makeTempGitRepository(prefix: "yeet-wt-add")
        defer { try? FileManager.default.removeItem(at: repo) }

        let first = try KeroAgentWorktree.prepare(alias: "iso", cwd: repo.path).get()
        defer {
            _ = KeroAgentWorktree.remove(path: first.path, in: repo.path)
            try? FileManager.default.removeItem(atPath: first.path)
        }
        XCTAssertFalse(first.attached)
        XCTAssertEqual(first.branch, "yeet/agent/iso")
        XCTAssertTrue(GitRepositoryLocator.isLinkedWorktree(first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        try "leftover\n".write(
            to: URL(fileURLWithPath: first.path).appendingPathComponent("leftover.txt"),
            atomically: true,
            encoding: .utf8
        )

        let attached = try KeroAgentWorktree.prepare(alias: "iso", cwd: repo.path).get()
        XCTAssertTrue(attached.attached)
        XCTAssertEqual(attached.path, first.path)
        XCTAssertEqual(attached.branch, first.branch)
        let leftover = try String(
            contentsOfFile: (attached.path as NSString).appendingPathComponent("leftover.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(leftover, "leftover\n")

        try KeroAgentWorktree.remove(path: first.path, in: repo.path).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let listed = KeroAgentWorktree.parseList(
            GitStatusModel.runGit(["worktree", "list", "--porcelain"], in: repo.path).stdout
        )
        XCTAssertFalse(listed.contains { $0.path == first.path })
    }

    func testWorktreePrepareKeepsSourceDirtInTheOriginalCheckout() throws {
        let repo = try makeTempGitRepository(prefix: "yeet-wt-dirty")
        defer { try? FileManager.default.removeItem(at: repo) }
        try "dirty-main\n".write(
            to: repo.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "only-main\n".write(
            to: repo.appendingPathComponent("main-only.txt"),
            atomically: true,
            encoding: .utf8
        )

        let checkout = try KeroAgentWorktree.prepare(alias: "dirty", cwd: repo.path).get()
        defer {
            _ = KeroAgentWorktree.remove(path: checkout.path, in: repo.path)
            try? FileManager.default.removeItem(atPath: checkout.path)
        }

        let worktreeReadme = try String(
            contentsOfFile: (checkout.path as NSString).appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertEqual(worktreeReadme, "init\n")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (checkout.path as NSString).appendingPathComponent("main-only.txt")
            )
        )
        try "only-worktree\n".write(
            to: URL(fileURLWithPath: checkout.path).appendingPathComponent("worktree-only.txt"),
            atomically: true,
            encoding: .utf8
        )

        let mainStatus = GitStatusModel.parseStatus(
            GitStatusModel.runGit(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
                in: repo.path
            ).stdout
        )
        let worktreeStatus = GitStatusModel.parseStatus(
            GitStatusModel.runGit(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
                in: checkout.path
            ).stdout
        )
        XCTAssertTrue(mainStatus.entries.contains { $0.path == "main-only.txt" })
        XCTAssertTrue(mainStatus.entries.contains { $0.path == "README.md" })
        XCTAssertFalse(mainStatus.entries.contains { $0.path == "worktree-only.txt" })
        XCTAssertTrue(worktreeStatus.entries.contains { $0.path == "worktree-only.txt" })
        XCTAssertFalse(worktreeStatus.entries.contains { $0.path == "main-only.txt" })
    }

    func testWorktreePrepareFailsWithoutGitOrRepository() throws {
        let missingGit = KeroAgentWorktree.prepare(
            alias: "iso",
            cwd: "/tmp",
            gitExecutable: "/no/such/yeet-git-\(UUID().uuidString)"
        )
        switch missingGit {
        case .success: XCTFail("missing git must fail")
        case .failure(let error):
            XCTAssertEqual(error, .gitMissing)
            XCTAssertEqual(error.code, "git_not_found")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-wt-nongit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        switch KeroAgentWorktree.prepare(alias: "iso", cwd: directory.path) {
        case .success: XCTFail("plain directory must fail")
        case .failure(let error):
            XCTAssertEqual(error, .notRepository)
            XCTAssertEqual(error.code, "not_a_git_repository")
        }

        switch KeroAgentWorktree.prepare(alias: "..", cwd: directory.path) {
        case .success: XCTFail("invalid branch alias must fail")
        case .failure(let error):
            XCTAssertEqual(error, .invalidBranch)
            XCTAssertEqual(error.code, "invalid_params")
        }
    }

    func testWorktreePrepareDoesNotClobberAnExistingPath() throws {
        let repo = try makeTempGitRepository(prefix: "yeet-wt-exists")
        defer { try? FileManager.default.removeItem(at: repo) }
        let toplevel = GitStatusModel.runGit(["rev-parse", "--show-toplevel"], in: repo.path)
        XCTAssertEqual(toplevel.status, 0, toplevel.stderr)
        let root = toplevel.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = KeroAgentWorktree.intendedPath(toplevel: root, alias: "taken")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }

        switch KeroAgentWorktree.prepare(alias: "taken", cwd: repo.path) {
        case .success: XCTFail("existing path must fail")
        case .failure(let error):
            XCTAssertEqual(error.code, "worktree_failed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let listed = KeroAgentWorktree.parseList(
            GitStatusModel.runGit(["worktree", "list", "--porcelain"], in: repo.path).stdout
        )
        XCTAssertFalse(listed.contains { $0.branch == "yeet/agent/taken" })
    }
}

private extension GitPorcelainTests {
    func makeTempGitRepository(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initGit = GitStatusModel.runGit(["init", "-b", "main"], in: directory.path)
        guard initGit.status == 0 else {
            throw NSError(
                domain: "GitPorcelainTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: initGit.stderr]
            )
        }
        try "init\n".write(
            to: directory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        let add = GitStatusModel.runGit(["add", "README.md"], in: directory.path)
        XCTAssertEqual(add.status, 0, add.stderr)
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
