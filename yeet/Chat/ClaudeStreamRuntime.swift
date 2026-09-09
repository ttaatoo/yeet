//
//  ClaudeStreamRuntime.swift
//  kero
//

import Foundation

/// Claude Code print-mode stream-json. stdin stays open so later turns and
/// `can_use_tool` control replies can be written.
@MainActor
final class ClaudeStreamRuntime: ChatRuntime {
    private let launch: ChatLaunch
    private var process: Process?
    private var stdin: FileHandle?
    private var stderrPipe: Pipe?
    private var reader: JSONLLineReader?
    private(set) var threadID: String?
    private(set) var needsLogin = false
    private var started = false
    private var pendingToolInput: [String: KeroJSONValue] = [:]
    private var eventContinuation: AsyncStream<ChatTimelineItem>.Continuation?
    let events: AsyncStream<ChatTimelineItem>
    var displayName: String { KeroAgentKind.claude.displayName }

    init(launch: ChatLaunch) {
        self.launch = launch
        var continuation: AsyncStream<ChatTimelineItem>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func start() async throws {
        if started { return }
        if !Self.looksLoggedIn(executable: launch.executable, path: launch.environmentPath) {
            needsLogin = true
            return
        }
        let spawned = try ChatChildProcess.spawn(launch)
        process = spawned.process
        stdin = spawned.stdin
        stderrPipe = spawned.stderr
        ChatChildProcess.drainStderr(spawned.stderr)
        let reader = JSONLLineReader(handle: spawned.stdout)
        self.reader = reader
        started = true
        try writeControlInitialize()
        forward(reader)
    }

    func startOrResumeThread(cwd: String, threadID: String?) async throws -> String {
        _ = cwd
        if let threadID {
            self.threadID = threadID
            return threadID
        }
        return self.threadID ?? ""
    }

    func startTurn(text: String) async throws {
        guard let stdin else { throw ChatRuntimeError.closed }
        let payload = KeroJSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ]),
        ])
        try ChatChildProcess.writeJSONL(payload, to: stdin)
    }

    func interrupt() async throws {
        guard let stdin else { return }
        let payload = KeroJSONValue.object([
            "type": .string("control_request"),
            "request_id": .string("interrupt-\(UUID().uuidString)"),
            "request": .object(["subtype": .string("interrupt")]),
        ])
        try ChatChildProcess.writeJSONL(payload, to: stdin)
        process?.interrupt()
    }

    func respond(to requestID: JSONRPCID, decision: ChatApprovalDecision) throws {
        guard let stdin else { throw ChatRuntimeError.closed }
        let id: String = {
            switch requestID {
            case .string(let value): return value
            case .number(let value): return String(value)
            }
        }()
        let allowed = decision == .accept || decision == .acceptForSession
        var response: [String: KeroJSONValue] = [
            "behavior": .string(allowed ? "allow" : "deny"),
        ]
        if allowed {
            response["updatedInput"] = pendingToolInput[id] ?? .object([:])
        } else {
            response["message"] = .string("User denied permission for this tool")
        }
        pendingToolInput.removeValue(forKey: id)
        let payload = KeroJSONValue.object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(id),
                "response": .object(response),
            ]),
        ])
        try ChatChildProcess.writeJSONL(payload, to: stdin)
    }

    func shutdown() {
        reader?.close()
        reader = nil
        try? stdin?.close()
        stdin = nil
        ChatChildProcess.terminate(process)
        process = nil
        eventContinuation?.finish()
        eventContinuation = nil
        started = false
    }

    private func writeControlInitialize() throws {
        guard let stdin else { return }
        let payload = KeroJSONValue.object([
            "type": .string("control_request"),
            "request_id": .string("init-1"),
            "request": .object([
                "subtype": .string("initialize"),
                "hooks": .null,
            ]),
        ])
        try ChatChildProcess.writeJSONL(payload, to: stdin)
    }

    private func forward(_ reader: JSONLLineReader) {
        Task { [weak self] in
            var mapper = ClaudeEventMapper()
            for await value in reader.lines {
                guard let self else { return }
                if let object = value.objectValue,
                   object["type"]?.stringValue == "control_request",
                   let requestID = object["request_id"]?.stringValue {
                    self.pendingToolInput[requestID] =
                        object["request"]?.objectValue?["input"] ?? .object([:])
                }
                let items = mapper.push(value)
                if let sessionID = mapper.sessionID, self.threadID != sessionID {
                    self.threadID = sessionID
                }
                for item in items {
                    self.eventContinuation?.yield(item)
                }
            }
        }
    }

    static func looksLoggedIn(executable: String, path: String) -> Bool {
        let result = ChatChildProcess.run(
            executable: executable,
            arguments: ["auth", "status"],
            environmentPath: path
        )
        return result.status == 0
    }
}

/// Blocking JSONL reader for Claude stream-json (not JSON-RPC).
final class JSONLLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let io = DispatchQueue(label: "sh.yeet.chat.jsonl")
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var continuation: AsyncStream<KeroJSONValue>.Continuation?
    let lines: AsyncStream<KeroJSONValue>

    init(handle: FileHandle) {
        self.handle = handle
        var continuation: AsyncStream<KeroJSONValue>.Continuation?
        lines = AsyncStream { continuation = $0 }
        self.continuation = continuation
        let reader = Thread { [weak self] in
            self?.readLoop()
        }
        reader.name = "sh.yeet.chat.jsonl.reader"
        reader.qualityOfService = .userInitiated
        reader.start()
    }

    func close() {
        io.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.closed = true
            self.lock.unlock()
            try? self.handle.close()
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    private func readLoop() {
        while true {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            if isClosed { return }
            let chunk = handle.readData(ofLength: 64 * 1024)
            io.sync { consume(chunk) }
            if chunk.isEmpty { return }
        }
    }

    private func consume(_ chunk: Data) {
        if chunk.isEmpty {
            continuation?.finish()
            continuation = nil
            return
        }
        buffer.append(chunk)
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { continue }
            if let value = try? JSONDecoder().decode(KeroJSONValue.self, from: Data(trimmed.utf8)) {
                continuation?.yield(value)
            }
        }
    }
}
