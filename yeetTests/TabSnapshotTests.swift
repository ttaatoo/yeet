//
//  TabSnapshotTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class TabSnapshotTests: XCTestCase {
    private typealias TabSnapshot = SessionSnapshot.ProjectSnapshot.TabSnapshot
    private typealias PaneContentSnapshot = SessionSnapshot.ProjectSnapshot.PaneContentSnapshot

    func testLegacySessionPayloadWithoutAgentFieldsDecodes() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["workingDirectory": "/tmp/legacy"]
        )
        let content = try JSONDecoder().decode(PaneContentSnapshot.self, from: data)
        guard case .session(let directory, let agentKind, let agentSessionID) = content
        else { return XCTFail("expected a session pane") }
        XCTAssertEqual(directory, "/tmp/legacy")
        XCTAssertNil(agentKind)
        XCTAssertNil(agentSessionID)
    }

    func testSessionAgentIdentityRoundTrips() throws {
        let content = PaneContentSnapshot.session(
            workingDirectory: "/tmp/repo",
            agentKind: "codex",
            agentSessionID: "550e8400-e29b-41d4-a716-446655440000"
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PaneContentSnapshot.self, from: data)
        guard case .session(let directory, let agentKind, let agentSessionID) = decoded
        else { return XCTFail("expected a session pane") }
        XCTAssertEqual(directory, "/tmp/repo")
        XCTAssertEqual(agentKind, "codex")
        XCTAssertEqual(agentSessionID, "550e8400-e29b-41d4-a716-446655440000")
    }

    func testResumeArgumentsPerKind() {
        XCTAssertEqual(
            KeroAgentKind.claude.resumeArguments(sessionID: "s1"), ["--resume", "s1"]
        )
        XCTAssertEqual(
            KeroAgentKind.codex.resumeArguments(sessionID: "s1"), ["resume", "s1"]
        )
        XCTAssertEqual(
            KeroAgentKind.grok.resumeArguments(sessionID: "s1"), ["-r", "s1"]
        )
        XCTAssertEqual(
            KeroAgentKind.opencode.resumeArguments(sessionID: "s1"), ["--session", "s1"]
        )
        XCTAssertEqual(
            KeroAgentKind.gemini.resumeArguments(sessionID: "s1"), ["--resume", "s1"]
        )
        XCTAssertNil(KeroAgentKind.pi.resumeArguments(sessionID: "s1"))
        XCTAssertNil(KeroAgentKind.aider.resumeArguments(sessionID: "s1"))
        XCTAssertNil(KeroAgentKind.amp.resumeArguments(sessionID: "s1"))
        XCTAssertNil(KeroAgentKind.cursor.resumeArguments(sessionID: "s1"))
    }

    // MARK: - Merged hook integrations

    private func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true
        )
        return home
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testMergedHooksInstallPreservesForeignEntriesAndUninstallStrips() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true
        )
        let settings = claudeDir.appendingPathComponent("settings.json")
        let foreign: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "echo foreign"]]]
                ]
            ],
        ]
        try JSONSerialization.data(withJSONObject: foreign).write(to: settings)

        try KeroAgentIntegrations.installAvailable(
            bundle: .main, homeURL: home, environment: [:]
        )

        let installed = try jsonObject(at: settings)
        XCTAssertEqual(installed["model"] as? String, "opus")
        let hooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        let yeetGroup = try XCTUnwrap(stop.first { ($0["_yeet"] as? Bool) == true })
        let yeetHooks = try XCTUnwrap(yeetGroup["hooks"] as? [[String: Any]])
        XCTAssertTrue(
            try XCTUnwrap(yeetHooks.first?["command"] as? String)
                .contains("_integration claude idle")
        )
        let submit = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(submit.count, 1)

        // Reinstall replaces Yeet's own groups instead of stacking them.
        try KeroAgentIntegrations.installAvailable(
            bundle: .main, homeURL: home, environment: [:]
        )
        let reinstalled = try jsonObject(at: settings)
        XCTAssertEqual(
            (try XCTUnwrap(reinstalled["hooks"] as? [String: Any])["Stop"] as? [Any])?
                .count, 2
        )

        try KeroAgentIntegrations.uninstallManaged(homeURL: home, environment: [:])

        let uninstalled = try jsonObject(at: settings)
        XCTAssertEqual(uninstalled["model"] as? String, "opus")
        let remainingHooks = try XCTUnwrap(uninstalled["hooks"] as? [String: Any])
        XCTAssertEqual((remainingHooks["Stop"] as? [Any])?.count, 1)
        XCTAssertNil(remainingHooks["UserPromptSubmit"])
        let survivor = try XCTUnwrap(
            (remainingHooks["Stop"] as? [[String: Any]])?.first
        )
        XCTAssertNil(survivor["_yeet"])
    }

    func testMergedHooksUninstallRemovesFileYeetCreated() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDir, withIntermediateDirectories: true
        )
        let hooksFile = codexDir.appendingPathComponent("hooks.json")

        try KeroAgentIntegrations.installAvailable(
            bundle: .main, homeURL: home, environment: [:]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksFile.path))

        try KeroAgentIntegrations.uninstallManaged(homeURL: home, environment: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksFile.path))
    }

    func testMergedHooksRefuseMalformedJSON() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true
        )
        let settings = claudeDir.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: settings)

        XCTAssertThrowsError(
            try KeroAgentIntegrations.installAvailable(
                bundle: .main, homeURL: home, environment: [:]
            )
        )
        XCTAssertEqual(
            String(data: try Data(contentsOf: settings), encoding: .utf8), "not json"
        )
    }
}
