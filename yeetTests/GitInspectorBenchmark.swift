//
//  GitInspectorBenchmark.swift
//  yeetTests
//
//  Timing harness for the Git inspector data path. Parser and AppKit row
//  rebuilds always run. The 133-file live snapshot matches the large Git
//  panel case and runs when tmp/git-inspector-bench.request is present.

import Foundation
import XCTest
@testable import yeet

struct GitInspectorBenchSample: Codable, Equatable {
    var name: String
    var iterations: Int
    var medianMs: Double
    var p95Ms: Double
    var maxMs: Double
}

struct GitInspectorBenchReport: Codable {
    var schemaVersion: Int
    var generatedAt: String
    var samples: [GitInspectorBenchSample]
}

enum GitInspectorBenchmark {
    static let schemaVersion = 1
    static let liveStagedCount = 133
    static let liveUnstagedCount = 3
    static let liveCommitCount = 60

    /// `scripts/bench-git-inspector.sh` writes the JSON path here. xcodebuild
    /// does not forward arbitrary environment variables into XCTest.
    static var requestFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tmp/git-inspector-bench.request")
    }

    static func requestedOutputURL() -> URL? {
        guard let raw = try? String(contentsOf: requestFileURL, encoding: .utf8)
        else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static let ceilingsMs: [String: Double] = [
        "parse-status-500": 250,
        "parse-commits-60x10": 250,
        "rollup-directories-500": 150,
        "recent-commits-collapsed-60": 200,
        "recent-commits-expanded-133": 400,
        "file-tree-snapshot-80": 750,
        "live-status-133-staged": 20_000,
    ]

    static func measure(
        name: String,
        iterations: Int,
        warmup: Int = 1,
        body: () throws -> Void
    ) rethrows -> GitInspectorBenchSample {
        for _ in 0..<warmup { try body() }
        var times: [Double] = []
        times.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            try body()
            let elapsed = start.duration(to: ContinuousClock.now)
            times.append(Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000)
        }
        let sorted = times.sorted()
        return GitInspectorBenchSample(
            name: name,
            iterations: iterations,
            medianMs: percentile(sorted, 0.50),
            p95Ms: percentile(sorted, 0.95),
            maxMs: sorted.last ?? 0
        )
    }

    static func measureAsync(
        name: String,
        iterations: Int,
        warmup: Int = 1,
        body: () async throws -> Void
    ) async rethrows -> GitInspectorBenchSample {
        for _ in 0..<warmup { try await body() }
        var times: [Double] = []
        times.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            try await body()
            let elapsed = start.duration(to: ContinuousClock.now)
            times.append(Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000)
        }
        let sorted = times.sorted()
        return GitInspectorBenchSample(
            name: name,
            iterations: iterations,
            medianMs: percentile(sorted, 0.50),
            p95Ms: percentile(sorted, 0.95),
            maxMs: sorted.last ?? 0
        )
    }

    static func runParserSamples() throws -> [GitInspectorBenchSample] {
        let porcelain = GitInspectorFixtures.porcelainStatus(fileCount: 500)
        let decorations = Dictionary(
            uniqueKeysWithValues: (0..<500).map { index in
                ("src/file-\(index).swift", GitStatusModel.FileDecoration.modified)
            }
        )
        let log = GitInspectorFixtures.recentCommitLog(commitCount: 60, filesPerCommit: 10)
        return [
            try measure(name: "parse-status-500", iterations: 8) {
                let result = GitStatusModel.parseStatus(porcelain)
                precondition(result.entries.count == 500)
            },
            try measure(name: "parse-commits-60x10", iterations: 8) {
                let commits = GitStatusModel.parseRecentCommits(log)
                precondition(commits.count == 60)
                precondition(commits[0].files.count == 10)
            },
            try measure(name: "rollup-directories-500", iterations: 8) {
                let dirs = GitStatusModel.rolledUpDirectoryDecorations(decorations)
                precondition(dirs["src"] == .modified)
            },
        ]
    }

    @MainActor
    static func runViewSamples() throws -> [GitInspectorBenchSample] {
        let collapsed = GitInspectorFixtures.recentCommits(
            count: 60, filesInFirst: 0, filesInOthers: 1
        )
        let expanded = GitInspectorFixtures.recentCommits(
            count: 8, filesInFirst: 133, filesInOthers: 1
        )
        let treeRoot = try GitInspectorFixtures.makeTempDirectory(prefix: "yeet-git-bench-tree")
        defer { try? FileManager.default.removeItem(at: treeRoot) }
        for index in 0..<80 {
            let file = treeRoot.appendingPathComponent("file-\(index).txt")
            try "body \(index)\n".write(to: file, atomically: true, encoding: .utf8)
        }

        return [
            try measure(name: "recent-commits-collapsed-60", iterations: 5) {
                // A new view each pass so Equatable snapshot short-circuit
                // cannot hide the rebuild cost a Git refresh pays.
                let view = RecentCommitsNSView()
                view.configure(
                    commits: collapsed,
                    expandedCommitIDs: [],
                    fontScale: 1,
                    hasMoreCommits: true,
                    isLoadingMore: false
                )
                precondition(view.requiredHeight > 0)
            },
            try measure(name: "recent-commits-expanded-133", iterations: 5) {
                let view = RecentCommitsNSView()
                view.configure(
                    commits: expanded,
                    expandedCommitIDs: [expanded[0].id],
                    fontScale: 1,
                    hasMoreCommits: false,
                    isLoadingMore: false
                )
                precondition(view.requiredHeight > 0)
            },
            try measure(name: "file-tree-snapshot-80", iterations: 5) {
                let items = FileTreeModel.snapshot(
                    root: treeRoot.path, expanded: [], draft: nil
                )
                precondition(items.filter { $0.name.hasPrefix("file-") }.count == 80)
            },
        ]
    }

    @MainActor
    static func runLiveSnapshot() async throws -> GitInspectorBenchSample {
        let repo = try makeLiveLoadRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        return try await measureAsync(
            name: "live-status-133-staged",
            iterations: 3,
            warmup: 1
        ) {
            let git = GitStatusModel()
            git.sync(root: repo.path)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if git.hasResolvedStatus && !git.isRefreshing && !git.isBusy {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            precondition(git.isRepo)
            precondition(git.stagedEntries.count == liveStagedCount)
            precondition(git.changedEntries.count == liveUnstagedCount)
            precondition(git.recentCommits.count == 30)
            precondition(git.hasMoreRecentCommits)
        }
    }

    static func write(_ samples: [GitInspectorBenchSample], to url: URL) throws {
        let report = GitInspectorBenchReport(
            schemaVersion: schemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            samples: samples
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    static func assertCeilings(
        _ samples: [GitInspectorBenchSample],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for sample in samples {
            guard let ceiling = ceilingsMs[sample.name] else { continue }
            XCTAssertLessThanOrEqual(
                sample.medianMs,
                ceiling,
                "\(sample.name) median \(sample.medianMs)ms exceeded \(ceiling)ms",
                file: file,
                line: line
            )
        }
    }

    static func makeLiveLoadRepository() throws -> GitInspectorRepo {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-git-bench-live",
            files: ["README.md": "seed\n"]
        )
        for index in 0..<liveStagedCount {
            try repo.write(
                String(format: "src/file-%03d.swift", index),
                "let value = \(index)\n"
            )
        }
        try repo.git(["add", "src"])
        try repo.git(["commit", "-m", "add \(liveStagedCount) files"])
        let extraCommits = liveCommitCount - 2
        if extraCommits > 0 {
            for index in 1...extraCommits {
                try repo.git(["commit", "--allow-empty", "-m", "history \(index)"])
            }
        }
        for index in 0..<liveStagedCount {
            try repo.write(
                String(format: "src/file-%03d.swift", index),
                "let value = \(index + 1)\n"
            )
        }
        try repo.git(["add", "src"])
        for index in 0..<liveUnstagedCount {
            try repo.write("unstaged-\(index).txt", "raw \(index)\n")
        }
        return repo
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}
