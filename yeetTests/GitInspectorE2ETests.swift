//
//  GitInspectorE2ETests.swift
//  yeetTests
//

import XCTest
@testable import yeet

/// Live Git inspector paths that unit fixtures cannot reach.
@MainActor
final class GitInspectorE2ETests: XCTestCase {
    func testDiscardDoesNotCrashOnCanonicallyEquivalentPaths() async throws {
        let directory = try makeTempDirectory(prefix: "yeet-git-discard-unicode")
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
        git.sync(root: directory.path)
        _ = try await waitUntil(timeout: 8) {
            git.hasResolvedStatus && !git.isRefreshing && !git.isBusy
        } satisfies: { $0 }

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
        _ = try await waitUntil(timeout: 8) {
            git.hasResolvedStatus && !git.isRefreshing && !git.isBusy
        } satisfies: { $0 }
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
        _ = try await waitUntil(timeout: 8) {
            git.hasResolvedStatus && !git.isRefreshing && !git.isBusy
        } satisfies: { $0 }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("gone.txt").path
            )
        )
        XCTAssertFalse(git.changedEntries.contains { $0.path == "gone.txt" })
    }
}

private extension GitInspectorE2ETests {
    func makeTempDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func waitUntil<T>(
        timeout: TimeInterval,
        _ sample: @MainActor () -> T,
        satisfies predicate: (T) -> Bool
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var last = sample()
        while Date() < deadline {
            if predicate(last) { return last }
            try await Task.sleep(for: .milliseconds(50))
            last = sample()
        }
        return last
    }
}
