//
//  JSONRPCStdioClient.swift
//  kero
//

import Foundation

enum JSONRPCID: Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)
}

/// One JSON object per line. Codex `app-server` omits `"jsonrpc":"2.0"`.
enum JSONRPCMessage: Equatable, Sendable {
    case request(id: JSONRPCID, method: String, params: KeroJSONValue?)
    case notification(method: String, params: KeroJSONValue?)
    case response(id: JSONRPCID, result: KeroJSONValue)
    case error(id: JSONRPCID?, code: Int, message: String, data: KeroJSONValue?)
}

enum JSONRPCCodecError: Error, Equatable {
    case emptyLine
    case notAnObject
    case unrecognizedShape
    case invalidID
    case invalidError
}

enum JSONRPCCodec {
    static func decodeLine(_ line: String) throws -> JSONRPCMessage {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JSONRPCCodecError.emptyLine }
        let value = try JSONDecoder().decode(KeroJSONValue.self, from: Data(trimmed.utf8))
        guard case .object(let object) = value else {
            throw JSONRPCCodecError.notAnObject
        }
        let method = object["method"]?.stringValue
        let id = object["id"].flatMap(parseID)
        if object["id"] != nil, id == nil {
            throw JSONRPCCodecError.invalidID
        }
        if let method {
            if let id {
                return .request(id: id, method: method, params: object["params"])
            }
            return .notification(method: method, params: object["params"])
        }
        if let id, let result = object["result"] {
            return .response(id: id, result: result)
        }
        if let errorValue = object["error"] {
            guard case .object(let error) = errorValue,
                  let code = error["code"]?.intValue,
                  let message = error["message"]?.stringValue
            else {
                throw JSONRPCCodecError.invalidError
            }
            return .error(id: id, code: code, message: message, data: error["data"])
        }
        throw JSONRPCCodecError.unrecognizedShape
    }

    static func encodeLine(
        _ message: JSONRPCMessage,
        jsonrpcVersion: String? = nil
    ) throws -> Data {
        var object: [String: KeroJSONValue] = [:]
        if let jsonrpcVersion {
            object["jsonrpc"] = .string(jsonrpcVersion)
        }
        switch message {
        case .request(let id, let method, let params):
            object["id"] = encodeID(id)
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = encodeID(id)
            object["result"] = result
        case .error(let id, let code, let message, let data):
            if let id { object["id"] = encodeID(id) }
            var error: [String: KeroJSONValue] = [
                "code": .number(Double(code)),
                "message": .string(message),
            ]
            if let data { error["data"] = data }
            object["error"] = .object(error)
        }
        var data = try JSONEncoder().encode(KeroJSONValue.object(object))
        data.append(contentsOf: [0x0A])
        return data
    }

    private static func parseID(_ value: KeroJSONValue) -> JSONRPCID? {
        if let number = value.intValue { return .number(number) }
        if let string = value.stringValue { return .string(string) }
        return nil
    }

    private static func encodeID(_ id: JSONRPCID) -> KeroJSONValue {
        switch id {
        case .number(let value): return .number(Double(value))
        case .string(let value): return .string(value)
        }
    }
}

enum JSONRPCClientError: Error, Equatable {
    case closed
    case encodeFailed
    case writeFailed
    case remote(code: Int, message: String)
}

/// Bidirectional JSONL JSON-RPC over two file handles (typically a child's
/// stdin/stdout). I/O stays off the main actor; callers hop decoded messages.
final class JSONRPCStdioClient: @unchecked Sendable {
    private let stdin: FileHandle
    private let stdout: FileHandle
    /// ACP requires `"jsonrpc":"2.0"`. Codex app-server omits the field.
    private let jsonrpcVersion: String?
    private let io = DispatchQueue(label: "sh.yeet.chat.jsonrpc")
    private let lock = NSLock()
    private var nextID = 1
    private var buffer = Data()
    private var closed = false
    private var pending: [JSONRPCID: CheckedContinuation<KeroJSONValue, Error>] = [:]
    private var requestContinuation: AsyncStream<(id: JSONRPCID, method: String, params: KeroJSONValue?)>.Continuation?
    private var notificationContinuation: AsyncStream<(method: String, params: KeroJSONValue?)>.Continuation?

