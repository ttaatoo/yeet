//
//  KeroGrokIdleGateTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class KeroGrokIdleGateTests: XCTestCase {
    func testGenuineStopRequiresEndTurn() {
        XCTAssertTrue(
            KeroGrokIdleGate.accepts(
                isGenuineStop: true,
                isTurnEnded: false,
                payload: .object(["reason": .string("end_turn")])
            )
        )
        XCTAssertFalse(
            KeroGrokIdleGate.accepts(
                isGenuineStop: true,
                isTurnEnded: false,
                payload: .object(["reason": .string("shutdown")])
            )
        )
        XCTAssertFalse(
            KeroGrokIdleGate.accepts(
                isGenuineStop: true,
                isTurnEnded: false,
                payload: nil
            )
        )
    }

    func testTurnEndedAcceptsCancelledAndIdlePrompt() {
        XCTAssertTrue(
            KeroGrokIdleGate.accepts(
                isGenuineStop: false,
                isTurnEnded: true,
                payload: .object(["hookEventName": .string("stopCancelled")])
            )
        )
        XCTAssertTrue(
            KeroGrokIdleGate.accepts(
                isGenuineStop: false,
                isTurnEnded: true,
                payload: .object(["notificationType": .string("idle_prompt")])
            )
        )
        XCTAssertTrue(
            KeroGrokIdleGate.accepts(
                isGenuineStop: false,
                isTurnEnded: true,
                payload: nil
            ),
            "A turn-ended hook that fails to parse stdin still ends Working; the flag is the event."
        )
    }

    func testBareIdleWithoutAFlagIsRejected() {
        XCTAssertFalse(
            KeroGrokIdleGate.accepts(
                isGenuineStop: false,
                isTurnEnded: false,
                payload: .object(["reason": .string("end_turn")])
            )
        )
    }

    func testSubagentEventsDoNotIdleTheHost() {
        XCTAssertFalse(
            KeroGrokIdleGate.accepts(
                isGenuineStop: true,
                isTurnEnded: false,
                payload: .object([
                    "reason": .string("end_turn"),
                    "subagentType": .string("explore"),
                ])
            )
        )
        XCTAssertFalse(
            KeroGrokIdleGate.accepts(
                isGenuineStop: false,
                isTurnEnded: true,
                payload: .object(["subagentType": .string("explore")])
            )
        )
    }

    func testBundledGrokHooksCoverCancelledTurnsAndIdlePrompt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("yeet/AgentIntegrations/grok/yeet-agent-state.grok.json")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["StopCancelled"])
        let notifications = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let matchers = notifications.compactMap { $0["matcher"] as? String }
        XCTAssertTrue(matchers.contains("idle_prompt"))
        XCTAssertTrue(matchers.contains("agent_error"))
    }
}
