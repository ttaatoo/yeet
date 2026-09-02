//
//  KeroAgentWorktree.swift
//  kero
//

import Foundation

/// Opt-in isolation for `agent.start`. Creates or attaches a linked worktree
/// (own branch, own cwd) so parallel agents do not share one dirty tree.
/// Files and Git follow that checkout through the existing foreground-job
/// path. Discard and merge stay human Git-panel actions; this is not a
/// sandbox and does not auto-merge.
enum KeroAgentWorktree {
    static let gitExecutable = "/usr/bin/git"
    static let branchPrefix = "yeet/agent/"

    struct Checkout: Equatable, Sendable {
        var path: String
        var branch: String
        var attached: Bool
    }

    struct Listed: Equatable, Sendable {
        var path: String
        var head: String? = nil
        var branch: String? = nil
        var detached: Bool = false
    }

    enum Failure: Equatable, Error, Sendable {
        case gitMissing
        case notRepository
        case invalidBranch
        case addFailed(String)

        var code: String {
            switch self {
            case .gitMissing: return "git_not_found"
            case .notRepository: return "not_a_git_repository"
            case .invalidBranch: return "invalid_params"
            case .addFailed: return "worktree_failed"
            }
        }

        var message: String {
            switch self {
            case .gitMissing:
                return "Git was not found. Install Git to start an agent in its own worktree."
            case .notRepository:
                return "The terminal is not inside a Git repository."
            case .invalidBranch:
                return "The agent alias cannot be used as a Git branch name."
            case .addFailed(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "Git could not create or attach the agent worktree."
                    : trimmed
            }
        }
    }

    nonisolated static func branchName(alias: String) -> String {
        branchPrefix + alias
    }

    nonisolated static func intendedPath(toplevel: String, alias: String) -> String {
        let parent = (toplevel as NSString).deletingLastPathComponent
        let base = (toplevel as NSString).lastPathComponent
        return (parent as NSString).appendingPathComponent("\(base)-yeet-\(alias)")
    }

    /// Source dirt stays in the original checkout. A new `yeet/agent/<alias>`
    /// worktree is a clean HEAD of that branch. Reusing the same alias
    /// attaches the existing checkout, including leftover dirty files. Never
    /// stash, `--force`, or auto-merge.
    nonisolated static func prepare(
        alias: String,
        cwd: String,
        gitExecutable: String = KeroAgentWorktree.gitExecutable
    ) -> Result<Checkout, Failure> {
        guard FileManager.default.isExecutableFile(atPath: gitExecutable) else {
            return .failure(.gitMissing)
        }
        let branch = branchName(alias: alias)
        guard GitRefName.passesLocalFormat(branch) else {
            return .failure(.invalidBranch)
        }
        let directory = (cwd as NSString).standardizingPath
        guard directory.hasPrefix("/") else {
            return .failure(.notRepository)
        }

        let top = runGit(
            ["rev-parse", "--show-toplevel"],
            in: directory,
            executable: gitExecutable
        )
        guard top.status == 0 else {
            return .failure(top.status == 128 ? .notRepository : .addFailed(gitMessage(top)))
        }
        let toplevel = trim(top.stdout)
        guard !toplevel.isEmpty else {
            return .failure(.notRepository)
        }

        let listed = parseList(
            runGit(
                ["worktree", "list", "--porcelain"],
                in: toplevel,
                executable: gitExecutable
            ).stdout
        )
        if let existing = listed.first(where: { $0.branch == branch }) {
            if FileManager.default.fileExists(atPath: existing.path) {
                return .success(Checkout(
                    path: standardizedPath(existing.path),
                    branch: branch,
                    attached: true
                ))
            }
            _ = runGit(["worktree", "prune"], in: toplevel, executable: gitExecutable)
        }

        let path = intendedPath(toplevel: toplevel, alias: alias)
        if listed.contains(where: { $0.path == path && $0.branch != branch }) {
            return .failure(.addFailed(
                "\(path) is already a worktree for a different branch."
            ))
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            return .failure(.addFailed("\(path) already exists."))
        }

        let branchExists = runGit(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            in: toplevel,
            executable: gitExecutable
        ).status == 0
        let args = branchExists
            ? ["worktree", "add", "--", path, branch]
            : ["worktree", "add", "-b", branch, "--", path]
        let added = runGit(args, in: toplevel, executable: gitExecutable)
        guard added.status == 0 else {
            return .failure(.addFailed(gitMessage(added)))
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.addFailed("Git reported success but the worktree is missing."))
        }
        return .success(Checkout(
            path: standardizedPath(path),
            branch: branch,
            attached: false
        ))
    }

    /// Test helper. Production start never removes or merges the worktree.
    nonisolated static func remove(
        path: String,
        in repository: String,
        gitExecutable: String = KeroAgentWorktree.gitExecutable
    ) -> Result<Void, Failure> {
        guard FileManager.default.isExecutableFile(atPath: gitExecutable) else {
            return .failure(.gitMissing)
        }
        let directory = (repository as NSString).standardizingPath
        let removed = runGit(
            ["worktree", "remove", "--force", "--", path],
            in: directory,
            executable: gitExecutable
        )
        _ = runGit(["worktree", "prune"], in: directory, executable: gitExecutable)
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        guard removed.status == 0 || !FileManager.default.fileExists(atPath: path) else {
            return .failure(.addFailed(gitMessage(removed)))
        }
        return .success(())
    }

    nonisolated static func parseList(_ output: String) -> [Listed] {
        var result: [Listed] = []
        var current: Listed?
        func flush() {
            if let current {
                result.append(current)
            }
            current = nil
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("worktree ") {
                flush()
                current = Listed(path: String(line.dropFirst("worktree ".count)))
            } else if line.isEmpty {
                flush()
            } else if current != nil {
                // Optional struct fields must be assigned through `!` so the
                // mutated copy writes back; `current?.head =` is a no-op.
                if line.hasPrefix("HEAD ") {
                    current!.head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    var name = String(line.dropFirst("branch ".count))
                    if name.hasPrefix("refs/heads/") {
                        name = String(name.dropFirst("refs/heads/".count))
                    }
                    current!.branch = name
                } else if line == "detached" {
                    current!.detached = true
                }
            }
        }
        flush()
        return result
    }

    private nonisolated static func runGit(
        _ args: [String],
        in directory: String,
        executable: String
    ) -> (status: Int32, stdout: String, stderr: String) {
        GitStatusModel.runGit(args, in: directory, timeout: 30, executable: executable)
    }

    private nonisolated static func gitMessage(
        _ run: (status: Int32, stdout: String, stderr: String)
    ) -> String {
        [run.stderr, run.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private nonisolated static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Match `GitRepositoryLocator`, which standardizes before walking, so
    /// `/var` and `/private/var` compare as the same checkout.
    private nonisolated static func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