    let inboundRequests: AsyncStream<(id: JSONRPCID, method: String, params: KeroJSONValue?)>
    let notifications: AsyncStream<(method: String, params: KeroJSONValue?)>

    /// `input` is the child's stdin (we write). `output` is the child's stdout (we read).
    init(input: FileHandle, output: FileHandle, jsonrpcVersion: String? = nil) {
        self.stdin = input
        self.stdout = output
        self.jsonrpcVersion = jsonrpcVersion
        var requestContinuation: AsyncStream<(id: JSONRPCID, method: String, params: KeroJSONValue?)>.Continuation?
        var notificationContinuation: AsyncStream<(method: String, params: KeroJSONValue?)>.Continuation?
        inboundRequests = AsyncStream { requestContinuation = $0 }
        notifications = AsyncStream { notificationContinuation = $0 }
        self.requestContinuation = requestContinuation
        self.notificationContinuation = notificationContinuation
        // Blocking reads, not FileHandle.readabilityHandler: that handler
        // needs a run loop and stays silent in XCTest and some Process pipes.
        let reader = Thread { [weak self] in
            self?.readLoop()
        }
        reader.name = "sh.yeet.chat.jsonrpc.reader"
        reader.qualityOfService = .userInitiated
        reader.start()
    }

    private func readLoop() {
        while true {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            if isClosed { return }
            let chunk = stdout.readData(ofLength: 64 * 1024)
            io.sync {
                consume(chunk)
            }
            if chunk.isEmpty { return }
        }
    }

    func send(method: String, params: KeroJSONValue?) async throws -> KeroJSONValue {
        lock.lock()
        let id = JSONRPCID.number(nextID)
        nextID += 1
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                self.lock.lock()
                if self.closed {
                    self.lock.unlock()
                    continuation.resume(throwing: JSONRPCClientError.closed)
                    return
                }
                self.pending[id] = continuation
                self.lock.unlock()
                do {
                    try self.write(.request(id: id, method: method, params: params))
                } catch {
                    self.lock.lock()
                    let pending = self.pending.removeValue(forKey: id)
                    self.lock.unlock()
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    func notify(method: String, params: KeroJSONValue?) throws {
        try io.sync {
            try write(.notification(method: method, params: params))
        }
    }

    func reply(id: JSONRPCID, result: KeroJSONValue) throws {
        try io.sync {
            try write(.response(id: id, result: result))
        }
    }

    func close() {
        io.async {
            self.tearDown(JSONRPCClientError.closed)
        }
    }

    private func write(_ message: JSONRPCMessage) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed { throw JSONRPCClientError.closed }
        let data: Data
        do {
            data = try JSONRPCCodec.encodeLine(message, jsonrpcVersion: jsonrpcVersion)
        } catch {
            throw JSONRPCClientError.encodeFailed
        }
        do {
            try stdin.write(contentsOf: data)
        } catch {
            throw JSONRPCClientError.writeFailed
        }
    }

    private func consume(_ chunk: Data) {
        if chunk.isEmpty {
            tearDown(JSONRPCClientError.closed)
            return
        }
        buffer.append(chunk)
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            do {
                dispatch(try JSONRPCCodec.decodeLine(trimmed))
            } catch {
                continue
            }
        }
    }

    private func dispatch(_ message: JSONRPCMessage) {
        switch message {
        case .response(let id, let result):
            finish(id: id, result: .success(result))
        case .error(let id, let code, let message, _):
            if let id {
                finish(id: id, result: .failure(JSONRPCClientError.remote(code: code, message: message)))
            }
        case .request(let id, let method, let params):
            requestContinuation?.yield((id, method, params))
        case .notification(let method, let params):
            notificationContinuation?.yield((method, params))
        }
    }

    private func finish(id: JSONRPCID, result: Result<KeroJSONValue, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        switch result {
        case .success(let value): continuation?.resume(returning: value)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    private func tearDown(_ error: Error) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        try? stdout.close()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
        requestContinuation?.finish()
        notificationContinuation?.finish()
        requestContinuation = nil
        notificationContinuation = nil
    }
}
