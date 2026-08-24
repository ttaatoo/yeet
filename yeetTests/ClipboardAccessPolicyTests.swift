//
//  ClipboardAccessPolicyTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class ClipboardAccessPolicyTests: XCTestCase {
    func testRawValuesMatchGhosttyKeys() {
        XCTAssertEqual(ClipboardAccessPolicy.ask.rawValue, "ask")
        XCTAssertEqual(ClipboardAccessPolicy.allow.rawValue, "allow")
        XCTAssertEqual(ClipboardAccessPolicy.deny.rawValue, "deny")
        XCTAssertNil(ClipboardAccessPolicy(rawValue: "prompt"))
        XCTAssertNil(ClipboardAccessPolicy(rawValue: ""))
    }

    func testTOMLKeysParse() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-clipboard-policy.toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        clipboard-write = "deny"
        clipboard-read = "allow"
        """.write(to: url, atomically: true, encoding: .utf8)

        let toml = try XCTUnwrap(TOML.parse(at: url))
        XCTAssertEqual(
            ClipboardAccessPolicy(rawValue: toml["clipboard-write"]?.string ?? ""),
            .deny
        )
        XCTAssertEqual(
            ClipboardAccessPolicy(rawValue: toml["clipboard-read"]?.string ?? ""),
            .allow
        )
    }

    @MainActor
    func testAllowApprovesAndDenyRejectsWithoutAsking() {
        var writeResult: Bool?
        let write = TerminalClipboardRequest(contents: "copied") { writeResult = $0 }
        XCTAssertFalse(ClipboardAccessPolicy.allow.needsConfirmation(for: write))
        XCTAssertEqual(writeResult, true)

        var readResult: Bool?
        let read = TerminalClipboardRequest(contents: "secret") { readResult = $0 }
        XCTAssertFalse(ClipboardAccessPolicy.deny.needsConfirmation(for: read))
        XCTAssertEqual(readResult, false)
    }

    @MainActor
    func testAskLeavesTheRequestUnresolved() {
        var result: Bool?
        let request = TerminalClipboardRequest(contents: "pending") { result = $0 }
        XCTAssertTrue(ClipboardAccessPolicy.ask.needsConfirmation(for: request))
        XCTAssertNil(result)
        request.deny()
        XCTAssertEqual(result, false)
    }
}
