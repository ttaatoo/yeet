//
//  GitInspectorBenchTests.swift
//  yeetTests
//
//  Always records parser / row-rebuild timings with a loose ceiling so a
//  later rewrite cannot silently go quadratic. The 133-file live snapshot
//  and JSON report run when scripts/bench-git-inspector.sh leaves a
//  tmp/git-inspector-bench.request file.

import XCTest
@testable import yeet

@MainActor
final class GitInspectorBenchTests: XCTestCase {
    func testParserAndViewBenchesStayUnderCeiling() async throws {
        var samples = try GitInspectorBenchmark.runParserSamples()
        samples += try GitInspectorBenchmark.runViewSamples()
        GitInspectorBenchmark.assertCeilings(samples)

        if let out = GitInspectorBenchmark.requestedOutputURL() {
            let live = try await GitInspectorBenchmark.runLiveSnapshot()
            samples.append(live)
            GitInspectorBenchmark.assertCeilings([live])
            try GitInspectorBenchmark.write(samples, to: out)
        }
    }

    func testBenchmarkJSONRoundTrip() throws {
        let samples = try GitInspectorBenchmark.runParserSamples()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-git-bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try GitInspectorBenchmark.write(samples, to: url)

        let data = try Data(contentsOf: url)
        let report = try JSONDecoder().decode(GitInspectorBenchReport.self, from: data)
        XCTAssertEqual(report.schemaVersion, GitInspectorBenchmark.schemaVersion)
        XCTAssertEqual(report.samples.map(\.name), samples.map(\.name))
        XCTAssertFalse(report.generatedAt.isEmpty)
        XCTAssertEqual(report.samples.first?.iterations, 8)
    }
}
