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
}
