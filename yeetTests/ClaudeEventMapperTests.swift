//
//  ClaudeEventMapperTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class ClaudeEventMapperTests: XCTestCase {
    func testInitCapturesSessionID() {
        var mapper = ClaudeEventMapper()
        _ = mapper.push(.object([
            "type": .string("system"),
            "subtype": .string("init"),
            "session_id": .string("sess-1"),
        ]))
        XCTAssertEqual(mapper.sessionID, "sess-1")
    }

    func testMapsAssistantTextAndThinking() {
        var mapper = ClaudeEventMapper()
        let items = mapper.push(.object([
            "type": .string("assistant"),
            "session_id": .string("sess-1"),
            "message": .object([
                "content": .array([
                    .object(["type": .string("thinking"), "thinking": .string("hmm")]),
                    .object(["type": .string("text"), "text": .string("Hi")]),
                ]),
            ]),
        ]))
        XCTAssertTrue(items.contains {
            if case .reasoning(_, let summary, _) = $0 { return summary == "hmm" }
            return false
        })
        XCTAssertTrue(items.contains {
            if case .assistant(_, let text) = $0 { return text == "Hi" }
            return false
        })
    }

    func testBashToolUseIsCommandCard() {
        var mapper = ClaudeEventMapper()
        let items = mapper.push(.object([
            "type": .string("assistant"),
            "message": .object([
                "content": .array([
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu_1"),
                        "name": .string("Bash"),
                        "input": .object(["command": .string("ls")]),
                    ]),
                ]),
            ]),
        ]))
        guard case .command(_, let command, _, _, _, _) = items.last else {
            return XCTFail("command \(items)")
        }
        XCTAssertEqual(command, "ls")
    }

    func testControlRequestBecomesApproval() {
        var mapper = ClaudeEventMapper()
        let items = mapper.push(.object([
            "type": .string("control_request"),
            "request_id": .string("req-9"),
            "request": .object([
                "subtype": .string("can_use_tool"),
                "tool_name": .string("Edit"),
                "input": .object(["file_path": .string("Panes.swift")]),
            ]),
        ]))
        guard case .approval(_, let requestID, let kind, _, let detail) = items.last else {
            return XCTFail("approval \(items)")
        }
        XCTAssertEqual(requestID, .string("req-9"))
        XCTAssertEqual(kind, .fileChange)
        XCTAssertEqual(detail, "Panes.swift")
    }

    func testResultEndsTurn() {
        var mapper = ClaudeEventMapper()
        let items = mapper.push(.object([
            "type": .string("result"),
            "session_id": .string("sess-1"),
            "is_error": .bool(false),
        ]))
        guard case .turnFinished(let id) = items.last else {
            return XCTFail("finished \(items)")
        }
        XCTAssertEqual(id, "sess-1")
    }
}
