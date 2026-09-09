//
//  ACPEventMapperTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class ACPEventMapperTests: XCTestCase {
    func testMapsAssistantChunks() {
        var mapper = ACPEventMapper()
        let first = mapper.applyNotification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("m1"),
                    "content": .object(["type": .string("text"), "text": .string("Hel")]),
                ]),
            ])
        )
        let second = mapper.applyNotification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "messageId": .string("m1"),
                    "content": .object(["type": .string("text"), "text": .string("lo")]),
                ]),
            ])
        )
        guard case .assistant(_, let text) = second.last else {
            return XCTFail("assistant")
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(first.count, 1)
    }

    func testMapsThoughtChunk() {
        var mapper = ACPEventMapper()
        let items = mapper.applyNotification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("plan")]),
                ]),
            ])
        )
        guard case .reasoning(_, let summary, _) = items.last else {
            return XCTFail("reasoning")
        }
        XCTAssertEqual(summary, "plan")
    }

    func testExecuteToolBecomesCommandCard() {
        var mapper = ACPEventMapper()
        let items = mapper.applyNotification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("c1"),
                    "kind": .string("execute"),
                    "title": .string("cargo test"),
                    "rawInput": .object(["command": .string("cargo test")]),
                ]),
            ])
        )
        guard case .command(_, let command, _, _, _, _) = items.last else {
            return XCTFail("command \(items)")
        }
        XCTAssertEqual(command, "cargo test")
    }

    func testPermissionRequestBecomesCard() {
        let mapper = ACPEventMapper()
        let item = mapper.applyPermissionRequest(
            id: .number(5),
            params: .object([
                "toolCall": .object([
                    "title": .string("Run tests"),
                    "kind": .string("execute"),
                    "rawInput": .object(["command": .string("npm test")]),
                ]),
            ])
        )
        guard case .approval(_, let requestID, let kind, _, let detail) = item else {
            return XCTFail("approval")
        }
        XCTAssertEqual(requestID, .number(5))
        XCTAssertEqual(kind, .command)
        XCTAssertEqual(detail, "npm test")
    }

    func testPermissionResultPicksAllowOnce() {
        let options: [KeroJSONValue] = [
            .object([
                "optionId": .string("allow-once"),
                "name": .string("Allow"),
                "kind": .string("allow_once"),
            ]),
            .object([
                "optionId": .string("reject-once"),
                "name": .string("Reject"),
                "kind": .string("reject_once"),
            ]),
        ]
        let result = ACPEventMapper.permissionResult(.accept, options: options)
        XCTAssertEqual(
            result.objectValue?["outcome"]?.objectValue?["optionId"]?.stringValue,
            "allow-once"
        )
    }
}
