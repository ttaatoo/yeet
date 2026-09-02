//
//  KeroAutomationRouter.swift
//  kero
//

import AppKit
import Foundation

/// Main-actor command router behind the authenticated Unix socket. A caller's
/// capability resolves to one terminal and therefore one project. Targets are
/// searched only inside that project; no request can reach another window or
/// project by guessing a UUID.
@MainActor
enum KeroAutomationRouter {
    private struct PaneContext {
        let manager: TerminalManager
        let project: Project
        let tab: PaneTab
        let pane: Pane

        var session: TerminalSession? {
            guard case .session(let session) = pane.content else { return nil }
            return session
        }
    }

    static func route(
        _ request: KeroAutomationRequest,
        callerTerminalID: UUID
    ) async -> KeroAutomationResponse {
        guard let caller = context(forSession: callerTerminalID) else {
            return failure(
                request, "caller_closed",
                "The terminal that owned this capability is no longer open."
            )
        }

        switch request.method {
        case "protocol.info":
            return success(request, .object([
                "version": .number(1),
                "scope": .string("project"),
                "current_terminal_id": .string(callerTerminalID.uuidString),
                "reads_mark_seen": .bool(false),
                "split_focus_default": .bool(false),
                "methods": .array(
                    KeroAutomationCapability.methods.map(KeroJSONValue.string)
                ),
            ]))

        case "pane.current":
            return success(request, paneSnapshot(caller, caller: caller))

        case "pane.list":
            return success(
                request,
                .array(projectContexts(caller.project, manager: caller.manager).map {
                    paneSnapshot($0, caller: caller)
                })
            )

        case "pane.get":
            guard let target = targetPane(request, caller: caller) else {
                return failure(request, "pane_not_found", "No matching pane exists in this project.")
            }
            return success(request, paneSnapshot(target, caller: caller))

        case "pane.split":
            return splitPane(request, caller: caller)

        case "pane.run":
            return runInPane(request, caller: caller)

        case "pane.send":
            return sendToPane(request, caller: caller)

        case "pane.read":
            return await readPane(request, caller: caller)

        case "agent.list":
            let agents = projectContexts(caller.project, manager: caller.manager)
                .compactMap { context -> KeroJSONValue? in
                    guard context.session?.agentStatus != nil else { return nil }
                    return paneSnapshot(context, caller: caller)
                }
            return success(request, .array(agents))

        case "agent.get":
            guard let target = targetAgent(request, caller: caller) else {
                return failure(request, "agent_not_found", "No matching agent exists in this project.")
            }
            return success(request, paneSnapshot(target, caller: caller))

        case "agent.start":
            return await startAgent(request, caller: caller)

        case "agent.prompt":
            return promptAgent(request, caller: caller)

        case "agent.report":
            return reportAgent(request, caller: caller)

        case "agent.wait":
            return await waitForAgent(request, caller: caller)

        default:
            return failure(
                request, "method_not_found",
                "Unknown automation method \(request.method)."
            )
        }
    }

