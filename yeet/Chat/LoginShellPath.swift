//
//  LoginShellPath.swift
//  kero
//

import Darwin
import Foundation

/// PATH a GUI-spawned process would miss: launchd often has no Homebrew.
/// A login shell (`zsh -l`) sources zprofile and returns the user's PATH.
/// Interactive `-i` is intentionally omitted — rc files can prompt and hang.
enum LoginShellPath {
    private static let lock = NSLock()
    private static var cached: String?

    /// Login-shell PATH, cached for the process. Falls back to
    /// `ProcessInfo.processInfo.environment["PATH"]` on timeout or failure.
    static func resolved(timeout: TimeInterval = 2) -> String {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = probe(timeout: timeout)
        lock.lock()
        cached = value
        lock.unlock()
        return value
    }

    private static func probe(timeout: TimeInterval) -> String {
        let fallback = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return fallback
        }

        final class PipeBytes: @unchecked Sendable {
            var value = Data()
        }
        let outData = PipeBytes()
        let readers = DispatchGroup()
        readers.enter()
        Thread {
            outData.value = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }.start()
        readers.enter()
        Thread {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }.start()

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        readers.wait()
        guard !timedOut, process.terminationStatus == 0 else { return fallback }
        let output = String(data: outData.value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? fallback : output
    }
}
