//
//  ACPChatRuntime.swift
//  kero
//

import Foundation

/// Grok (`grok agent stdio`) and other ACP JSON-RPC agents.
@MainActor
final class ACPChatRuntime: ChatRuntime {
    let kind: KeroAgentKind
    private let launch: ChatLaunch
    private var process: Process?
    private var client: JSONRPCStdioClient?
    private var stderrPipe: Pipe?
    private(set) var threadID: String?
    private(set) var needsLogin = false
    private var started = false
    private var pendingPermissionOptions: [JSONRPCID: [KeroJSONValue]] = [:]
    private var eventContinuation: AsyncStream<ChatTimelineItem>.Continuation?
    let events: AsyncStream<ChatTimelineItem>
    var displayName: String { kind.displayName }

    init(kind: KeroAgentKind, launch: ChatLaunch) {
        self.kind = kind
        self.launch = launch
        var continuation: AsyncStream<ChatTimelineItem>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func start() async throws {
        if started { return }
        if kind == .grok, !Self.grokLooksLoggedIn(path: launch.environmentPath, executable: launch.executable) {
            needsLogin = true
            return
        }
        let spawned = try ChatChildProcess.spawn(launch)
        process = spawned.process
        stderrPipe = spawned.stderr
        ChatChildProcess.drainStderr(spawned.stderr)
        let client = JSONRPCStdioClient(
            input: spawned.stdin,
            output: spawned.stdout,
            jsonrpcVersion: "2.0"
        )
        self.client = client
        try await handshake(client)
        started = true
        forward(client)
    }

    func startOrResumeThread(cwd: String, threadID: String?) async throws -> String {
        let client = try requireClient()
        if let threadID {
            do {
                _ = try await client.send(
                    method: "session/load",
                    params: .object([
                        "sessionId": .string(threadID),
                        "cwd": .string(cwd),
                        "mcpServers": .array([]),
                    ])
                )
                self.threadID = threadID
                return threadID
            } catch {
                // Fall through to a new session when the id is gone.
            }
        }
        let result = try await client.send(
            method: "session/new",
            params: .object([
                "cwd": .string(cwd),
                "mcpServers": .array([]),
            ])
        )
        let id = result.objectValue?["sessionId"]?.stringValue
        guard let id else {
            throw ChatRuntimeError.spawnFailed("session/new returned no sessionId")
        }
        self.threadID = id
        return id
    }

    func startTurn(text: String) async throws {
        let client = try requireClient()
        guard let threadID else { throw ChatRuntimeError.notInitialized }
        _ = try await client.send(
            method: "session/prompt",
            params: .object([
                "sessionId": .string(threadID),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ])
        )
        eventContinuation?.yield(.turnFinished(id: threadID))
    }

    func interrupt() async throws {
        let client = try requireClient()
        guard let threadID else { return }
        try client.notify(
            method: "session/cancel",
            params: .object(["sessionId": .string(threadID)])
        )
        for id in pendingPermissionOptions.keys {
            try? client.reply(
                id: id,
                result: ACPEventMapper.permissionResult(.cancel, options: [])
            )
        }
        pendingPermissionOptions.removeAll()
    }

    func respond(to requestID: JSONRPCID, decision: ChatApprovalDecision) throws {
        let client = try requireClient()
        let options = pendingPermissionOptions.removeValue(forKey: requestID) ?? []
        try client.reply(
            id: requestID,
            result: ACPEventMapper.permissionResult(decision, options: options)
        )
    }

    func shutdown() {
        client?.close()
        client = nil
        ChatChildProcess.terminate(process)
        process = nil
        eventContinuation?.finish()
        eventContinuation = nil
        started = false
    }

    private func handshake(_ client: JSONRPCStdioClient) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0"
        _ = try await client.send(
            method: "initialize",
            params: .object([
                "protocolVersion": .number(1),
                "clientInfo": .object([
                    "name": .string("yeet"),
                    "title": .string("Yeet"),
                    "version": .string(version),
                ]),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(false),
                        "writeTextFile": .bool(false),
                    ]),
                    "terminal": .bool(false),
                ]),
            ])
        )
        if kind == .grok {
            let methodId = ProcessInfo.processInfo.environment["XAI_API_KEY"] == nil
                ? "cached_token"
                : "xai.api_key"
            do {
                _ = try await client.send(
                    method: "authenticate",
                    params: .object(["methodId": .string(methodId)])
                )
            } catch {
                needsLogin = true
                throw error
            }
        }
    }

    private func forward(_ client: JSONRPCStdioClient) {
        Task { [weak self] in
            var mapper = ACPEventMapper()
            for await notification in client.notifications {
                guard let self else { return }
                for item in mapper.applyNotification(
                    method: notification.method,
                    params: notification.params
                ) {
                    self.eventContinuation?.yield(item)
                }
            }
        }
        Task { [weak self] in
            var mapper = ACPEventMapper()
            for await request in client.inboundRequests {
                guard let self else { return }
                if request.method == "session/request_permission" {
                    let options = request.params?.objectValue?["options"]?.arrayValue ?? []
                    self.pendingPermissionOptions[request.id] = options
                    self.eventContinuation?.yield(
                        mapper.applyPermissionRequest(id: request.id, params: request.params)
                    )
                }
            }
        }
    }

    private func requireClient() throws -> JSONRPCStdioClient {
        guard let client else { throw ChatRuntimeError.closed }
        return client
    }

    static func grokLooksLoggedIn(path: String, executable: String) -> Bool {
        if ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil { return true }
        let result = ChatChildProcess.run(
            executable: executable,
            arguments: ["models"],
            environmentPath: path
        )
        let text = result.stdout.lowercased()
        if text.contains("not authenticated") || text.contains("not logged in") {
            return false
        }
        if text.contains("you are logged in") { return true }
        let auth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        return FileManager.default.fileExists(atPath: auth.path)
    }
}
