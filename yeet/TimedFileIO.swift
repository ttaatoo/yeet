//
//  TimedFileIO.swift
//  kero
//

import Foundation

/// Filesystem calls that must not hang the UI on a dead volume. Matches the
/// Git runner's idea of a bounded wait: the work still runs on a helper
/// thread, but the caller gives up after `timeout`.
nonisolated enum TimedFileIO {
    /// Same order of magnitude as a Git status snapshot, so a wedged NFS
    /// mount cannot pin the file tree forever. `nonisolated` because the
    /// project defaults every type to the main actor, and the directory
    /// helpers below run off it.
    nonisolated static let defaultTimeout: TimeInterval = 8

    nonisolated static func contentsOfDirectory(
        atPath path: String,
        timeout: TimeInterval = defaultTimeout
    ) -> [String]? {
        run(timeout: timeout) {
            try? FileManager.default.contentsOfDirectory(atPath: path)
        } ?? nil
    }

    /// Names, paths, and directory-ness for one folder in a single helper-thread
    /// hop. The file tree used to call `fileExists` per child (a GCD hop and
    /// 8s wait each). Hidden files are included; `.git` filtering stays with
    /// the caller. A symlink-to-directory still counts as a directory because
    /// `fileExists` follows it, matching the old per-child check.
    nonisolated static func contentsOfDirectoryEntries(
        atPath path: String,
        timeout: TimeInterval = defaultTimeout
    ) -> [(name: String, path: String, isDirectory: Bool)]? {
        run(timeout: timeout) { () -> [(name: String, path: String, isDirectory: Bool)]? in
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            ) else {
                return nil
            }
            return urls.map { url in
                let name = url.lastPathComponent
                let childPath = (path as NSString).appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: Set(keys))
                var isDirectory = values?.isDirectory ?? false
                if values?.isSymbolicLink == true {
                    var isDir: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: childPath, isDirectory: &isDir)
                    isDirectory = isDir.boolValue
                }
                return (name: name, path: childPath, isDirectory: isDirectory)
            }
        } ?? nil
    }

    nonisolated static func fileExists(
        atPath path: String,
        timeout: TimeInterval = defaultTimeout
    ) -> (exists: Bool, isDirectory: Bool)? {
        run(timeout: timeout) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return (exists, isDirectory.boolValue)
        }
    }

    nonisolated static func fileExists(atPath path: String) -> Bool {
        fileExists(atPath: path)?.exists ?? false
    }

    private nonisolated static func run<T>(
        timeout: TimeInterval,
        _ work: @escaping @Sendable () -> T
    ) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            return nil
        }
        return box.value
    }

    private nonisolated final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}
