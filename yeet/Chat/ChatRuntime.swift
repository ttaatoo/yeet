//
//  ChatRuntime.swift
//  kero
//

import Darwin
import Foundation

enum ChatRuntimeError: Error, Equatable {
    case missingExecutable
    case spawnFailed(String)
    case notInitialized
    case closed
}

/// One local CLI session behind a chat pane. Codex, Claude, and Grok each
/// implement this; the pane never talks HTTP or scrapes a TUI.
@MainActor
protocol ChatRuntime: AnyObject {
    var events: AsyncStream<ChatTimelineItem> { get }
    var threadID: String? { get }
    var needsLogin: Bool { get }
    var displayName: String { get }
    func start() async throws
    func startOrResumeThread(cwd: String, threadID: String?) async throws -> String
    func startTurn(text: String) async throws
    func interrupt() async throws
    func respond(to requestID: JSONRPCID, decision: ChatApprovalDecision) throws
    func shutdown()
}

struct ChatLaunch: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var currentDirectory: String
    var environmentPath: String
}

enum ChatChildProcess {
    static func spawn(_ launch: ChatLaunch) throws -> (
        process: Process,
        stdin: FileHandle,
        stdout: FileHandle,
        stderr: Pipe
    ) {
        guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
            throw ChatRuntimeError.missingExecutable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: launch.currentDirectory, isDirectory: true
        )
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
            throw ChatRuntimeError.spawnFailed(error.localizedDescription)
        }
        return (
            process,
            stdin.fileHandleForWriting,
            stdout.fileHandleForReading,
            stderr
        )
    }

    static func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            [pid = process.processIdentifier] in
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    static func drainStderr(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async {
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
        }
    }

    static func writeJSONL(_ value: KeroJSONValue, to handle: FileHandle) throws {
        var data = try JSONEncoder().encode(value)
        data.append(contentsOf: [0x0A])
        try handle.write(contentsOf: data)
    }

    static func run(
        executable: String,
        arguments: [String],
        environmentPath: String,
        timeout: TimeInterval = 8
    ) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environmentPath
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        final class Box: @unchecked Sendable { var value = Data() }
        let out = Box()
        let group = DispatchGroup()
        group.enter()
        Thread {
            out.value = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }.start()
        group.enter()
        Thread {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }.start()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        group.wait()
        return (
            process.terminationStatus,
            String(data: out.value, encoding: .utf8) ?? ""
        )
    }
}

enum ChatRuntimeFactory {
    @MainActor
    static func make(
        kind: KeroAgentKind,
        executable: String,
        currentDirectory: String,
        environmentPath: String,
        resumeID: String? = nil
    ) -> ChatRuntime {
        var args = arguments(for: kind)
        if kind == .claude, let resumeID, !resumeID.isEmpty {
            args.append("--resume=\(resumeID)")
        }
        let launch = ChatLaunch(
            executable: executable,
            arguments: args,
            currentDirectory: currentDirectory,
            environmentPath: environmentPath
        )
        switch kind {
        case .codex:
            return CodexAppServer(launch: CodexLaunch(
                executable: executable,
                currentDirectory: currentDirectory,
                environmentPath: environmentPath
            ))
        case .grok:
            return ACPChatRuntime(kind: .grok, launch: launch)
        case .claude:
            return ClaudeStreamRuntime(launch: launch)
        default:
            return ACPChatRuntime(kind: kind, launch: launch)
        }
    }

    static func arguments(for kind: KeroAgentKind) -> [String] {
        switch kind {
        case .codex:
            return ["app-server"]
        case .grok:
            // Supervised: ask before commands and file changes.
            return ["--permission-mode", "default", "agent", "stdio"]
        case .claude:
            return [
                "-p",
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--permission-mode", "default",
            ]
        default:
            return []
        }
    }
}