    private static func splitPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller) else {
            return failure(request, "pane_not_found", "No matching pane exists in this project.")
        }
        guard !target.pane.content.isDiff else {
            return failure(request, "pane_not_splittable", "Diff panes cannot be split.")
        }
        guard let edgeName = request.params["edge"]?.stringValue,
              let edge = paneEdge(edgeName)
        else {
            return failure(
                request, "invalid_params",
                "edge must be one of left, right, top, or bottom."
            )
        }
        let focus = request.params["focus"]?.boolValue ?? false
        let directory = request.params["cwd"]?.stringValue
        if let directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory, isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                return failure(
                    request, "invalid_directory",
                    "The requested working directory does not exist."
                )
            }
        }

        guard let created = caller.project.automationSplitTerminal(
            beside: target.pane.id,
            toward: edge,
            directory: directory,
            focus: focus
        ) else {
            return failure(request, "pane_not_splittable", "The target pane could not be split.")
        }
        if focus { TerminalManager.revealSession(id: created.session.id) }
        let context = PaneContext(
            manager: caller.manager,
            project: caller.project,
            tab: created.tab,
            pane: created.pane
        )
        return success(request, paneSnapshot(context, caller: caller))
    }

    private static func runInPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        guard session.isShellAvailableForAutomation else {
            return failure(
                request, "shell_busy",
                "The target terminal does not have an available foreground shell."
            )
        }
        guard let argv = stringArray(request.params["argv"]),
              !argv.isEmpty, argv.count <= 256,
              !argv[0].isEmpty,
              argv.allSatisfy({
                  $0.utf8.count <= 16_384 && isSafeShellArgument($0)
              })
        else {
            return failure(
                request, "invalid_params",
                "argv must contain 1 to 256 control-free arguments with a non-empty executable."
            )
        }
        let command = argv.map(shellQuote).joined(separator: " ")
        session.sendCommand(command + "\r")
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func sendToPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        guard let text = request.params["text"]?.stringValue,
              text.utf8.count <= 262_144 else {
            return failure(
                request, "invalid_params",
                "text is required and is limited to 256 KiB."
            )
        }
        session.sendCommand(text)
        if request.params["enter"]?.boolValue == true {
            session.sendCommand("\r")
        }
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func readPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) async -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        let lines = min(max(request.params["lines"]?.intValue ?? 80, 1), 500)
        let columns = min(max(request.params["columns"]?.intValue ?? 400, 1), 2_000)
        do {
            let text = try await session.automationReadText(
                maxLines: lines,
                maxColumns: columns,
                requireIdleAgentForHistory:
                    request.params["require_idle_agent"]?.boolValue == true
            )
            return success(request, .object([
                "pane": paneSnapshot(target, caller: caller),
                "text": .string(text),
                "lines": .number(Double(lines)),
                "columns": .number(Double(columns)),
            ]))
        } catch KeroAutomationReadError.agentNotIdle {
            return failure(
                request,
                "agent_not_idle",
                "Alternate-screen transcript history is available only after the agent settles. Wait for idle or done, then read again."
            )
        } catch {
            return failure(
                request,
                "read_failed",
                "Yeet could not read the terminal transcript."
            )
        }
    }

    /// Optional worktree create/attach, then declare, launch, then wait for
    /// Yeet to recognize the process. Same race as `agent.wait` over
    /// `$agentStatus`; terminal text is never classified, and `Thread.sleep`
    /// is never used here.
    private static func startAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) async -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let initialSession = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        var session = initialSession
        guard session.isShellAvailableForAutomation else {
            return failure(
                request, "shell_busy",
                "Agents can start only in an existing terminal with an available shell."
            )
        }
        guard session.agentStatus == nil else {
            return failure(
                request, "agent_already_declared",
                "This terminal already has an active or pending agent."
            )
        }
        guard let alias = request.params["alias"]?.stringValue,
              isValidAlias(alias) else {
            return failure(
                request, "invalid_alias",
                "alias must be 1 to 64 ASCII letters, numbers, dots, underscores, or hyphens."
            )
        }
        guard let kindName = request.params["kind"]?.stringValue,
              let kind = KeroAgentKind(rawValue: kindName) else {
            return failure(
                request, "invalid_agent_kind",
                "Supported kinds: \(KeroAgentKind.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        let duplicate = caller.project.sessions.contains {
            $0.id != session.id && $0.agentStatus?.alias == alias
        }
        guard !duplicate else {
            return failure(
                request, "alias_in_use",
                "Another agent in this project already uses alias \(alias)."
            )
        }
        let extra = stringArray(request.params["argv"]) ?? []
        guard extra.count <= 128,
              extra.allSatisfy({
                  $0.utf8.count <= 16_384 && isSafeShellArgument($0)
              }) else {
            return failure(
                request, "invalid_params",
                "Agent arguments exceed the protocol limits or contain terminal control characters."
            )
        }
        let start: KeroAgentWait.StartSpec
        switch KeroAgentWait.parseStart(request.params) {
        case .success(let value):
            start = value
        case .failure(let error):
            return failure(request, "invalid_params", error.message)
        }

        // Worktree create/attach happens before declare so a git failure
        // cannot leave a half-declared agent. Recognition wait stays after
        // launch, same as a shared-checkout start.
        var worktree: KeroAgentWorktree.Checkout?
        if start.worktree {
            let cwd = session.currentDirectoryPath
            let prepared = await Task.detached {
                KeroAgentWorktree.prepare(alias: alias, cwd: cwd)
            }.value
            switch prepared {
            case .success(let checkout):
                worktree = checkout
            case .failure(let error):
                return failure(request, error.code, error.message)
            }
            // Re-check after prepare: the pane or alias may have been taken
            // during git. Do not auto-remove; leftover checkout is v1 and
            // the operator deletes with `git worktree remove`.
            guard let current = targetPane(request, caller: caller),
                  let live = current.session else {
                return failure(
                    request, "terminal_required",
                    "The target pane is not a terminal."
                )
            }
            guard live.agentStatus == nil else {
                return failure(
                    request, "agent_already_declared",
                    "This terminal already has an active or pending agent."
                )
            }
            session = live
            let taken = caller.project.sessions.contains {
                $0.id != session.id && $0.agentStatus?.alias == alias
            }
            guard !taken else {
                return failure(
                    request, "alias_in_use",
                    "Another agent in this project already uses alias \(alias)."
                )
            }
        }

        session.declareAutomationAgent(alias: alias, kind: kind)
        let launch = ([kind.executable] + extra).map(shellQuote).joined(separator: " ")
        // Same shell line as launch so the agent never starts in the shared
        // checkout if chdir races the next prompt.
        let command = worktree.map {
            "cd \(shellQuote($0.path)) && \(launch)"
        } ?? launch
        session.sendCommand(command + "\r")
        if request.params["focus"]?.boolValue == true {
            TerminalManager.revealSession(id: session.id)
        }

        let observation = KeroAgentWait.statusUpdates(from: session)
        defer { observation.cancel() }
        let outcome = await KeroAgentWait.race(
            timeout: .milliseconds(start.timeoutMS),
            updates: observation.stream,
            finished: KeroAgentWait.recognized
        )
        switch outcome {
        case .matched:
            guard let current = targetPane(request, caller: caller) else {
                return failure(request, "pane_not_found", "No matching pane exists in this project.")
            }
            return success(request, startSnapshot(current, caller: caller, worktree: worktree))
        case .disappeared:
            return failure(
                request,
                "agent_not_running",
                KeroAgentWait.startDisappearedMessage
            )
        case .timedOut:
            return failure(
                request,
                "wait_timeout",
                KeroAgentWait.startTimeoutMessage
            )
        }
    }

    private static func promptAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetAgent(request, caller: caller),
              let session = target.session,
              let status = session.agentStatus else {
            return failure(request, "agent_not_found", "No matching agent exists in this project.")
        }
        guard status.phase == .created
                || status.phase == .working
                || status.phase == .idle
                || status.phase == .done else {
            return failure(
                request, "agent_not_ready",
                "\(status.alias) is \(status.phase.rawValue); guarded prompts require created, working, idle, or done. Use +pane send for explicit raw input."
            )
        }
        guard session.isAutomationAgentRunning(kind: status.kind) else {
            return failure(
                request, "agent_not_running",
                "\(status.alias) has exited; start it again before sending a guarded prompt."
            )
        }
        guard let prompt = request.params["text"]?.stringValue,
              !prompt.isEmpty, prompt.utf8.count <= 262_144,
              isSafePromptText(prompt) else {
            return failure(
                request, "invalid_prompt",
                "Prompt text must be non-empty, contain no terminal control characters, and fit within 256 KiB."
            )
        }

        let normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("\n") {
            session.sendCommand("\u{1b}[200~" + normalized + "\u{1b}[201~")
        } else {
            session.sendCommand(normalized)
        }
        session.sendCommand("\r")
        session.markAutomationAgentPrompted()
        return success(request, paneSnapshot(target, caller: caller))
    }

    /// Waits for a provider-reported or process-recognized phase. Observes
    /// `$agentStatus` and sleeps off the main actor; terminal text is never
    /// classified, and `Thread.sleep` is never used here.
    private static func waitForAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) async -> KeroAutomationResponse {
        let spec: KeroAgentWait.Spec
        switch KeroAgentWait.parse(request.params) {
        case .success(let value):
            spec = value
        case .failure(let error):
            return failure(request, "invalid_params", error.message)
        }

        // Same project-scoped resolver as `agent.get`. A guessed pane or
        // alias in another window never appears in this search set.
        guard let target = targetAgent(request, caller: caller),
              let session = target.session
        else {
            return failure(
                request, "agent_not_found",
                "No matching agent exists in this project."
            )
        }

        let observation = KeroAgentWait.phaseUpdates(from: session)
        defer { observation.cancel() }
        let outcome = await KeroAgentWait.race(
            phases: spec.phases,
            timeout: .milliseconds(spec.timeoutMS),
            updates: observation.stream
        )
        switch outcome {
        case .matched:
            guard let current = targetAgent(request, caller: caller) else {
                return failure(
                    request, "agent_not_found",
                    "No matching agent exists in this project."
                )
            }
            return success(request, paneSnapshot(current, caller: caller))
        case .disappeared:
            return failure(
                request, "agent_not_found",
                "No matching agent exists in this project."
            )
        case .timedOut:
            return failure(
                request,
                "wait_timeout",
                KeroAgentWait.timeoutMessage(phases: spec.phases)
            )
        }
    }

    private static func reportAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let session = caller.session else {
            return failure(request, "terminal_required", "The caller is not a terminal pane.")
        }
        guard let name = request.params["state"]?.stringValue,
              let phase = KeroAgentPhase(rawValue: name),
              phase != .created else {
            return failure(
                request, "invalid_params",
                "state must be working, blocked, done, idle, or unknown."
            )
        }
        let reason = request.params["reason"]?.stringValue
        guard reason?.utf8.count ?? 0 <= 4_096 else {
            return failure(request, "invalid_params", "reason is limited to 4 KiB.")
        }
        let sessionID = request.params["sessionID"]?.stringValue
        guard sessionID.map(isValidAgentSessionID) ?? true else {
            return failure(
                request, "invalid_params",
                "sessionID must be 1 to 128 letters, digits, dots, colons, underscores, or hyphens."
            )
        }
        guard session.reportAutomationAgent(
            phase: phase, reason: reason, sessionID: sessionID
        ) else {
            return failure(
                request, "agent_not_recognized",
                "Declare or start an agent in this terminal before reporting its state."
            )
        }
        return success(request, paneSnapshot(caller, caller: caller))
    }

    private static func targetPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> PaneContext? {
        guard let value = request.params["pane_id"] else { return caller }
        guard let string = value.stringValue, let id = UUID(uuidString: string) else {
            return nil
        }
        return projectContexts(caller.project, manager: caller.manager)
            .first { $0.pane.id == id }
    }

    private static func targetAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> PaneContext? {
        if request.params["pane_id"] != nil {
            guard let pane = targetPane(request, caller: caller),
                  pane.session?.agentStatus != nil else { return nil }
            return pane
        }
        if let alias = request.params["alias"]?.stringValue {
            return projectContexts(caller.project, manager: caller.manager).first {
                $0.session?.agentStatus?.alias == alias
            }
        }
        return caller.session?.agentStatus == nil ? nil : caller
    }

    private static func context(forSession id: UUID) -> PaneContext? {
        for manager in TerminalManager.automationManagers {
            for project in manager.projects {
                for tab in project.tabs {
                    for pane in tab.allPanes {
                        guard case .session(let session) = pane.content,
                              session.id == id else { continue }
                        return PaneContext(
                            manager: manager, project: project, tab: tab, pane: pane
                        )
                    }
                }
            }
        }
        return nil
    }

    private static func projectContexts(
        _ project: Project,
        manager: TerminalManager
    ) -> [PaneContext] {
        project.tabs.flatMap { tab in
            tab.allPanes.map {
                PaneContext(manager: manager, project: project, tab: tab, pane: $0)
            }
        }
    }

    private static func startSnapshot(
        _ context: PaneContext,
        caller: PaneContext,
        worktree: KeroAgentWorktree.Checkout?
    ) -> KeroJSONValue {
        guard case .object(var object) = paneSnapshot(context, caller: caller) else {
            return paneSnapshot(context, caller: caller)
        }
        if let worktree {
            object["cwd"] = .string(worktree.path)
            object["worktree"] = .object([
                "path": .string(worktree.path),
                "branch": .string(worktree.branch),
                "attached": .bool(worktree.attached),
            ])
        }
        return .object(object)
    }

    private static func paneSnapshot(
        _ context: PaneContext,
        caller: PaneContext
    ) -> KeroJSONValue {
        let contentKind: String = switch context.pane.content {
        case .session: "terminal"
        case .file: "file"
        case .browser: "browser"
        case .diff: "diff"
        }
        var object: [String: KeroJSONValue] = [
            "project_id": .string(context.project.id.uuidString),
            "project_name": .string(context.project.name),
            "tab_id": .string(context.tab.id.uuidString),
            "pane_id": .string(context.pane.id.uuidString),
            "content": .string(contentKind),
            "title": .string(context.pane.content.title),
            "is_caller": .bool(context.pane.id == caller.pane.id),
            "is_focused": .bool(
                context.manager.selectedProjectID == context.project.id
                    && context.project.selectedTabID == context.tab.id
                    && context.tab.focusedPaneID == context.pane.id
            ),
        ]
        if let session = context.session {
            object["terminal_id"] = .string(session.id.uuidString)
            object["cwd"] = .string(session.currentDirectoryPath)
            object["shell_available"] = .bool(session.isShellAvailableForAutomation)
            object["exited"] = .bool(session.hasExited)
            object["agent"] = session.agentStatus.map(agentSnapshot) ?? .null
        }
        return .object(object)
    }

    private static func agentSnapshot(_ status: KeroAgentStatus) -> KeroJSONValue {
        .object([
            "alias": .string(status.alias),
            "kind": .string(status.kind.rawValue),
            "state": .string(status.phase.rawValue),
            "authority": .string(status.authority.rawValue),
            "reason": .string(status.reason),
            "updated_at": .string(ISO8601DateFormatter().string(from: status.updatedAt)),
            "process_id": status.processID.map { .number(Double($0)) } ?? .null,
            "session_id": status.sessionID.map { .string($0) } ?? .null,
            "unseen": .bool(status.unseen),
        ])
    }

    private static func paneEdge(_ value: String) -> PaneDropEdge? {
        switch value {
        case "left": return .left
        case "right": return .right
        case "top", "up": return .top
        case "bottom", "down": return .bottom
        default: return nil
        }
    }

    private static func stringArray(_ value: KeroJSONValue?) -> [String]? {
        guard let values = value?.arrayValue else { return nil }
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }

    private static func isValidAlias(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    /// Session identifiers become shell arguments on resume, so the charset
    /// stays conservative even though each argument is quoted.
    private static func isValidAgentSessionID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 58 || $0 == 95
        }
    }

    private static func isSafePromptText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value))
                || scalar.value == 0x0A
                || scalar.value == 0x0D
                || scalar.value == 0x09
        }
    }

    private static func isSafeShellArgument(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func success(
        _ request: KeroAutomationRequest,
        _ result: KeroJSONValue
    ) -> KeroAutomationResponse {
        .success(id: request.id, result: result)
    }

    private static func failure(
        _ request: KeroAutomationRequest,
        _ code: String,
        _ message: String
    ) -> KeroAutomationResponse {
        .failure(id: request.id, code: code, message: message)
    }
}
