//
//  KeroAgentWaitTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class KeroAgentWaitTests: XCTestCase {
    func testDefaultsMatchIdleDoneBlockedAndTwoMinutes() throws {
        let spec = try KeroAgentWait.parse([:]).get()
        XCTAssertEqual(spec.phases, [.idle, .done, .blocked])
        XCTAssertEqual(spec.timeoutMS, 120_000)
    }

    func testImmediateMatchWhenPhaseAlreadyRequested() {
        XCTAssertEqual(
            KeroAgentWait.finished(.idle, phases: [.idle, .done, .blocked]),
            .matched
        )
        XCTAssertEqual(
            KeroAgentWait.finished(.done, phases: [.done, .blocked]),
            .matched
        )
        XCTAssertNil(KeroAgentWait.finished(.working, phases: [.idle, .done, .blocked]))
    }

    func testMissingAgentIsDisappeared() {
        XCTAssertEqual(
            KeroAgentWait.finished(nil, phases: [.idle]),
            .disappeared
        )
    }

    func testInvalidStateNamesAreInvalidParams() {
        switch KeroAgentWait.parse([
            "states": .array([.string("idle"), .string("running")]),
        ]) {
        case .success:
            XCTFail("expected invalid_params")
        case .failure(let error):
            XCTAssertEqual(
                error,
                .invalidParams(
                    "states must be an array of created, working, blocked, done, idle, or unknown."
                )
            )
        }
    }

    func testEmptyStatesAndNonArrayStatesAreInvalidParams() {
        switch KeroAgentWait.parse(["states": .array([])]) {
        case .success: XCTFail("empty states must fail")
        case .failure: break
        }
        switch KeroAgentWait.parse(["states": .string("idle,done")]) {
        case .success: XCTFail("string states must fail")
        case .failure: break
        }
        switch KeroAgentWait.parse(["states": .array([.number(1)])]) {
        case .success: XCTFail("numeric states must fail")
        case .failure: break
        }
    }

    func testTimeoutBounds() throws {
        XCTAssertEqual(
            try KeroAgentWait.parse(["timeout_ms": .number(100)]).get().timeoutMS,
            100
        )
        XCTAssertEqual(
            try KeroAgentWait.parse(["timeout_ms": .number(3_600_000)]).get().timeoutMS,
            3_600_000
        )
        switch KeroAgentWait.parse(["timeout_ms": .number(99)]) {
        case .success: XCTFail("99ms must fail")
        case .failure(let error):
            XCTAssertEqual(
                error,
                .invalidParams("timeout_ms must be between 100 and 3600000.")
            )
        }
        switch KeroAgentWait.parse(["timeout_ms": .number(3_600_001)]) {
        case .success: XCTFail("over-max must fail")
        case .failure: break
        }
        switch KeroAgentWait.parse(["timeout_ms": .string("120000")]) {
        case .success: XCTFail("string timeout must fail")
        case .failure: break
        }
    }

    func testWaitSpecIgnoresProjectAndWindowSelectors() throws {
        let spec = try KeroAgentWait.parse([
            "alias": .string("other-window-agent"),
            "project_id": .string(UUID().uuidString),
            "window_id": .string(UUID().uuidString),
            "states": .array([.string("idle")]),
        ]).get()
        XCTAssertEqual(spec.phases, [.idle])
        XCTAssertEqual(spec.timeoutMS, KeroAgentWait.defaultTimeoutMS)
        // Isolation is the router's project-scoped targetAgent, the same
        // resolver as agent.get. Wait has no project or window override.
    }

    func testTimeoutErrorIsStructuredWaitTimeout() {
        XCTAssertEqual(
            KeroAgentWait.timeoutMessage(phases: [.blocked, .done, .idle]),
            "Timed out waiting for agent state blocked, done, idle."
        )
    }

    func testProtocolMethodsAdvertiseAgentWait() {
        XCTAssertTrue(KeroAutomationCapability.methods.contains("agent.wait"))
        XCTAssertTrue(KeroAutomationCapability.methods.contains("agent.get"))
        XCTAssertTrue(KeroAutomationCapability.methods.contains("protocol.info"))
    }

    func testSocketTimeoutIncludesTransportMarginOnlyForWait() {
        XCTAssertEqual(KeroAgentWait.socketTimeout(timeoutMS: 120_000), 125)
        let wait = automationRequest(
            method: "agent.wait",
            params: ["timeout_ms": .number(1_000)]
        )
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: wait), 6)
        let get = automationRequest(method: "agent.get")
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: get), 2)
        let invalidWait = automationRequest(
            method: "agent.wait",
            params: ["timeout_ms": .number(1)]
        )
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: invalidWait), 2)
    }

    func testRaceMatchesInitialPhaseImmediately() async {
        let stream = AsyncStream<KeroAgentPhase?> { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
        let outcome = await KeroAgentWait.race(
            phases: [.idle, .done, .blocked],
            timeout: .seconds(2),
            updates: stream
        )
        XCTAssertEqual(outcome, .matched)
    }

    func testRaceTimesOutWhenPhaseNeverMatches() async {
        let stream = AsyncStream<KeroAgentPhase?> { continuation in
            continuation.yield(.working)
            continuation.onTermination = { _ in
                continuation.finish()
            }
        }
        let started = ContinuousClock.now
        let outcome = await KeroAgentWait.race(
            phases: [.idle],
            timeout: .milliseconds(150),
            updates: stream
        )
        XCTAssertEqual(outcome, .timedOut)
        let elapsed = started.duration(to: ContinuousClock.now)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testRaceDisappearsWhenAgentClears() async {
        let stream = AsyncStream<KeroAgentPhase?> { continuation in
            continuation.yield(.working)
            continuation.yield(nil)
            continuation.finish()
        }
        let outcome = await KeroAgentWait.race(
            phases: [.idle],
            timeout: .seconds(2),
            updates: stream
        )
        XCTAssertEqual(outcome, .disappeared)
    }

    func testRaceMatchesALaterPublishedPhase() async {
        let stream = AsyncStream<KeroAgentPhase?> { continuation in
            continuation.yield(.working)
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                continuation.yield(.blocked)
                continuation.finish()
            }
        }
        let outcome = await KeroAgentWait.race(
            phases: [.idle, .done, .blocked],
            timeout: .seconds(2),
            updates: stream
        )
        XCTAssertEqual(outcome, .matched)
    }

    func testExchangeWaitTimeoutSurvivesADelayedHandler() throws {
        let path = uniqueSocketPath()
        let server = try KeroAutomationSocketServer(path: path) { request, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                reply(.success(id: request.id, result: .object(["waited": .bool(true)])))
            }
        }
        defer { withExtendedLifetime(server) {} }

        let request = automationRequest(
            method: "agent.wait",
            params: ["timeout_ms": .number(1_000)]
        )
        let response = try KeroAutomationSocketServer.exchange(
            path: path,
            request: request,
            timeout: KeroAgentWait.socketTimeout(for: request)
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.objectValue?["waited"]?.boolValue, true)
    }

    func testShortClientTimeoutFailsBeforeASlowHandlerReplies() throws {
        let path = uniqueSocketPath()
        let server = try KeroAutomationSocketServer(path: path) { request, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                reply(.success(id: request.id, result: .bool(true)))
            }
        }
        defer { withExtendedLifetime(server) {} }

        XCTAssertThrowsError(
            try KeroAutomationSocketServer.exchange(
                path: path,
                request: automationRequest(method: "agent.get"),
                timeout: 0.12
            )
        )
    }

    private func automationRequest(
        method: String,
        params: [String: KeroJSONValue] = [:]
    ) -> KeroAutomationRequest {
        KeroAutomationRequest(
            version: 1,
            id: "test",
            method: method,
            token: "token",
            terminalID: UUID().uuidString,
            params: params
        )
    }

    private func uniqueSocketPath() -> String {
        "/tmp/yeet-aw-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock"
    }
}
