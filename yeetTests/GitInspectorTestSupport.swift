//
//  GitInspectorTestSupport.swift
//  yeetTests
//
//  Shared fixtures for Git inspector characterization tests. Perf work on
//  the panel must keep these helpers; they build isolated repositories so
//  parallel XCTest runs cannot share a worktree.

import Foundation
import XCTest
@testable import yeet

struct GitInspectorTimedOut: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct GitCommandFailed: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let stderr: String
    var description: String {
        "git \(command) exited \(status): \(stderr)"
    }
}

struct GitInspectorRepo {
    let root: URL

    var path: String { root.path }

    func url(_ relative: String) -> URL {
        relative.split(separator: "/").reduce(root) { partial, part in
            partial.appendingPathComponent(String(part))
        }
    }

    func write(_ relative: String, _ contents: String) throws {
        let file = url(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func writeData(_ relative: String, _ data: Data) throws {
        let file = url(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)
    }

    @discardableResult
    func git(_ args: [String]) throws -> (stdout: String, stderr: String) {
        let result = GitStatusModel.runGit(args, in: path)
        guard result.status == 0 else {
            throw GitCommandFailed(
                command: args.joined(separator: " "),
                status: result.status,
                stderr: result.stderr
            )
        }
        return (result.stdout, result.stderr)
    }

    @discardableResult
    func gitAllowingFailure(_ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        GitStatusModel.runGit(args, in: path)
    }
}

enum GitInspectorFixtures {
    static func makeTempDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Empty git repository on `main` with a local identity so commits do not
    /// pick up the machine's signing or user config.
    static func makeRepository(
        prefix: String = "yeet-git",
        files: [String: String] = ["README.md": "hello\n"],
        commitMessage: String? = "initial"
    ) throws -> GitInspectorRepo {
        let root = try makeTempDirectory(prefix: prefix)
        let repo = GitInspectorRepo(root: root)
        try repo.git(["init", "-b", "main"])
        try repo.git(["config", "user.name", "Yeet Test"])
        try repo.git(["config", "user.email", "yeet.test@example.com"])
        try repo.git(["config", "commit.gpgsign", "false"])
        try repo.git(["config", "core.autocrlf", "false"])
        for (relative, contents) in files {
            try repo.write(relative, contents)
        }
        if let commitMessage {
            if !files.isEmpty {
                try repo.git(["add", "-A"])
            }
            try repo.git(["commit", "--allow-empty", "-m", commitMessage])
        }
        return repo
    }

    /// Synthetic porcelain v2 for parser and decoration benches. Paths stay
    /// ASCII so the fixture does not mix encoding cost into the measurement.
    static func porcelainStatus(
        fileCount: Int,
        prefix: String = "src"
    ) -> String {
        var records = [
            "# branch.oid abcdef1234567890",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +0 -0",
        ]
        records.reserveCapacity(fileCount + 8)
        for index in 0..<fileCount {
            let path = "\(prefix)/file-\(index).swift"
            records.append("1 MM N... 100644 100644 100644 0000000 0000000 \(path)")
        }
        return records.joined(separator: "\0") + "\0"
    }

    static func recentCommitLog(
        commitCount: Int,
        filesPerCommit: Int
    ) -> String {
        (0..<commitCount).map { commitIndex in
            let header = [
                String(repeating: "a", count: 40 - 2) + String(format: "%02d", commitIndex),
                String(format: "c%02d", commitIndex),
                "commit \(commitIndex)",
                "Ada",
                "1700000\(String(format: "%03d", commitIndex))",
                String(repeating: "b", count: 40),
                commitIndex == 0 ? "HEAD -> main" : "",
            ].joined(separator: "\u{1f}")
            let files = (0..<filesPerCommit).map { fileIndex in
                "M\u{0}\(String(format: "src/%02d-%03d.swift", commitIndex, fileIndex))"
            }.joined(separator: "\u{0}")
            return header + "\n" + files
        }.joined(separator: "\u{1e}")
    }

    static func recentCommits(
        count: Int,
        filesInFirst: Int = 0,
        filesInOthers: Int = 1
    ) -> [GitStatusModel.RecentCommit] {
        (0..<count).map { index in
            let fileCount = index == 0 ? filesInFirst : filesInOthers
            let files = (0..<fileCount).map { fileIndex in
                GitStatusModel.RecentCommit.FileChange(
                    status: "M",
                    path: String(format: "src/%02d-%03d.swift", index, fileIndex),
                    originalPath: nil
                )
            }
            return GitStatusModel.RecentCommit(
                hash: String(repeating: "a", count: 38) + String(format: "%02d", index),
                shortHash: String(format: "c%02d", index),
                subject: "commit \(index)",
                author: "Ada",
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                parentHash: index == 0 ? nil : String(repeating: "b", count: 40),
                references: index == 0 ? ["HEAD -> main"] : [],
                files: files
            )
        }
    }
}

extension XCTestCase {
    /// Polls `sample` until `predicate` holds. Throws on timeout so a hung
    /// Git refresh cannot be mistaken for an assertion against stale state.
    @MainActor
    func waitUntil<T>(
        timeout: TimeInterval = 8,
        description: String,
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
        throw GitInspectorTimedOut(
            message: "timed out waiting for \(description); last value: \(String(describing: last))"
        )
    }

    @MainActor
    @discardableResult
    func waitForGitStatus(
        _ git: GitStatusModel,
        timeout: TimeInterval = 8
    ) async throws -> GitStatusModel {
        _ = try await waitUntil(timeout: timeout, description: "git status to resolve") {
            git.hasResolvedStatus && !git.isRefreshing && !git.isBusy
        } satisfies: { $0 }
        return git
    }

    @MainActor
    func loadGit(_ git: GitStatusModel, root: String, timeout: TimeInterval = 8) async throws {
        git.sync(root: root)
        _ = try await waitForGitStatus(git, timeout: timeout)
    }
}
