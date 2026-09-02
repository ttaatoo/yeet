//
//  KeroAgentWait.swift
//  kero
//

import Combine
import Foundation

/// Shared wait policy for `agent.wait`, `agent.start` recognition, and the
/// CLI wrappers that call them. Targeting stays project-scoped in the router
/// (`targetAgent` / `targetPane`); this type only parses timeouts and races
/// published agent-status updates.
enum KeroAgentWait {
    nonisolated static let defaultTimeoutMS = 120_000
    nonisolated static let minimumTimeoutMS = 100
    nonisolated static let maximumTimeoutMS = 3_600_000
    /// CLI and socket `agent.start` keep the historical recognition window.
    nonisolated static let startDefaultTimeoutMS = 30_000
    nonisolated static let startMinimumTimeoutMS = 3_000
    nonisolated static let startMaximumTimeoutMS = 300_000
    /// Accept/read of the request stays short. Only a wait response uses the
    /// full `timeout_ms` budget.
    nonisolated static let requestSocketTimeout: TimeInterval = 2
    /// Headroom so the client can still read `wait_timeout` after the wait
    /// itself expires.
    nonisolated static let transportMargin: TimeInterval = 5
    nonisolated static let defaultPhases: Set<KeroAgentPhase> = [.idle, .done, .blocked]
    nonisolated static let startTimeoutMessage =
        "Timed out waiting for Yeet to recognize the launched agent."
    nonisolated static let startDisappearedMessage =
        "The launched agent exited before Yeet recognized it."

    struct Spec: Equatable, Sendable {
        var phases: Set<KeroAgentPhase>
        var timeoutMS: Int
    }

    enum ParseError: Equatable, Error, Sendable {
        case invalidParams(String)

