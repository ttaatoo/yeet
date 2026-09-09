//
//  CodexAppServer.swift
//  kero
//

import Darwin
import Foundation

struct CodexLaunch: Equatable, Sendable {
    var executable: String
    var arguments: [String] = ["app-server"]
    var currentDirectory: String
    var environmentPath: String
}

enum CodexAppServerError: Error, Equatable {
    case missingExecutable
    case spawnFailed(String)
    case notInitialized
    case needsLogin
    case closed
}

/// Long-lived `codex app-server` child. Pipes, not a PTY. Does not inject
/// `YEET_AUTOMATION*` so Codex hooks cannot `agent.report` without a terminal.
@MainActor
final class CodexAppServer: ChatRuntime {
    var displayName: String { KeroAgentKind.codex.displayName }
    private let launch: CodexLaunch
    private var process: Process?
    private var client: JSONRPCStdioClient?
    private var stderrPipe: Pipe?
    private(set) var threadID: String?
    private(set) var turnID: String?
    private(set) var accountEmail: String?
    private(set) var needsLogin = false
    private var started = false

    private var eventContinuation: AsyncStream<ChatTimelineItem>.Continuation?
    let events: AsyncStream<ChatTimelineItem>

    init(launch: CodexLaunch) {
        self.launch = launch
        var continuation: AsyncStream<ChatTimelineItem>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func start() async throws {
        if started { return }
        guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
            throw CodexAppServerError.missingExecutable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.currentDirectory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = launch.environmentPath
        environment["HOME"] = NSHomeDirectory()
        environment["TERM"] = "dumb"
        environment.removeValue(forKey: "YEET_AUTOMATION")
        environment.removeValue(forKey: "YEET_AUTOMATION_SOCKET")
        environment.removeValue(forKey: "YEET_AUTOMATION_TOKEN")
        environment.removeValue(forKey: "YEET_TERMINAL_ID")
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw CodexAppServerError.spawnFailed(error.localizedDescription)
        }
        self.process = process
        self.stderrPipe = stderr
        let client = JSONRPCStdioClient(
            input: stdin.fileHandleForWriting,
            output: stdout.fileHandleForReading
        )
        self.client = client
        drainStderr(stderr)
        try await handshake(client)
        started = true
        forward(client)
    }

    func startThread(cwd: String) async throws -> String {
        let client = try requireClient()
        let result = try await client.send(
            method: "thread/start",
            params: .object(supervisedThreadParams(cwd: cwd))
        )
        let id = result.objectValue?["thread"]?.objectValue?["id"]?.stringValue
            ?? result.objectValue?["id"]?.stringValue
        guard let id else {
            throw CodexAppServerError.spawnFailed("thread/start returned no thread id")
        }
        threadID = id
        return id
    }

    func resumeThread(threadID: String, cwd: String) async throws {
        let client = try requireClient()
        var params = supervisedThreadParams(cwd: cwd)
        params["threadId"] = .string(threadID)
        _ = try await client.send(method: "thread/resume", params: .object(params))
        self.threadID = threadID
    }

    func startOrResumeThread(cwd: String, threadID: String?) async throws -> String {
        if let threadID {
            do {
                try await resumeThread(threadID: threadID, cwd: cwd)
                return threadID
            } catch {
                return try await startThread(cwd: cwd)
            }
        }
        return try await startThread(cwd: cwd)
    }

    func startTurn(text: String) async throws {
        _ = try await startTurnReturningID(text)
    }

    func startTurnReturningID(_ text: String) async throws -> String {
        let client = try requireClient()
        guard let threadID else { throw CodexAppServerError.notInitialized }
        let result = try await client.send(
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
                "approvalPolicy": .string("untrusted"),
                "sandboxPolicy": .object(["type": .string("readOnly")]),
            ])
        )
        let id = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue ?? UUID().uuidString
        turnID = id
        return id
    }

    func interrupt() async throws {
        let client = try requireClient()
        guard let threadID else { return }
        var params: [String: KeroJSONValue] = ["threadId": .string(threadID)]
        if let turnID { params["turnId"] = .string(turnID) }
        _ = try await client.send(method: "turn/interrupt", params: .object(params))
    }

    func respond(to requestID: JSONRPCID, decision: ChatApprovalDecision) throws {
        let client = try requireClient()
        try client.reply(
            id: requestID,
            result: .object(["decision": .string(decision.rawValue)])
        )
    }

    func shutdown() {
        client?.close()
        client = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [pid = process.processIdentifier] in
                if process.isRunning {
                    Darwin.kill(pid, SIGKILL)
                }
            }
        }
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
                "clientInfo": .object([
                    "name": .string("yeet"),
                    "title": .string("Yeet"),
                    "version": .string(version),
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true),
                ]),
            ])
        )
        try client.notify(method: "initialized", params: .object([:]))
        let account = try await client.send(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )
        let object = account.objectValue ?? [:]
        let accountInfo = object["account"]
        let loggedIn: Bool = {
            if accountInfo == nil || accountInfo == .null { return false }
            return true
        }()
        accountEmail = accountInfo?.objectValue?["email"]?.stringValue
        let requiresAuth = object["requiresOpenaiAuth"]?.boolValue ?? true
        needsLogin = !loggedIn && requiresAuth
    }

    private func forward(_ client: JSONRPCStdioClient) {
        Task { [weak self] in
            var mapper = CodexEventMapper()
            for await notification in client.notifications {
                guard let self else { return }
                let line: String
                do {
                    let data = try JSONRPCCodec.encodeLine(
                        .notification(method: notification.method, params: notification.params)
                    )
                    line = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    continue
                }
                let items = (try? mapper.push(line: line)) ?? []
                for item in items {
                    self.eventContinuation?.yield(item)
                }
            }
        }
        Task { [weak self] in
            var mapper = CodexEventMapper()
            for await request in client.inboundRequests {
                guard let self else { return }
                let line: String
                do {
                    let data = try JSONRPCCodec.encodeLine(
                        .request(id: request.id, method: request.method, params: request.params)
                    )
                    line = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    continue
                }
                let items = (try? mapper.push(line: line)) ?? []
                for item in items {
                    self.eventContinuation?.yield(item)
                }
            }
        }
    }

    private func drainStderr(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async {
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
        }
    }

    private func requireClient() throws -> JSONRPCStdioClient {
        guard let client else { throw CodexAppServerError.closed }
        return client
    }

    private func supervisedThreadParams(cwd: String) -> [String: KeroJSONValue] {
        [
            "cwd": .string(cwd),
            "approvalPolicy": .string("untrusted"),
            "sandbox": .string("read-only"),
            "approvalsReviewer": .string("user"),
        ]
    }
}
