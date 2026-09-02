//
//  GitRepositoryLocator.swift
//  kero
//

import Foundation

/// Walks ancestors looking for `.git`. Results are cached so the file tree
/// and git panel do not repeat the same climb on every refresh. A dead
/// volume must not hang the walk forever — each existence check is timed.
enum GitRepositoryLocator {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String?] = [:]

    /// The directory of the nearest enclosing git repository: a `.git`
    /// directory in a normal checkout, or a `.git` file in a worktree.
    nonisolated static func closestGitRepository(containing path: String) -> String? {
        var dir = (path as NSString).standardizingPath
        guard dir.hasPrefix("/") else { return nil }

        var walked: [String] = []
        while true {
            if let cached = locked({ cache[dir] }) {
                let root = cached
                remember(walked, root: root)
                return root
            }
            walked.append(dir)
            if TimedFileIO.fileExists(
                atPath: (dir as NSString).appendingPathComponent(".git")
            ) {
                remember(walked, root: dir)
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir {
                remember(walked, root: nil)
                return nil
            }
            dir = parent
        }
    }

    /// Whether `root` is a linked worktree rather than a normal checkout.
    nonisolated static func isLinkedWorktree(_ root: String) -> Bool {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        guard let info = TimedFileIO.fileExists(atPath: gitPath),
              info.exists, !info.isDirectory,
              let contents = try? String(contentsOfFile: gitPath, encoding: .utf8)
        else { return false }
        return contents.contains("/worktrees/")
    }

    nonisolated static func invalidate() {
        locked { cache.removeAll(keepingCapacity: true) }
    }

    private nonisolated static func remember(_ paths: [String], root: String?) {
        locked {
            for path in paths {
                cache[path] = root
            }
        }
    }

    private nonisolated static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