        var message: String {
            switch self {
            case .invalidParams(let message): return message
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case matched
        case disappeared
        case timedOut
    }

    private static let statesMessage =
        "states must be an array of created, working, blocked, done, idle, or unknown."

    static func parse(_ params: [String: KeroJSONValue]) -> Result<Spec, ParseError> {
        let phases: Set<KeroAgentPhase>
        if let value = params["states"] {
            guard let items = value.arrayValue else {
                return .failure(.invalidParams(statesMessage))
            }
            let names = items.compactMap(\.stringValue)
            guard names.count == items.count else {
                return .failure(.invalidParams(statesMessage))
            }
            switch parsePhases(names) {
            case .success(let parsed):
                phases = parsed
            case .failure(let error):
                return .failure(error)
            }
        } else {
            phases = defaultPhases
        }

        switch parseTimeout(
            params["timeout_ms"],
            defaultTimeoutMS: defaultTimeoutMS,
            minimum: minimumTimeoutMS,
            maximum: maximumTimeoutMS
        ) {
        case .success(let timeoutMS):
            return .success(Spec(phases: phases, timeoutMS: timeoutMS))
        case .failure(let error):
            return .failure(error)
        }
    }

    static func parseStartTimeout(_ params: [String: KeroJSONValue]) -> Result<Int, ParseError> {
        parseTimeout(
            params["timeout_ms"],
            defaultTimeoutMS: startDefaultTimeoutMS,
            minimum: startMinimumTimeoutMS,
            maximum: startMaximumTimeoutMS
        )
    }

    static func parsePhases(_ names: [String]) -> Result<Set<KeroAgentPhase>, ParseError> {
        let phases = Set(names.compactMap(KeroAgentPhase.init(rawValue:)))
        guard !names.isEmpty, phases.count == names.count else {
            return .failure(.invalidParams(statesMessage))
        }
        return .success(phases)
    }

    /// Immediate decision for a published phase. `nil` means keep waiting.
    /// Terminal text is never consulted.
    nonisolated static func finished(
        _ phase: KeroAgentPhase?,
        phases: Set<KeroAgentPhase>
    ) -> Outcome? {
        guard let phase else { return .disappeared }
        return phases.contains(phase) ? .matched : nil
    }

    /// Immediate decision for `agent.start` process recognition. Authority
    /// must leave `.command` and a pid must be present. Terminal text is
    /// never consulted.
    nonisolated static func recognized(_ status: KeroAgentStatus?) -> Outcome? {
        guard let status else { return .disappeared }
        guard status.authority != .command, status.processID != nil else {
            return nil
        }
        return .matched
    }

    nonisolated static func timeoutMessage(phases: Set<KeroAgentPhase>) -> String {
        let names = phases.map(\.rawValue).sorted().joined(separator: ", ")
        return "Timed out waiting for agent state \(names)."
    }

    nonisolated static func socketTimeout(timeoutMS: Int) -> TimeInterval {
        Double(timeoutMS) / 1_000 + transportMargin
    }

    /// Client and accepted-server sockets use this after the request is on
    /// the wire. Non-wait methods keep the short default. The socket worker
    /// is not main-actor isolated.
    nonisolated static func socketTimeout(for request: KeroAutomationRequest) -> TimeInterval {
        switch request.method {
        case "agent.wait":
            return waitingSocketTimeout(
                params: request.params,
                defaultTimeoutMS: defaultTimeoutMS,
                minimum: minimumTimeoutMS,
                maximum: maximumTimeoutMS
            )
        case "agent.start":
            return waitingSocketTimeout(
                params: request.params,
                defaultTimeoutMS: startDefaultTimeoutMS,
                minimum: startMinimumTimeoutMS,
                maximum: startMaximumTimeoutMS
            )
        default:
            return requestSocketTimeout
        }
    }

    /// Subscribes on the caller's actor (the router is main-actor) so Combine
    /// delivery of `@Published agentStatus` stays on the thread that publishes
    /// it. The caller must invoke `cancel` when the wait ends. The first value
    /// is the current status.
    static func statusUpdates(from session: TerminalSession) -> (
        stream: AsyncStream<KeroAgentStatus?>,
        cancel: () -> Void
    ) {
        let (stream, continuation) = AsyncStream<KeroAgentStatus?>.makeStream()
        let sink = session.$agentStatus.sink { status in
            continuation.yield(status)
        }
        return (stream, {
            sink.cancel()
            continuation.finish()
        })
    }

    /// Phase-only view of `statusUpdates` for `agent.wait`.
    static func phaseUpdates(from session: TerminalSession) -> (
        stream: AsyncStream<KeroAgentPhase?>,
        cancel: () -> Void
    ) {
        let (stream, continuation) = AsyncStream<KeroAgentPhase?>.makeStream()
        let sink = session.$agentStatus.sink { status in
            continuation.yield(status?.phase)
        }
        return (stream, {
            sink.cancel()
            continuation.finish()
        })
    }

    /// Races published phase updates against `timeout`. The timeout sleep is
    /// not main-actor isolated, so a long wait does not hitch AppKit.
    nonisolated static func race(
        phases: Set<KeroAgentPhase>,
        timeout: Duration,
        updates: AsyncStream<KeroAgentPhase?>
    ) async -> Outcome {
        await raceUpdates(timeout: timeout, updates: updates) { phase in
            finished(phase, phases: phases)
        }
    }

    /// Same race as `agent.wait`, with a caller-supplied finish predicate.
    /// Used by `agent.start` recognition (`recognized`).
    nonisolated static func race(
        timeout: Duration,
        updates: AsyncStream<KeroAgentStatus?>,
        finished: @escaping @Sendable (KeroAgentStatus?) -> Outcome?
    ) async -> Outcome {
        await raceUpdates(timeout: timeout, updates: updates, finished: finished)
    }

    private static func parseTimeout(
        _ value: KeroJSONValue?,
        defaultTimeoutMS: Int,
        minimum: Int,
        maximum: Int
    ) -> Result<Int, ParseError> {
        guard let value else { return .success(defaultTimeoutMS) }
        guard let parsed = value.intValue, (minimum...maximum).contains(parsed) else {
            return .failure(.invalidParams(
                "timeout_ms must be between \(minimum) and \(maximum)."
            ))
        }
        return .success(parsed)
    }

    private nonisolated static func waitingSocketTimeout(
        params: [String: KeroJSONValue],
        defaultTimeoutMS: Int,
        minimum: Int,
        maximum: Int
    ) -> TimeInterval {
        let timeoutMS = params["timeout_ms"]?.intValue ?? defaultTimeoutMS
        guard (minimum...maximum).contains(timeoutMS) else {
            return requestSocketTimeout
        }
        return socketTimeout(timeoutMS: timeoutMS)
    }

    /// Timeout sleep is not main-actor isolated, so a long wait does not hitch
    /// AppKit. Stream finish without a decision is disappearance.
    private nonisolated static func raceUpdates<Value: Sendable>(
        timeout: Duration,
        updates: AsyncStream<Value>,
        finished: @escaping @Sendable (Value) -> Outcome?
    ) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await value in updates {
                    if let outcome = finished(value) {
                        return outcome
                    }
                }
                return .disappeared
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}
