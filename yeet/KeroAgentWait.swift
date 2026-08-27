//
//  KeroAgentWait.swift
//  kero
//

import Combine
import Foundation

/// Shared wait policy for the `agent.wait` socket method and the CLI wrappers
/// that call it. Targeting stays project-scoped in the router (`targetAgent`);
/// this type only parses states/timeouts and races published phase updates.
enum KeroAgentWait {
    nonisolated static let defaultTimeoutMS = 120_000
    nonisolated static let minimumTimeoutMS = 100
    nonisolated static let maximumTimeoutMS = 3_600_000
    /// Accept/read of the request stays short. Only a wait response uses the
    /// full `timeout_ms` budget.
    nonisolated static let requestSocketTimeout: TimeInterval = 2
    /// Headroom so the client can still read `wait_timeout` after the wait
    /// itself expires.
    nonisolated static let transportMargin: TimeInterval = 5
    nonisolated static let defaultPhases: Set<KeroAgentPhase> = [.idle, .done, .blocked]

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

        let timeoutMS: Int
        if let value = params["timeout_ms"] {
            guard let parsed = value.intValue,
                  (minimumTimeoutMS...maximumTimeoutMS).contains(parsed)
            else {
                return .failure(.invalidParams(
                    "timeout_ms must be between \(minimumTimeoutMS) and \(maximumTimeoutMS)."
                ))
            }
            timeoutMS = parsed
        } else {
            timeoutMS = defaultTimeoutMS
        }

        return .success(Spec(phases: phases, timeoutMS: timeoutMS))
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
        guard request.method == "agent.wait" else { return requestSocketTimeout }
        let timeoutMS = request.params["timeout_ms"]?.intValue ?? defaultTimeoutMS
        guard (minimumTimeoutMS...maximumTimeoutMS).contains(timeoutMS) else {
            return requestSocketTimeout
        }
        return socketTimeout(timeoutMS: timeoutMS)
    }

    /// Subscribes on the caller's actor (the router is main-actor) so Combine
    /// delivery of `@Published agentStatus` stays on the thread that publishes
    /// it. The caller must invoke `cancel` when the wait ends. The first value
    /// is the current phase.
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
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await phase in updates {
                    if let outcome = finished(phase, phases: phases) {
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
