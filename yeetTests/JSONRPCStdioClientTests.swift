//
//  JSONRPCStdioClientTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class JSONRPCStdioClientTests: XCTestCase {
    func testDecodesNotificationWithoutId() throws {
        let line = #"{"method":"turn/started","params":{"turn":{"id":"t1"}}}"#
        let msg = try JSONRPCCodec.decodeLine(line)
        guard case .notification(let method, let params) = msg else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(method, "turn/started")
        XCTAssertEqual(params?.objectValue?["turn"]?.objectValue?["id"]?.stringValue, "t1")
    }

    func testDecodesInboundApprovalRequest() throws {
        let line = #"{"id":61,"method":"item/commandExecution/requestApproval","params":{"command":"ls"}}"#
        let msg = try JSONRPCCodec.decodeLine(line)
        guard case .request(let id, let method, _) = msg else {
            return XCTFail("expected request")
        }
        XCTAssertEqual(id, .number(61))
        XCTAssertEqual(method, "item/commandExecution/requestApproval")
    }

    func testDecodesResponse() throws {
        let line = #"{"id":1,"result":{"thread":{"id":"abc"}}}"#
        let msg = try JSONRPCCodec.decodeLine(line)
        guard case .response(let id, let result) = msg else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(result.objectValue?["thread"]?.objectValue?["id"]?.stringValue, "abc")
    }

    func testDecodesStringID() throws {
        let line = #"{"id":"req-1","method":"ping"}"#
        let msg = try JSONRPCCodec.decodeLine(line)
        guard case .request(let id, let method, _) = msg else {
            return XCTFail("expected request")
        }
        XCTAssertEqual(id, .string("req-1"))
        XCTAssertEqual(method, "ping")
    }

    func testEncodeOmitsJsonrpcField() throws {
        let data = try JSONRPCCodec.encodeLine(
            .request(id: .number(0), method: "initialize", params: .object([:]))
        )
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("jsonrpc"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"method\":\"initialize\""))
    }

    func testEncodeIncludesJsonrpcForACP() throws {
        let data = try JSONRPCCodec.encodeLine(
            .request(id: .number(1), method: "initialize", params: .object([:])),
            jsonrpcVersion: "2.0"
        )
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("\"jsonrpc\":\"2.0\""))
    }

    func testRoundTripNotification() throws {
        let original = JSONRPCMessage.notification(
            method: "initialized",
            params: .object([:])
        )
        let data = try JSONRPCCodec.encodeLine(original)
        let line = String(data: data, encoding: .utf8)!
        let decoded = try JSONRPCCodec.decodeLine(line)
        XCTAssertEqual(decoded, original)
    }

}
