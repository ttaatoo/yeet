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

    func testParseStatusCopyUsesFollowingToken() {
        let output = [
            "2 C. N... 100644 100644 100644 0000000 0000000 C100 copied.txt",
            "source.txt",
        ].joined(separator: "\0") + "\0"

        let result = GitStatusModel.parseStatus(output)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].path, "copied.txt")
        XCTAssertEqual(result.entries[0].origPath, "source.txt")
        XCTAssertEqual(result.entries[0].staged, Character("C"))
        XCTAssertEqual(result.entries[0].unstaged, Character("."))
    }

    func testParseStatusKeepsIgnoredDirectorySlash() {
        let output = [
            "! build/",
            "! secret.bin",
        ].joined(separator: "\0") + "\0"

        let result = GitStatusModel.parseStatus(output)
        XCTAssertTrue(result.ignoredPaths.contains("build/"))
        XCTAssertTrue(result.ignoredPaths.contains("secret.bin"))
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(GitStatusModel.dirtyFileCount(from: result), 0)
    }

    func testParseStatusStagedOnlyAndUnstagedOnly() {
        let output = [
            "1 M. N... 100644 100644 100644 0000000 0000000 staged.swift",
            "1 .M N... 100644 100644 100644 0000000 0000000 unstaged.swift",
            "1 A. N... 100644 100644 100644 0000000 0000000 added.swift",
            "1 .D N... 100644 100644 100644 0000000 0000000 deleted.swift",
        ].joined(separator: "\0") + "\0"

        let result = GitStatusModel.parseStatus(output)
        XCTAssertEqual(result.entries.map(\.path), [
            "staged.swift", "unstaged.swift", "added.swift", "deleted.swift",
        ])
        XCTAssertEqual(result.entries[0].staged, Character("M"))
        XCTAssertEqual(result.entries[0].unstaged, Character("."))
        XCTAssertEqual(result.entries[1].staged, Character("."))
        XCTAssertEqual(result.entries[1].unstaged, Character("M"))
        XCTAssertEqual(result.entries[2].staged, Character("A"))
        XCTAssertEqual(result.entries[3].unstaged, Character("D"))
    }

    func testEntryRowIDsStayDistinctForTheSamePath() {
        let entry = GitStatusModel.Entry(
            path: "src/file.swift", staged: "M", unstaged: "M"
        )
        XCTAssertEqual(entry.id, "src/file.swift")
        XCTAssertEqual(entry.mergeRowID, "merge/src/file.swift")
        XCTAssertEqual(entry.stagedRowID, "staged/src/file.swift")
        XCTAssertEqual(entry.changedRowID, "changed/src/file.swift")
        XCTAssertNotEqual(entry.stagedRowID, entry.changedRowID)
        XCTAssertNotEqual(entry.mergeRowID, entry.stagedRowID)
    }

    func testEntryClassifiesIntentToAddUntrackedAndWorktreeRename() {
        let intent = GitStatusModel.Entry(path: "new.txt", staged: ".", unstaged: "A")
        XCTAssertTrue(intent.isIntentToAdd)
        XCTAssertTrue(intent.isUntracked)

        let untracked = GitStatusModel.Entry(path: "new.txt", staged: "?", unstaged: "?")
        XCTAssertTrue(untracked.isUntracked)
        XCTAssertFalse(untracked.isIntentToAdd)

        var rename = GitStatusModel.Entry(path: "new.swift", staged: ".", unstaged: "R")
        rename.origPath = "old.swift"
        XCTAssertTrue(rename.isWorktreeRename)
        XCTAssertFalse(rename.isWorktreeCopy)

        var copy = GitStatusModel.Entry(path: "copy.swift", staged: ".", unstaged: "C")
        copy.origPath = "source.swift"
        XCTAssertTrue(copy.isWorktreeCopy)
        XCTAssertFalse(copy.isWorktreeRename)
    }

    func testEntrySplitsFileNameAndDirectory() {
        let nested = GitStatusModel.Entry(path: "src/app/main.swift", staged: "M", unstaged: ".")
        XCTAssertEqual(nested.fileName, "main.swift")
        XCTAssertEqual(nested.directory, "src/app")

        let rootFile = GitStatusModel.Entry(path: "README.md", staged: "?", unstaged: "?")
        XCTAssertEqual(rootFile.fileName, "README.md")
        XCTAssertEqual(rootFile.directory, "")
    }

    func testParseNumstatEmptyAndMissingColumns() {
        XCTAssertEqual(GitStatusModel.parseNumstat("").additions, 0)
        XCTAssertEqual(GitStatusModel.parseNumstat("").deletions, 0)
        XCTAssertEqual(GitStatusModel.parseNumstat("not-a-numstat-row\n").additions, 0)
    }

    func testParseRecentCommitsCopyAndEmptyFiles() {
        let copied = [
            "ccc222", "ccc", "copy file", "Ada", "1700000002", "aaa111", "tag: v1",
        ].joined(separator: "\u{1f}") + "\nC100\u{0}from.swift\u{0}to.swift"
        let empty = [
            "ddd333", "ddd", "empty", "Ada", "1700000003", "ccc222", "",
        ].joined(separator: "\u{1f}")
        let commits = GitStatusModel.parseRecentCommits(copied + "\u{1e}" + empty)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].files[0].status, Character("C"))
        XCTAssertEqual(commits[0].files[0].originalPath, "from.swift")
        XCTAssertEqual(commits[0].files[0].path, "to.swift")
        XCTAssertEqual(commits[0].references, ["tag: v1"])
        XCTAssertTrue(commits[1].files.isEmpty)
    }

    func testCommitFileChangeIdentityIncludesRenameSides() {
        let renamed = GitStatusModel.RecentCommit.FileChange(
            status: "R", path: "new.swift", originalPath: "old.swift"
        )
        let modified = GitStatusModel.RecentCommit.FileChange(
            status: "M", path: "new.swift", originalPath: nil
        )
        XCTAssertNotEqual(renamed.id, modified.id)
        XCTAssertEqual(renamed.fileName, "new.swift")
        XCTAssertEqual(renamed.directory, "")
    }

    func testDirectoryDecorationRollupWalksNestedAncestors() {
        let decorations: [String: GitStatusModel.FileDecoration] = [
            "src/app/view.swift": .modified,
            "src/app/conflict.swift": .conflict,
        ]
        let dirs = GitStatusModel.rolledUpDirectoryDecorations(decorations)
        XCTAssertEqual(dirs["src/app"], .conflict)
        XCTAssertEqual(dirs["src"], .conflict)
        XCTAssertNil(dirs[""])
    }

    func testDirectoryPriorityOrdersConflictAboveModified() {
        XCTAssertGreaterThan(
            GitStatusModel.FileDecoration.conflict.directoryPriority,
            GitStatusModel.FileDecoration.deleted.directoryPriority
        )
        XCTAssertGreaterThan(
            GitStatusModel.FileDecoration.deleted.directoryPriority,
            GitStatusModel.FileDecoration.modified.directoryPriority
        )
        XCTAssertGreaterThan(
            GitStatusModel.FileDecoration.untracked.directoryPriority,
            GitStatusModel.FileDecoration.ignored.directoryPriority
        )
    }
}
