//
//  ChatProviderProbeTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class ChatProviderProbeTests: XCTestCase {
    func testResolveFindsExecutableOnInjectedPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        FileManager.default.createFile(
            atPath: fake.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        let found = ChatProviderProbe.resolveExecutable(named: "codex", path: dir.path)
        XCTAssertEqual(found, fake.path)
    }

    func testResolveSkipsNonExecutableFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        FileManager.default.createFile(
            atPath: fake.path,
            contents: Data("not executable\n".utf8),
            attributes: [.posixPermissions: 0o644]
        )
        XCTAssertNil(ChatProviderProbe.resolveExecutable(named: "codex", path: dir.path))
    }

    func testResolvePrefersTheFirstPathEntry() throws {
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-probe-a-\(UUID().uuidString)", isDirectory: true)
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-probe-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let firstCodex = first.appendingPathComponent("codex")
        let secondCodex = second.appendingPathComponent("codex")
        FileManager.default.createFile(
            atPath: firstCodex.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        FileManager.default.createFile(
            atPath: secondCodex.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        let found = ChatProviderProbe.resolveExecutable(
            named: "codex",
            path: "\(first.path):\(second.path)"
        )
        XCTAssertEqual(found, firstCodex.path)
    }

    func testProbeAlwaysListsClaudeCodexAndGrok() {
        let rows = ChatProviderProbe.probe(path: "/no/such/bin")
        XCTAssertEqual(
            rows.filter(\.isSupported).map(\.executableName),
            ["claude", "codex", "grok"]
        )
        XCTAssertTrue(rows.allSatisfy { $0.resolvedPath == nil })
        XCTAssertFalse(rows.contains { $0.executableName == "opencode" })
    }

    func testProbeMarksInstalledCLIsSupported() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["codex", "claude", "grok", "opencode"] {
            let fake = dir.appendingPathComponent(name)
            FileManager.default.createFile(
                atPath: fake.path,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: 0o755]
            )
        }
        let rows = ChatProviderProbe.probe(path: dir.path)
        XCTAssertEqual(rows.first { $0.executableName == "codex" }?.isSupported, true)
        XCTAssertEqual(rows.first { $0.executableName == "claude" }?.isSupported, true)
        XCTAssertEqual(rows.first { $0.executableName == "grok" }?.isSupported, true)
        XCTAssertEqual(
            rows.first { $0.executableName == "opencode" }?.isSupported,
            false
        )
    }
}
