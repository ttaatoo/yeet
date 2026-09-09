//
//  CodexEventMapperTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class CodexEventMapperTests: XCTestCase {
    func testMapsAgentMessageDelta() throws {
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [
            #"{"method":"item/started","params":{"item":{"id":"i1","type":"agentMessage","text":""}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"itemId":"i1","delta":"Hello"}}"#,
            #"{"method":"item/completed","params":{"item":{"id":"i1","type":"agentMessage","text":"Hello"}}}"#,
        ])
        guard case .assistant(_, let text) = items.last else {
            return XCTFail("assistant, got \(items)")
        }
        XCTAssertEqual(text, "Hello")
    }

    func testApprovalBecomesCardNotPtyKeystroke() throws {
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [
            #"{"id":61,"method":"item/commandExecution/requestApproval","params":{"command":"rm -rf /"}}"#,
        ])
        guard case .approval(_, let requestID, let kind, _, let detail) = items.last else {
            return XCTFail("approval, got \(items)")
        }
        XCTAssertEqual(requestID, .number(61))
        XCTAssertEqual(kind, .command)
        XCTAssertEqual(detail, "rm -rf /")
    }

    func testFileChangeApproval() throws {
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [
            #"{"id":62,"method":"item/fileChange/requestApproval","params":{"reason":"edit"}}"#,
        ])
        guard case .approval(_, let requestID, let kind, _, _) = items.last else {
            return XCTFail("approval, got \(items)")
        }
        XCTAssertEqual(requestID, .number(62))
        XCTAssertEqual(kind, .fileChange)
    }

    func testCommandOutputTruncatesAtTwentyLines() throws {
        let output = (1...30).map { "line\($0)" }.joined(separator: "\n")
        let payload: [String: Any] = [
            "method": "item/completed",
            "params": [
                "item": [
                    "id": "c1",
                    "type": "commandExecution",
                    "command": "tests",
                    "aggregatedOutput": output,
                    "exitCode": 1,
                    "durationMs": 10,
                ] as [String: Any],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = String(data: data, encoding: .utf8)!
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [line])
        guard case .command(_, let command, let exitCode, let durationMs, let preview, _) = items.last else {
            return XCTFail("command, got \(items)")
        }
        XCTAssertEqual(command, "tests")
        XCTAssertEqual(exitCode, 1)
        XCTAssertEqual(durationMs, 10)
        XCTAssertEqual(preview.split(separator: "\n").count, 20)
    }

    func testFileChangeIsOneLineSummaryNotHunk() throws {
        let diff = """
        --- a/GitStatusModel.swift
        +++ b/GitStatusModel.swift
        @@ -1,3 +1,4 @@
         keep
        -old
        +new
        +also
        """
        let payload: [String: Any] = [
            "method": "item/started",
            "params": [
                "item": [
                    "id": "f1",
                    "type": "fileChange",
                    "status": "inProgress",
                    "changes": [
                        [
                            "path": "GitStatusModel.swift",
                            "kind": ["type": "update"],
                            "diff": diff,
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = String(data: data, encoding: .utf8)!
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [line])
        guard case .tool(_, let path, let added, let removed, _) = items.last else {
            return XCTFail("tool, got \(items)")
        }
        XCTAssertEqual(path, "GitStatusModel.swift")
        XCTAssertEqual(added, 2)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(items.contains { item in
            if case .assistant(_, let text) = item { return text.contains("@@") }
            return false
        })
    }

    func testDropsSubAgentSource() throws {
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [
            #"{"method":"item/started","params":{"source":"subAgent","item":{"id":"i9","type":"agentMessage","text":"secret"}}}"#,
        ])
        XCTAssertTrue(items.isEmpty)
    }

    func testTurnCompletedEmitsFinished() throws {
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [
            #"{"method":"turn/completed","params":{"turn":{"id":"t9","status":"completed"}}}"#,
        ])
        guard case .turnFinished(let id) = items.last else {
            return XCTFail("turnFinished, got \(items)")
        }
        XCTAssertEqual(id, "t9")
    }

    func testIgnoresUnknownNotification() throws {
        var mapper = CodexEventMapper()
        let items = try mapper.push(lines: [
            #"{"method":"thread/tokenUsage/updated","params":{"total":1}}"#,
        ])
        XCTAssertTrue(items.isEmpty)
    }
}
