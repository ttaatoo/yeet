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

    func testImmediateRecognitionWhenProcessAuthorityHasPid() {
        XCTAssertEqual(
            KeroAgentWait.recognized(
                agentStatus(authority: .process, processID: 4242)
            ),
            .matched
        )
        XCTAssertEqual(
            KeroAgentWait.recognized(
                agentStatus(authority: .integration, processID: 7)
            ),
            .matched
        )
    }

    func testCommandAuthorityOrMissingPidIsNotYetRecognized() {
        XCTAssertNil(
            KeroAgentWait.recognized(
                agentStatus(authority: .command, processID: nil)
            )
        )
        XCTAssertNil(
            KeroAgentWait.recognized(
                agentStatus(authority: .command, processID: 99)
            )
        )
        XCTAssertNil(
            KeroAgentWait.recognized(
                agentStatus(authority: .process, processID: nil)
            )
        )
    }

    func testMissingAgentIsDisappearedForRecognition() {
        XCTAssertEqual(KeroAgentWait.recognized(nil), .disappeared)
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

    func testStartTimeoutBounds() throws {
        XCTAssertEqual(try KeroAgentWait.parseStartTimeout([:]).get(), 30_000)
        XCTAssertEqual(
            try KeroAgentWait.parseStartTimeout(["timeout_ms": .number(3_000)]).get(),
            3_000
        )
        XCTAssertEqual(
            try KeroAgentWait.parseStartTimeout(["timeout_ms": .number(300_000)]).get(),
            300_000
        )
        switch KeroAgentWait.parseStartTimeout(["timeout_ms": .number(2_999)]) {
        case .success: XCTFail("2999ms must fail")
        case .failure(let error):
            XCTAssertEqual(
                error,
                .invalidParams("timeout_ms must be between 3000 and 300000.")
            )
        }
        switch KeroAgentWait.parseStartTimeout(["timeout_ms": .number(300_001)]) {
        case .success: XCTFail("over-max start timeout must fail")
        case .failure: break
        }
        switch KeroAgentWait.parseStartTimeout(["timeout_ms": .number(100)]) {
        case .success: XCTFail("wait-min is below start-min")
        case .failure: break
        }
        switch KeroAgentWait.parseStartTimeout(["timeout_ms": .string("30000")]) {
        case .success: XCTFail("string start timeout must fail")
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

    func testStartParamsDefaultToSharedCheckout() throws {
        let spec = try KeroAgentWait.parseStart([:]).get()
        XCTAssertEqual(spec.timeoutMS, 30_000)
        XCTAssertFalse(spec.worktree)
        let omitted = try KeroAgentWait.parseStart([
            "timeout_ms": .number(12_000),
            "alias": .string("tests"),
        ]).get()
        XCTAssertEqual(omitted.timeoutMS, 12_000)
        XCTAssertFalse(omitted.worktree)
        let explicitOff = try KeroAgentWait.parseStart([
            "worktree": .bool(false),
        ]).get()
        XCTAssertFalse(explicitOff.worktree)
        let nullWorktree = try KeroAgentWait.parseStart([
            "worktree": .null,
        ]).get()
        XCTAssertFalse(nullWorktree.worktree)
    }

    func testStartParamsParseOptInWorktree() throws {
        let spec = try KeroAgentWait.parseStart([
            "worktree": .bool(true),
            "timeout_ms": .number(8_000),
        ]).get()
        XCTAssertTrue(spec.worktree)
        XCTAssertEqual(spec.timeoutMS, 8_000)
    }

    func testStartParamsRejectNonBooleanWorktree() {
        switch KeroAgentWait.parseStart(["worktree": .string("true")]) {
        case .success: XCTFail("string worktree must fail")
        case .failure(let error):
            XCTAssertEqual(error, .invalidParams("worktree must be a boolean."))
        }
        switch KeroAgentWait.parseStart(["worktree": .number(1)]) {
        case .success: XCTFail("numeric worktree must fail")
        case .failure: break
        }
        switch KeroAgentWait.parseStart(["worktree": .array([])]) {
        case .success: XCTFail("array worktree must fail")
        case .failure: break
        }
    }

    func testStartParamsStillValidateTimeoutWhenWorktreeIsSet() {
        switch KeroAgentWait.parseStart([
            "worktree": .bool(true),
            "timeout_ms": .number(2_999),
        ]) {
        case .success: XCTFail("worktree must not skip timeout bounds")
        case .failure(let error):
            XCTAssertEqual(
                error,
                .invalidParams("timeout_ms must be between 3000 and 300000.")
            )
        }
    }

    func testStartTimeoutIgnoresProjectAndWindowSelectors() throws {
        let timeoutMS = try KeroAgentWait.parseStartTimeout([
            "alias": .string("other-window-agent"),
            "project_id": .string(UUID().uuidString),
            "window_id": .string(UUID().uuidString),
            "timeout_ms": .number(12_000),
        ]).get()
        XCTAssertEqual(timeoutMS, 12_000)
        // Start targeting stays on the caller's project via targetPane.
    }

    func testTimeoutErrorIsStructuredWaitTimeout() {
        XCTAssertEqual(
            KeroAgentWait.timeoutMessage(phases: [.blocked, .done, .idle]),
            "Timed out waiting for agent state blocked, done, idle."
        )
        XCTAssertEqual(
            KeroAgentWait.startTimeoutMessage,
            "Timed out waiting for Yeet to recognize the launched agent."
        )
    }

    func testProtocolMethodsAdvertiseAgentWaitAndStart() {
        XCTAssertTrue(KeroAutomationCapability.methods.contains("agent.wait"))
        XCTAssertTrue(KeroAutomationCapability.methods.contains("agent.start"))
        XCTAssertTrue(KeroAutomationCapability.methods.contains("agent.get"))
        XCTAssertTrue(KeroAutomationCapability.methods.contains("protocol.info"))
    }

    func testSocketTimeoutIncludesTransportMarginForWaitAndStart() {
        XCTAssertEqual(KeroAgentWait.socketTimeout(timeoutMS: 120_000), 125)
        let wait = automationRequest(
            method: "agent.wait",
            params: ["timeout_ms": .number(1_000)]
        )
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: wait), 6)
        let start = automationRequest(
            method: "agent.start",
            params: ["timeout_ms": .number(3_000)]
        )
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: start), 8)
        let startDefault = automationRequest(method: "agent.start")
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: startDefault), 35)
        let get = automationRequest(method: "agent.get")
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: get), 2)
        let invalidWait = automationRequest(
            method: "agent.wait",
            params: ["timeout_ms": .number(1)]
        )
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: invalidWait), 2)
        let invalidStart = automationRequest(
            method: "agent.start",
            params: ["timeout_ms": .number(1)]
        )
        XCTAssertEqual(KeroAgentWait.socketTimeout(for: invalidStart), 2)
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

    func testRaceMatchesImmediateRecognition() async {
        let stream = AsyncStream<KeroAgentStatus?> { continuation in
            continuation.yield(agentStatus(authority: .process, processID: 11))
            continuation.finish()
        }
        let outcome = await KeroAgentWait.race(
            timeout: .seconds(2),
            updates: stream,
            finished: KeroAgentWait.recognized
        )
        XCTAssertEqual(outcome, .matched)
    }

    func testRaceTimesOutWhenNeverRecognized() async {
        let stream = AsyncStream<KeroAgentStatus?> { continuation in
            continuation.yield(agentStatus(authority: .command, processID: nil))
            continuation.onTermination = { _ in
                continuation.finish()
            }
        }
        let started = ContinuousClock.now
        let outcome = await KeroAgentWait.race(
            timeout: .milliseconds(150),
            updates: stream,
            finished: KeroAgentWait.recognized
        )
        XCTAssertEqual(outcome, .timedOut)
        let elapsed = started.duration(to: ContinuousClock.now)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testRaceDisappearsWhenAgentClearsBeforeRecognition() async {
        let stream = AsyncStream<KeroAgentStatus?> { continuation in
            continuation.yield(agentStatus(authority: .command, processID: nil))
            continuation.yield(nil)
            continuation.finish()
        }
        let outcome = await KeroAgentWait.race(
            timeout: .seconds(2),
            updates: stream,
            finished: KeroAgentWait.recognized
        )
        XCTAssertEqual(outcome, .disappeared)
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

    func testExchangeStartTimeoutSurvivesADelayedHandler() throws {
        let path = uniqueSocketPath()
        let server = try KeroAutomationSocketServer(path: path) { request, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                reply(.success(id: request.id, result: .object(["started": .bool(true)])))
            }
        }
        defer { withExtendedLifetime(server) {} }

        let request = automationRequest(
            method: "agent.start",
            params: ["timeout_ms": .number(3_000)]
        )
        let response = try KeroAutomationSocketServer.exchange(
            path: path,
            request: request,
            timeout: KeroAgentWait.socketTimeout(for: request)
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.objectValue?["started"]?.boolValue, true)
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

    private func agentStatus(
        authority: KeroAgentStateAuthority,
        processID: pid_t?
    ) -> KeroAgentStatus {
        KeroAgentStatus(
            alias: "tests",
            kind: .codex,
            phase: authority == .command ? .working : .created,
            authority: authority,
            reason: "test",
            updatedAt: Date(),
            processID: processID,
            sessionID: nil,
            unseen: false
        )
    }
}
