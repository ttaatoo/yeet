//
//  GitStatusModel.swift
//  kero
//

import Combine
import Darwin
import Dispatch
import Foundation

/// Loads repository state in response to explicit UI events and performs
/// source-control operations without blocking the UI.
@MainActor
final class GitStatusModel: nonisolated ObservableObject {
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        var id: String { path }
        /// Relative to the repository root, as porcelain v2 reports it.
        let path: String
        /// Index (staged) status letter, "." when clean, "?" for untracked.
        let staged: Character
        /// Worktree (unstaged) status letter.
        let unstaged: Character
        var isConflict = false
        /// Previous path for renames/copies (porcelain "2" entries).
        var origPath: String?
        /// Canonical repo that produced this snapshot. Mutations reject stale
        /// rows after the active terminal moves to another repository.
        var repositoryRoot = ""

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
        /// Intent-to-add (`git add -N`) is represented as `.A`; restoring it
        /// from the empty index blob would truncate user content, so destructive
        /// handling treats it like an untracked file and uses the Trash.
        var isIntentToAdd: Bool { staged == "." && unstaged == "A" }
        var isUntracked: Bool { staged == "?" || isIntentToAdd }
        var isWorktreeRename: Bool { unstaged == "R" && origPath != nil }
        var isWorktreeCopy: Bool { unstaged == "C" && origPath != nil }

        // A file can sit in two sections at once (for example, "MM"). Rows in
        // the same lazy stack need distinct identities or SwiftUI drops one.
        var mergeRowID: String { "merge/" + path }
        var stagedRowID: String { "staged/" + path }
        var changedRowID: String { "changed/" + path }
    }

    /// Compact Explorer-style decoration for a path in the active repository.
    /// The file tree maps these semantic states to both a color and a visible
    /// status badge, so color is never the only indication.
    nonisolated enum FileDecoration: Equatable, Sendable {
        case modified
        case added
        case untracked
        case deleted
        case renamed
        case copied
        case conflict
        case ignored

        /// When a directory contains several changed files, bubble up the
        /// state that most needs attention.
        var directoryPriority: Int {
            switch self {
            case .conflict: 8
            case .deleted: 7
            case .modified: 6
            case .added: 5
            case .untracked: 4
            case .renamed: 3
            case .copied: 2
            case .ignored: 1
            }
        }
    }

    nonisolated struct RecentCommit: Identifiable, Equatable, Sendable {
        nonisolated struct FileChange: Identifiable, Equatable, Sendable {
            let status: Character
            let path: String
            let originalPath: String?

            var id: String {
                "\(status)\u{0}\(originalPath ?? "")\u{0}\(path)"
            }
            var fileName: String { (path as NSString).lastPathComponent }
            var directory: String {
                let dir = (path as NSString).deletingLastPathComponent
                return dir.isEmpty ? "" : dir
            }
        }

        var id: String { hash }
        let hash: String
        let shortHash: String
        let subject: String
        let author: String
        let date: Date
        let parentHash: String?
        let references: [String]
        let files: [FileChange]

        var relativeDate: String {
            date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
    }

    nonisolated struct Operation: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case running
            case succeeded
            case failed(exitCode: Int32)
        }

        let id: UUID
        let label: String
        var state: State
        var output: String
        let startedAt: Date
        var finishedAt: Date?

        var isRunning: Bool { state == .running }
        var isSuccess: Bool { state == .succeeded }

        var statusLabel: String {
            switch state {
            case .running:
                return String(localized: "\(label)…", comment: "A Git operation that is still running.")
            case .succeeded:
                return String(localized: "\(label) completed", comment: "A Git operation that completed successfully.")
            case .failed:
                return String(localized: "\(label) failed", comment: "A Git operation that failed.")
            }
        }
    }

    private(set) var rootPath = ""
    /// Stable canonical repository root, used by the UI to key drafts. It is
    /// preserved while a cwd change is being resolved inside the same repo.
    private(set) var repositoryIdentity = ""
    private(set) var isRepo = false
    private(set) var fileDecorations: [String: FileDecoration] = [:]
    /// Highest-priority decoration for each ancestor directory of a changed
    /// file. Built once per refresh so the file tree is O(depth), not O(n×m).
    private var directoryDecorations: [String: FileDecoration] = [:]
    /// Ignored directories without the trailing slash porcelain uses.
    private var ignoredDirectories: [String] = []
    /// Relative porcelain paths. Directory records retain their trailing slash
    /// so expanded descendants can inherit the ignored state.
    private(set) var ignoredPaths: Set<String> = []
    private(set) var branch: String?
    private(set) var headOID: String?
    private(set) var hasHead = true
    private(set) var upstream: String?
    private(set) var ahead = 0
    private(set) var behind = 0
    private(set) var hasUpstream = false
    private(set) var lineAdditions = 0
    private(set) var lineDeletions = 0
    private(set) var mergeEntries: [Entry] = []
    private(set) var stagedEntries: [Entry] = []
    private(set) var changedEntries: [Entry] = []
    private(set) var branches: [String] = []
    private(set) var defaultBranch: String?
    private(set) var remotes: [String] = []
    private(set) var recentCommits: [RecentCommit] = []
    private(set) var hasMoreRecentCommits = false
    private(set) var isLoadingMoreCommits = false
    private(set) var repositoryOperation: String?
    private(set) var stashCount = 0
    private(set) var isRefreshing = false
    /// True once a status load has completed for the current `rootPath`. The
    /// UI keeps showing resolved content during later event-driven refreshes
    /// instead of flashing a loading placeholder.
    private(set) var hasResolvedStatus = false
    private(set) var statusError: String?
    /// True while a user-initiated Git operation runs.
    private(set) var isBusy = false
    private(set) var operation: Operation?
    var lastError: String?
    /// UI state is not `@Published`; one send per transaction.
    private lazy var changeBatch = ObjectChangeBatch(objectWillChange)

    /// Absolute repository root. Porcelain paths are relative to this path,
    /// not necessarily to the terminal's current working directory.
    private var topLevel = ""
    /// Invalidates async refreshes and operations after the terminal changes cwd.
    private var contextGeneration: UInt = 0
    /// Restores a previously resolved directory immediately when switching
    /// tabs. Without this, every return to a repository clears `isRepo` until
    /// the asynchronous Git refresh finishes, briefly removing the toolbar
    /// and resizing the terminal through the wrong height.
    private var cachedStatusByRoot: [String: StatusLoadResult] = [:]
    /// Invalidates an in-flight status refresh when a mutation begins, so its
    /// pre-operation snapshot cannot overwrite the post-operation state.
    private var statusRequestID: UInt = 0
    /// Coalesces an event that arrives while another refresh or mutation is
    /// running. Without polling, dropping that event could leave the snapshot
    /// stale indefinitely.
    private var refreshPending = false
    private static let recentCommitPageSize = 30
    private var recentCommitLimit = recentCommitPageSize
    private var recentCommitLimitByRoot: [String: Int] = [:]
    /// Keeps a mutation globally exclusive even if the terminal changes cwd
    /// while its Git process is still running.
    private var runningOperationID: UUID?
    var totalChangeCount: Int {
        mergeEntries.count + stagedEntries.count + changedEntries.count
    }

    /// Distinct paths across merge / staged / unstaged / untracked rows.
    /// `totalChangeCount` can count one file twice when it is both staged
    /// and unstaged; review chrome uses this unique count instead.
    var uniqueDirtyPathCount: Int {
        var paths = Set<String>()
        paths.reserveCapacity(mergeEntries.count + stagedEntries.count + changedEntries.count)
        for entry in mergeEntries { paths.insert(entry.path) }
        for entry in stagedEntries { paths.insert(entry.path) }
        for entry in changedEntries { paths.insert(entry.path) }
        return paths.count
    }

    /// True while the first status load for the current directory is still in
    /// flight, so later event-driven refreshes do not replace resolved content
    /// with a loading state.
    var isResolvingInitialStatus: Bool {
        isRefreshing && !hasResolvedStatus
    }

    var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    func isCurrent(_ entry: Entry) -> Bool {
        entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot
    }

    /// Returns a Git decoration only when `absolutePath` belongs to the
    /// currently resolved repository. Plain folders therefore keep the normal
    /// file-tree appearance, even when their names resemble ignored paths.
    func fileDecoration(for absolutePath: String, isDirectory: Bool) -> FileDecoration? {
        guard isRepo, !topLevel.isEmpty else { return nil }
        let repositoryPath = (topLevel as NSString).standardizingPath
        let itemPath = (absolutePath as NSString).standardizingPath
        let relativePath: String
        if itemPath == repositoryPath {
            relativePath = ""
        } else {
            let prefix = repositoryPath + "/"
            guard itemPath.hasPrefix(prefix) else { return nil }
            relativePath = String(itemPath.dropFirst(prefix.count))
        }

        if let decoration = fileDecorations[relativePath] {
            return decoration
        }
        if ignoredPaths.contains(relativePath) { return .ignored }
        for directory in ignoredDirectories where
            relativePath == directory || relativePath.hasPrefix(directory + "/")
        {
            return .ignored
        }
        guard isDirectory, !relativePath.isEmpty else { return nil }
        return directoryDecorations[relativePath]
    }

    /// Walks each changed path's ancestors once so later directory lookups
    /// are a dictionary hit instead of scanning every dirty file.
    nonisolated static func rolledUpDirectoryDecorations(
        _ fileDecorations: [String: FileDecoration]
    ) -> [String: FileDecoration] {
        var directories: [String: FileDecoration] = [:]
        for (path, decoration) in fileDecorations {
            var dir = (path as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                if let existing = directories[dir] {
                    if decoration.directoryPriority > existing.directoryPriority {
                        directories[dir] = decoration
                    }
                } else {
                    directories[dir] = decoration
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        return directories
    }

    /// Git paths are byte-oriented, while Swift strings compare canonically
    /// equivalent Unicode spellings as equal. Keep the original entries for
    /// Git operations, but merge their file-tree projection deterministically
    /// instead of trapping when two paths compare equal as dictionary keys.
    nonisolated static func fileDecorations(
        for entries: [Entry]
    ) -> [String: FileDecoration] {
        Dictionary(
            entries.map { ($0.path, Self.fileDecoration(for: $0)) },
            uniquingKeysWith: { current, candidate in
                candidate.directoryPriority > current.directoryPriority
                    ? candidate
                    : current
            }
        )
    }

    func sync(root: String) {
        changeBatch.perform {
            if root != rootPath {
                contextGeneration &+= 1
                rootPath = root
                recentCommitLimit = recentCommitLimitByRoot[root]
                    ?? Self.recentCommitPageSize
                hasResolvedStatus = false
                clearRepositoryState(preserveIdentity: true)
                if let cachedStatus = cachedStatusByRoot[root] {
                    apply(cachedStatus)
                    hasResolvedStatus = true
                }
            }
            refresh()
        }
    }

    func refresh() {
        let root = rootPath
        let generation = contextGeneration
        let commitLimit = recentCommitLimit
        guard !root.isEmpty else { return }
        guard !isRefreshing, !isBusy else {
            refreshPending = true
            return
        }
        refreshPending = false
        statusRequestID &+= 1
        let requestID = statusRequestID
        changeBatch.perform { isRefreshing = true }

        // This is deliberately independent of the worker. Even filesystem
        // metadata calls can become uninterruptible on a disconnected volume;
        // the sidebar must still leave its initial loading state and offer a
        // retry while the stale worker winds down in the background.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self,
                  self.isRefreshing,
                  self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            afterViewUpdate {
                guard self.isRefreshing,
                      self.contextGeneration == generation,
                      self.statusRequestID == requestID,
                      self.rootPath == root else { return }
                self.changeBatch.perform {
                    self.statusRequestID &+= 1
                    self.isRefreshing = false
                    self.isLoadingMoreCommits = false
                    self.refreshPending = false
                    self.apply(.failed(String(localized: "Git did not respond in time.")))
                    self.hasResolvedStatus = true
                }
            }
        }

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.runGitStatus(in: root, recentCommitLimit: commitLimit)
            }.value
            guard let self, self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            afterViewUpdate {
                guard self.contextGeneration == generation,
                      self.statusRequestID == requestID,
                      self.rootPath == root else { return }
                self.changeBatch.perform {
                    self.isRefreshing = false
                    // A pagination request may have arrived while this older snapshot
                    // was already running. Keep its loading state latched until the
                    // queued refresh using the larger limit finishes.
                    self.isLoadingMoreCommits = commitLimit < self.recentCommitLimit
                    switch result {
                    case .repository, .notRepository:
                        self.cachedStatusByRoot[root] = result
                    case .failed:
                        break
                    }
                    self.apply(result)
                    self.hasResolvedStatus = true
                    if self.refreshPending {
                        self.refreshPending = false
                        self.refresh()
                    }
                }
            }
        }
    }

    @discardableResult
    func loadMoreCommits() -> Bool {
        guard isRepo, hasMoreRecentCommits,
              !isLoadingMoreCommits, !isBusy else { return false }
        recentCommitLimit += Self.recentCommitPageSize
        recentCommitLimitByRoot[rootPath] = recentCommitLimit
        changeBatch.perform { isLoadingMoreCommits = true }
        if isRefreshing {
            // The active worker captured the previous limit. Queue a second
            // refresh instead of dropping the request made as the section is
            // opened near the end of the viewport.
            refreshPending = true
        } else {
            refresh()
        }
        return true
    }

    func dismissOperation() {
        guard operation?.isRunning != true else { return }
        changeBatch.perform {
            operation = nil
            lastError = nil
        }
    }

    // MARK: - File operations

    func stage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.unstaged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        perform(
            label: String(localized: "Stage \(entry.fileName)"),
            commands: [["--literal-pathspecs", "add", "--"] + paths]
        )
    }

    func unstage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.staged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        let args = hasHead
            ? ["--literal-pathspecs", "restore", "--staged", "--"] + paths
            : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + paths
        perform(label: String(localized: "Unstage \(entry.fileName)"), commands: [args])
    }

    func stageAll() {
        perform(label: String(localized: "Stage all changes"), commands: [["add", "-A"]])
    }

    func unstageAll() {
        let args = hasHead
            ? ["restore", "--staged", "--", "."]
            : ["rm", "--cached", "-r", "-f", "--", "."]
        perform(label: String(localized: "Unstage all changes"), commands: [args])
    }

    /// Restores a tracked file from the index, or moves an untracked file to
    /// the Trash. The UI confirms before calling this.
    func discard(_ entry: Entry) {
        guard validate(entry) else { return }
        if entry.isIntentToAdd {
            perform(
                label: String(localized: "Remove intent-to-add for \(entry.fileName)"),
                commands: [[
                    "--literal-pathspecs", "rm", "--cached", "-f", "--", entry.path,
                ]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash"),
                    completedBefore: String(localized: "Removed the intent-to-add index entry.")
                )
            }
        } else if entry.isUntracked || entry.isWorktreeCopy {
            trash(
                paths: [entry.path],
                label: String(localized: "Move \(entry.fileName) to Trash")
            )
        } else if entry.isWorktreeRename, let original = entry.origPath {
            perform(
                label: String(localized: "Restore \((original as NSString).lastPathComponent)"),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", original]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash"),
                    completedBefore: String(localized: "Restored \((original as NSString).lastPathComponent).")
                )
            }
        } else {
            perform(
                label: String(localized: "Discard changes in \(entry.fileName)"),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", entry.path]]
            )
        }
    }

    /// Discards only the confirmed snapshot. This prevents new files written
    /// by an agent while the dialog is open from joining a bulk destructive action.
    func discardChanges(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        guard entries.allSatisfy(isCurrent) else {
            cancelStaleDiscard()
            return
        }
        let intentToAdd = entries.filter(\.isIntentToAdd)
        let moved = entries.filter { $0.isWorktreeRename || $0.isWorktreeCopy }
        let untracked = entries.filter(\.isUntracked).map(\.path) + moved.map(\.path)
        let renamedOriginals = moved.filter(\.isWorktreeRename).compactMap(\.origPath)
        let tracked = entries.filter {
            !$0.isUntracked && !$0.isWorktreeRename && !$0.isWorktreeCopy
        }.map(\.path) + renamedOriginals
        var commands: [[String]] = []
        if !tracked.isEmpty {
            commands.append(["--literal-pathspecs", "restore", "--worktree", "--"] + tracked)
        }
        if !intentToAdd.isEmpty {
            commands.append(
                ["--literal-pathspecs", "rm", "--cached", "-f", "--"]
                    + intentToAdd.map(\.path)
            )
        }
        guard !commands.isEmpty || !untracked.isEmpty else { return }

        if commands.isEmpty {
            trash(paths: untracked, label: String(localized: "Move untracked files to Trash"))
        } else {
            var completedSteps: [String] = []
            if !tracked.isEmpty {
                completedSteps.append(
                    String(localized: "Restored \(tracked.count) tracked paths.")
                )
            }
            if !intentToAdd.isEmpty {
                completedSteps.append(
                    String(localized: "Removed \(intentToAdd.count) intent-to-add index entries.")
                )
            }
            perform(label: String(localized: "Discard all changes"), commands: commands) { [weak self] success in
                guard success, !untracked.isEmpty else { return }
                self?.trash(
                    paths: untracked,
                    label: String(localized: "Finish discarding all changes"),
                    completedBefore: completedSteps.joined(separator: "\n")
                )
            }
        }
    }

    func cancelStaleDiscard() {
        failImmediately(String(localized: "Files changed while the confirmation was open. Review them and try again."))
    }

    // MARK: - Commit and remote operations

    /// Commits only the index unless `includeAll` explicitly requests `git add -A`.
    func commit(
        message: String,
        includeAll: Bool,
        amend: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(String(localized: "Enter a commit message"), completion: completion)
            return
        }
        guard includeAll || !stagedEntries.isEmpty || amend else {
            failImmediately(String(localized: "Stage changes before committing"), completion: completion)
            return
        }

        var commands: [[String]] = []
        if includeAll { commands.append(["add", "-A"]) }
        var commitArgs = ["commit"]
        if amend { commitArgs.append("--amend") }
        commitArgs += ["-m", trimmed]
        commands.append(commitArgs)
        let label = amend
            ? String(localized: "Amend commit")
            : (includeAll
                ? String(localized: "Stage all and commit")
                : String(localized: "Commit staged changes"))
        perform(label: label, commands: commands, completion: completion)
    }

    func fetch() {
        guard !remotes.isEmpty else {
            failImmediately(String(localized: "No Git remote is configured"))
            return
        }
        perform(
            label: String(localized: "Fetch"),
            commands: [["fetch", "--all", "--prune"]],
            requiresStableHead: false
        )
    }

    func pull() {
        guard hasUpstream else {
            failImmediately(String(localized: "This branch has no upstream to pull from"))
            return
        }
        perform(
            label: String(localized: "Pull"),
            commands: [["pull", "--ff-only"]],
            requiresStableUpstream: true
        )
    }

    func push() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD"))
            return
        }
        if hasUpstream {
            perform(label: String(localized: "Push"), commands: [["push"]], requiresStableUpstream: true)
            return
        }
        guard let remote = unambiguousRemote else {
            failImmediately(remotes.isEmpty
                ? String(localized: "Add a Git remote before publishing this branch")
                : String(localized: "Choose which remote should receive this branch"))
            return
        }
        perform(label: String(localized: "Publish branch"), commands: [["push", "-u", remote, "HEAD"]])
    }

    func publish(to remote: String) {
        guard branch != "detached HEAD" else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD"))
            return
        }
        guard remotes.contains(remote) else {
            failImmediately(String(localized: "The selected Git remote is no longer available"))
            return
        }
        perform(
            label: String(localized: "Publish branch to \(remote)"),
            commands: [["push", "-u", remote, "HEAD"]]
        )
    }

    func syncChanges() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD"))
            return
        }
        if hasUpstream {
            perform(
                label: String(localized: "Sync changes"),
                commands: [["pull", "--ff-only"], ["push"]],
                requiresStableUpstream: true
            )
        } else {
            guard let remote = unambiguousRemote else {
                failImmediately(remotes.isEmpty
                    ? String(localized: "Add a Git remote before publishing this branch")
                    : String(localized: "Choose which remote should receive this branch"))
                return
            }
            perform(label: String(localized: "Publish branch"), commands: [["push", "-u", remote, "HEAD"]])
        }
    }

    // MARK: - Branches, stash, and repository setup

    func switchBranch(to name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard name != branch else {
            completion?(true)
            return
        }
        guard let args = validatedSwitchArguments(to: name, completion: completion) else { return }
        perform(
            label: String(localized: "Switch to \(name)"),
            commands: [args],
            completion: completion
        )
    }

    func createBranch(named name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let args = validatedCreateArguments(named: name, completion: completion) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(
            label: String(localized: "Create branch \(trimmed)"),
            commands: [args],
            completion: completion
        )
    }

    private func validatedSwitchArguments(
        to name: String,
        completion: (@MainActor (Bool) -> Void)?
    ) -> [String]? {
        guard let trimmed = acceptedBranchName(name, completion: completion),
              let args = GitRefName.switchArguments(to: trimmed)
        else { return nil }
        return args
    }

    private func validatedCreateArguments(
        named name: String,
        completion: (@MainActor (Bool) -> Void)?
    ) -> [String]? {
        guard let trimmed = acceptedBranchName(name, completion: completion),
              let args = GitRefName.createArguments(named: trimmed)
        else { return nil }
        return args
    }

    /// Rejects empty and dash-leading names locally, then asks Git
    /// `check-ref-format --branch` when a repository is available.
    private func acceptedBranchName(
        _ name: String,
        completion: (@MainActor (Bool) -> Void)?
    ) -> String? {
        switch GitRefName.sanitizedUserName(name) {
        case .failure(.empty):
            failImmediately(String(localized: "Enter a branch name"), completion: completion)
            return nil
        case .failure(.leadingDash), .failure(.invalidFormat):
            failImmediately(
                String(localized: "A branch name can’t start with “-”."),
                completion: completion
            )
            return nil
        case .success(let trimmed):
            guard GitRefName.passesLocalFormat(trimmed) else {
                failImmediately(
                    String(localized: "“\(trimmed)” is not a valid Git branch name."),
                    completion: completion
                )
                return nil
            }
            let directory = repoRoot.isEmpty ? rootPath : repoRoot
            guard !directory.isEmpty else { return trimmed }
            let check = Self.runGit(
                ["check-ref-format", "--branch", trimmed],
                in: directory,
                timeout: 5
            )
            if check.status != 0 {
                failImmediately(
                    String(localized: "“\(trimmed)” is not a valid Git branch name."),
                    completion: completion
                )
                return nil
            }
            return trimmed
        }
    }

    func stash(includeUntracked: Bool = true) {
        guard totalChangeCount > 0 else {
            failImmediately(String(localized: "There are no changes to stash"))
            return
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        perform(label: String(localized: "Stash changes"), commands: [args])
    }

    func stashPop() {
        guard stashCount > 0 else {
            failImmediately(String(localized: "There are no stashes to pop"))
            return
        }
        perform(label: String(localized: "Pop stash"), commands: [["stash", "pop"]])
    }

    func initializeRepository(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !rootPath.isEmpty else {
            failImmediately(String(localized: "Open a terminal directory first"), completion: completion)
            return
        }
        perform(
            label: String(localized: "Initialize repository"),
            commands: [["init"]],
            directory: rootPath,
            completion: completion
        )
    }

    // MARK: - Operation runner

    private var unambiguousRemote: String? {
        remotes.count == 1 ? remotes[0] : nil
    }

    private func validate(_ entry: Entry) -> Bool {
        guard isCurrent(entry) else {
            failImmediately(String(localized: "Repository changed; refresh and try the Git action again"))
            return false
        }
        return true
    }

    private func perform(
        label: String,
        commands: [[String]],
        directory: String? = nil,
        requiresStableHead: Bool = true,
        requiresStableUpstream: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        if directory == nil && !isRepo {
            failImmediately(
                String(localized: "Repository changed; review the current directory and try the Git action again."),
                completion: completion
            )
            return
        }
        let dir = directory ?? repoRoot
        let generation = contextGeneration
        let validationRoot = rootPath
        let expectedRepositoryRoot = directory == nil && isRepo ? repoRoot : nil
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let expectedUpstream = upstream
        guard !dir.isEmpty, !isBusy, !commands.isEmpty else { return }

        let operationID = UUID()
        changeBatch.perform {
            invalidateStatusRefresh()
            runningOperationID = operationID
            isBusy = true
            lastError = nil
            operation = Operation(
                id: operationID,
                label: label,
                state: .running,
                output: "",
                startedAt: Date(),
                finishedAt: nil
            )
        }

        Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                var transcript: [String] = []
                var failureCode: Int32?
                var failureMessage: String?

                if let expectedRepositoryRoot {
                    guard Self.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                        let message = String(localized: "Repository changed before the Git action could run. Review the current changes and try again.")
                        return CommandBatchResult(
                            output: message, failureCode: -1, failureMessage: message
                        )
                    }
                    if requiresStableHead {
                        let liveStatus = Self.runGit(
                            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                            in: expectedRepositoryRoot
                        )
                        let live = liveStatus.status == 0
                            ? Self.parseStatus(liveStatus.stdout)
                            : nil
                        guard let live,
                              live.headOID == expectedHeadOID,
                              live.branch == expectedBranch,
                              !requiresStableUpstream || live.upstream == expectedUpstream else {
                            let message = requiresStableUpstream
                                ? String(localized: "Branch, HEAD, or upstream changed before the Git action could run. Review the current changes and try again.")
                                : String(localized: "Branch or HEAD changed before the Git action could run. Review the current changes and try again.")
                            return CommandBatchResult(
                                output: message, failureCode: -1, failureMessage: message
                            )
                        }
                    }
                }

                for args in commands {
                    transcript.append("$ git " + Self.displayCommand(args))
                    let run = Self.runGit(args, in: dir)
                    let text = [run.stdout, run.stderr]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    if !text.isEmpty { transcript.append(text) }
                    if run.status != 0 {
                        let fallback = String(localized: "Git command failed")
                        failureCode = run.status
                        failureMessage = text.isEmpty ? fallback : text
                        break
                    }
                }
                return CommandBatchResult(
                    output: transcript.joined(separator: "\n"),
                    failureCode: failureCode,
                    failureMessage: failureMessage
                )
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            var succeeded = false
            self.changeBatch.perform {
                self.runningOperationID = nil
                self.isBusy = false
                guard self.contextGeneration == generation,
                      self.operation?.id == operationID else {
                    return
                }
                let finishedAt = Date()
                if let failureCode = batch.failureCode {
                    self.lastError = batch.failureMessage
                    self.operation = Operation(
                        id: operationID,
                        label: label,
                        state: .failed(exitCode: failureCode),
                        output: batch.output,
                        startedAt: self.operation?.startedAt ?? finishedAt,
                        finishedAt: finishedAt
                    )
                    succeeded = false
                } else {
                    self.lastError = nil
                    self.operation = Operation(
                        id: operationID,
                        label: label,
                        state: .succeeded,
                        output: batch.output.isEmpty
                            ? String(localized: "Completed successfully.")
                            : batch.output,
                        startedAt: self.operation?.startedAt ?? finishedAt,
                        finishedAt: finishedAt
                    )
                    succeeded = true
                }
            }
            if self.contextGeneration != generation || self.operation?.id != operationID {
                completion?(false)
                self.refresh()
                return
            }
            completion?(succeeded)
            self.refresh()
        }
    }

    private func failImmediately(
        _ message: String,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isBusy else {
            completion?(false)
            return
        }
        changeBatch.perform {
            lastError = message
            operation = Operation(
                id: UUID(),
                label: String(localized: "Git action"),
                state: .failed(exitCode: -1),
                output: message,
                startedAt: Date(),
                finishedAt: Date()
            )
        }
        completion?(false)
    }

    private func trash(paths: [String], label: String, completedBefore: String? = nil) {
        guard !paths.isEmpty, !isBusy else { return }
        let base = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let expectedRepositoryRoot = repoRoot
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let validationRoot = rootPath
        let generation = contextGeneration
        let operationID = UUID()
        changeBatch.perform {
            invalidateStatusRefresh()
            runningOperationID = operationID
            isBusy = true
            lastError = nil
            operation = Operation(
                id: operationID, label: label, state: .running, output: "",
                startedAt: Date(), finishedAt: nil
            )
        }

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                guard Self.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Repository changed before the file action could run. Review the current changes and try again.")
                    )
                }
                let liveStatus = Self.runGit(
                    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                    in: expectedRepositoryRoot
                )
                let live = liveStatus.status == 0 ? Self.parseStatus(liveStatus.stdout) : nil
                guard let live,
                      live.headOID == expectedHeadOID,
                      live.branch == expectedBranch else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Branch or HEAD changed before the file action could run. Review the current changes and try again.")
                    )
                }
                var moved: [String] = []
                var failure: String?
                for path in paths {
                    do {
                        try FileManager.default.trashItem(
                            at: base.appendingPathComponent(path), resultingItemURL: nil
                        )
                        moved.append(path)
                    } catch {
                        failure = error.localizedDescription
                        break
                    }
                }
                return TrashResult(moved: moved, failure: failure)
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.changeBatch.perform {
                self.runningOperationID = nil
                self.isBusy = false
                guard self.contextGeneration == generation,
                      self.operation?.id == operationID else {
                    return
                }
                let finishedAt = Date()
                if let failure = result.failure {
                    let completedResult = completedBefore.map { $0 + "\n" } ?? ""
                    let partialResult = result.moved.isEmpty
                        ? ""
                        : "\n\n" + String(localized: "Moved to Trash before the failure:") + "\n"
                            + result.moved.joined(separator: "\n")
                    let output = completedResult + failure + partialResult
                    self.lastError = result.moved.isEmpty
                        ? completedResult + failure
                        : completedResult + String(
                            localized: "\(failure) (\(result.moved.count) items were already moved to Trash.)"
                        )
                    self.operation = Operation(
                        id: operationID, label: label, state: .failed(exitCode: -1),
                        output: output, startedAt: self.operation?.startedAt ?? finishedAt,
                        finishedAt: finishedAt
                    )
                } else {
                    let output = [
                        completedBefore,
                        String(localized: "Moved to Trash:") + "\n"
                            + result.moved.joined(separator: "\n"),
                    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                    self.operation = Operation(
                        id: operationID, label: label, state: .succeeded,
                        output: output,
                        startedAt: self.operation?.startedAt ?? finishedAt,
                        finishedAt: finishedAt
                    )
                }
            }
            self.refresh()
        }
    }

    private nonisolated struct CommandBatchResult: Sendable {
        let output: String
        let failureCode: Int32?
        let failureMessage: String?
    }

    private nonisolated struct TrashResult: Sendable {
        let moved: [String]
        let failure: String?
    }

    private nonisolated final class PipeData: @unchecked Sendable {
        var value = Data()
    }

    private func invalidateStatusRefresh() {
        changeBatch.perform {
            statusRequestID &+= 1
            isRefreshing = false
            isLoadingMoreCommits = false
            refreshPending = false
        }
    }

    private nonisolated static func displayCommand(_ args: [String]) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_@%+=:,./-")
        )
        return args.map { arg in
            guard arg.isEmpty || arg.unicodeScalars.contains(where: { !safeCharacters.contains($0) }) else {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: - Status

    private func clearRepositoryState(
        preserveIdentity: Bool = false,
        preserveFailedOperation: Bool = false
    ) {
        let failedOperation = preserveFailedOperation ? operation : nil
        let failedError = preserveFailedOperation ? lastError : nil
        topLevel = ""
        isRepo = false
        branch = nil
        headOID = nil
        hasHead = true
        upstream = nil
        ahead = 0
        behind = 0
        hasUpstream = false
        lineAdditions = 0
        lineDeletions = 0
        mergeEntries = []
        stagedEntries = []
        changedEntries = []
        fileDecorations = [:]
        directoryDecorations = [:]
        ignoredPaths = []
        ignoredDirectories = []
        branches = []
        defaultBranch = nil
        remotes = []
        recentCommits = []
        hasMoreRecentCommits = false
        isLoadingMoreCommits = false
        repositoryOperation = nil
        stashCount = 0
        isRefreshing = false
        isBusy = runningOperationID != nil
        operation = failedOperation
        lastError = failedError
        statusError = nil
        statusRequestID &+= 1
        if !preserveIdentity { repositoryIdentity = "" }
    }

    private func apply(_ loadResult: StatusLoadResult) {
        changeBatch.perform {
        switch loadResult {
        case .notRepository:
            // A refresh can finish after a user action starts. Do not let a
            // transient status failure erase the active operation/result.
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(preserveFailedOperation: preserveFailure)
            return
        case .failed(let message):
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(
                preserveIdentity: true,
                preserveFailedOperation: preserveFailure
            )
            statusError = message
            return
        case .repository(let result):
            statusError = nil
            applyRepository(result)
        }
        }
    }

    private func applyRepository(_ result: StatusResult) {
        isRepo = true
        branch = result.branch
        headOID = result.headOID
        hasHead = result.hasHead
        upstream = result.upstream
        ahead = result.ahead
        behind = result.behind
        hasUpstream = result.upstream != nil
        lineAdditions = result.lineAdditions
        lineDeletions = result.lineDeletions
        topLevel = result.topLevel
        repositoryIdentity = result.topLevel
        if result.loadedDetails {
            branches = result.branches
            defaultBranch = result.defaultBranch
            remotes = result.remotes
            recentCommits = result.recentCommits
            hasMoreRecentCommits = result.hasMoreRecentCommits
            repositoryOperation = result.repositoryOperation
            stashCount = result.stashCount
        }

        let entries = result.entries.map { entry in
            var entry = entry
            entry.repositoryRoot = result.topLevel
            return entry
        }
        fileDecorations = Self.fileDecorations(for: entries)
        directoryDecorations = Self.rolledUpDirectoryDecorations(fileDecorations)
        ignoredPaths = result.ignoredPaths
        ignoredDirectories = result.ignoredPaths.compactMap { path in
            path.hasSuffix("/") ? String(path.dropLast()) : nil
        }
        mergeEntries = entries.filter(\.isConflict)
        stagedEntries = entries.filter {
            !$0.isConflict && $0.staged != "." && $0.staged != "?"
        }
        changedEntries = entries.filter {
            !$0.isConflict && $0.unstaged != "."
        }
    }

    nonisolated enum StatusLoadResult: Equatable, Sendable {
        case repository(StatusResult)
        case notRepository
        case failed(String)
    }

    nonisolated struct StatusResult: Equatable, Sendable {
        var branch: String?
        var headOID: String?
        var hasHead = true
        var upstream: String?
        var ahead = 0
        var behind = 0
        var lineAdditions = 0
        var lineDeletions = 0
        var topLevel = ""
        var entries: [Entry] = []
        var ignoredPaths: Set<String> = []
        var branches: [String] = []
        var defaultBranch: String?
        var remotes: [String] = []
        var recentCommits: [RecentCommit] = []
        var hasMoreRecentCommits = false
        var repositoryOperation: String?
        var stashCount = 0
        var loadedDetails = false
    }

    /// Identifies a cached log/branches/remotes snapshot. Unborn repositories
    /// use `"(initial)"` because porcelain reports that instead of an oid.
    nonisolated struct GitDetailsCacheKey: Equatable, Hashable, Sendable {
        let repositoryRoot: String
        let headOID: String
        let recentCommitLimit: Int
    }

    /// Status-only work keeps HEAD unchanged; reuse when the cache covers the
    /// requested history length. Stash count is loaded separately because it
    /// can change without a new commit.
    nonisolated static func shouldReuseCachedGitDetails(
        cached: GitDetailsCacheKey?,
        current: GitDetailsCacheKey
    ) -> Bool {
        guard let cached else { return false }
        return cached.repositoryRoot == current.repositoryRoot
            && cached.headOID == current.headOID
            && cached.recentCommitLimit >= current.recentCommitLimit
    }

    nonisolated struct UntrackedLineCacheKey: Equatable, Hashable, Sendable {
        let path: String
        let modificationDate: Date
        let size: Int
    }

    nonisolated static func untrackedLineCacheKey(
        path: String,
        modificationDate: Date?,
        size: Int?
    ) -> UntrackedLineCacheKey? {
        guard let modificationDate, let size else { return nil }
        return UntrackedLineCacheKey(
            path: path, modificationDate: modificationDate, size: size
        )
    }

    private nonisolated struct CachedGitDetails: Sendable {
        var key: GitDetailsCacheKey
        var branches: [String]
        var defaultBranch: String?
        var remotes: [String]
        var recentCommits: [RecentCommit]
        var hasMoreRecentCommits: Bool
    }

    /// Process-wide caches shared by background status refreshes. Guarded by
    /// locks because several windows can load Git state at once.
    private nonisolated final class GitStatusSharedCaches: @unchecked Sendable {
        static let shared = GitStatusSharedCaches()

        private let detailsLock = NSLock()
        private var details: [DetailsIdentity: CachedGitDetails] = [:]

        private let untrackedLock = NSLock()
        private var untrackedLines: [UntrackedLineCacheKey: (lines: Int, bytesRead: Int)] = [:]
        private let untrackedLineLimit = 4_096

        private nonisolated struct DetailsIdentity: Hashable, Sendable {
            let repositoryRoot: String
            let headOID: String
        }

        private init() {}

        func details(for key: GitDetailsCacheKey) -> CachedGitDetails? {
            detailsLock.lock()
            defer { detailsLock.unlock() }
            return details[
                DetailsIdentity(repositoryRoot: key.repositoryRoot, headOID: key.headOID)
            ]
        }

        func storeDetails(_ cached: CachedGitDetails) {
            detailsLock.lock()
            defer { detailsLock.unlock() }
            let identity = DetailsIdentity(
                repositoryRoot: cached.key.repositoryRoot,
                headOID: cached.key.headOID
            )
            if let existing = details[identity],
               existing.key.recentCommitLimit > cached.key.recentCommitLimit
            {
                return
            }
            details[identity] = cached
        }

        func untrackedLineCount(
            for key: UntrackedLineCacheKey
        ) -> (lines: Int, bytesRead: Int)? {
            untrackedLock.lock()
            defer { untrackedLock.unlock() }
            return untrackedLines[key]
        }

        func storeUntrackedLineCount(
            _ count: (lines: Int, bytesRead: Int),
            for key: UntrackedLineCacheKey
        ) {
            untrackedLock.lock()
            defer { untrackedLock.unlock() }
            if untrackedLines[key] == nil, untrackedLines.count >= untrackedLineLimit {
                untrackedLines.removeAll(keepingCapacity: true)
            }
            untrackedLines[key] = count
        }
    }

    private nonisolated final class GitStatusDetailOutputs: @unchecked Sendable {
        let lock = NSLock()
        var branches: [String] = []
        var remotes: [String] = []
        var logOutput: String?
        var stashCount: Int?
        var gitDirectory: String?
        var originHeadStatus: Int32 = -1
        var originHeadOutput = ""
    }

    /// Shares the snapshot deadline with concurrent detail commands. Nested
    /// functions are not Sendable, so the worker closures capture this object.
    private nonisolated final class GitStatusDeadlineRunner: @unchecked Sendable {
        let deadline: Date
        let timeoutMessage: String

        init(deadline: Date, timeoutMessage: String) {
            self.deadline = deadline
            self.timeoutMessage = timeoutMessage
        }

        func run(
            _ args: [String], in directory: String
        ) -> (status: Int32, stdout: String, stderr: String) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (-2, "", timeoutMessage) }
            return GitStatusModel.runGit(args, in: directory, timeout: remaining)
        }
    }

    /// Runs Git while draining stdout and stderr concurrently. Dedicated
    /// reader threads are intentional: several restored diff tabs can call
    /// this from Swift's cooperative executor at once, and dispatching the
    /// readers back onto the shared pool can starve every pipe drain.
    nonisolated static func runGit(
        _ args: [String], in dir: String, timeout: TimeInterval? = nil,
        executable: String = "/usr/bin/git"
    ) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Fail rather than hanging on a credential prompt behind the app.
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Git diagnostics are parsed only to distinguish an ordinary folder
        // from a broken repository. Pinning the locale makes that safe and
        // also keeps relative dates stable in the compact history list.
        env["LC_ALL"] = "C"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processExited.signal() }

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = PipeData()
        let errData = PipeData()
        let readers = DispatchGroup()
        // These readers are on the synchronous completion path below. Match
        // the caller so a user-initiated Git request never waits on utility
        // threads, while background refreshes keep their lower priority.
        let readerQualityOfService = Thread.current.qualityOfService
        readers.enter()
        let stdoutReader = Thread {
            outData.value = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stdoutReader.qualityOfService = readerQualityOfService
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stderrReader.qualityOfService = readerQualityOfService
        stderrReader.start()
        var timedOut = false
        if let timeout {
            timedOut = processExited.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                if processExited.wait(timeout: .now() + 1) == .timedOut {
                    // Git can launch a helper that ignores SIGTERM. It is our
                    // child, so force it down before waiting for pipe EOF.
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
        } else {
            process.waitUntilExit()
        }
        readers.wait()
        let output = String(data: outData.value, encoding: .utf8) ?? ""
        var errorOutput = String(data: errData.value, encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = String(localized: "Git did not respond in time.")
            if !errorOutput.isEmpty, !errorOutput.hasSuffix("\n") {
                errorOutput += "\n"
            }
            errorOutput += timeoutMessage
            return (-2, output, errorOutput)
        }
        return (
            process.terminationStatus,
            output,
            errorOutput
        )
    }

    /// Resolves the active repository and distinguishes a normal non-repo
    /// directory from an actual Git failure that the UI should surface.
    private nonisolated static func runGitStatus(
        in root: String,
        recentCommitLimit: Int
    ) -> StatusLoadResult {
        // A filesystem, Git helper, or corrupt repository must not leave the
        // initial sidebar spinner running forever. Share one deadline across
        // the full snapshot instead of allowing every detail command its own
        // timeout.
        let deadline = Date().addingTimeInterval(10)
        let timeoutMessage = String(localized: "Git did not respond in time.")
        let statusGit = GitStatusDeadlineRunner(
            deadline: deadline, timeoutMessage: timeoutMessage
        )

        let top = statusGit.run(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else {
            let failure = gitFailureMessage(
                top,
                fallback: String(localized: "Unable to locate the Git repository.")
            )
            if top.status == 128,
               failure.localizedCaseInsensitiveContains("not a git repository"),
               !containsGitMetadata(atOrAbove: root) {
                return .notRepository
            }
            return .failed(failure)
        }
        let resolvedRoot = strippingTrailingLineEnding(top.stdout)
        guard !resolvedRoot.isEmpty else {
            return .failed(String(localized: "Git returned an empty repository path."))
        }
        let status = statusGit.run(
            [
                "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all", "--ignored=matching",
            ],
            in: resolvedRoot
        )
        guard status.status == 0 else {
            return .failed(
                gitFailureMessage(
                    status,
                    fallback: String(localized: "Unable to read Git status.")
                )
            )
        }
        var result = parseStatus(status.stdout)
        result.topLevel = resolvedRoot

        let diff = statusGit.run(
            result.hasHead
                ? ["diff", "--numstat", "HEAD", "--"]
                : ["diff", "--numstat", "--cached", "--"],
            in: resolvedRoot
        )
        if diff.status == 0 {
            let totals = parseNumstat(diff.stdout)
            result.lineAdditions = totals.additions
            result.lineDeletions = totals.deletions
        }
        // An unborn branch has no HEAD to compare against. Its cached diff is
        // the initial snapshot; add any edits made after staging as a second
        // layer so the toolbar still reflects all pending work.
        if !result.hasHead {
            let unstaged = statusGit.run(["diff", "--numstat", "--"], in: resolvedRoot)
            if unstaged.status == 0 {
                let totals = parseNumstat(unstaged.stdout)
                result.lineAdditions += totals.additions
                result.lineDeletions += totals.deletions
            }
        }
        // `git diff` intentionally omits untracked files. Count their text
        // lines as additions so the compact toolbar totals cover all pending
        // work reported by the porcelain snapshot.
        result.lineAdditions += untrackedLineAdditions(
            for: result.entries,
            in: resolvedRoot
        )

        result.loadedDetails = true
        let repoRoot = resolvedRoot
        let detailsKey = GitDetailsCacheKey(
            repositoryRoot: repoRoot,
            headOID: result.headOID ?? "(initial)",
            recentCommitLimit: recentCommitLimit
        )
        let cachedDetails = GitStatusSharedCaches.shared.details(for: detailsKey)
        let reuseCachedDetails = shouldReuseCachedGitDetails(
            cached: cachedDetails?.key,
            current: detailsKey
        )

        let outputs = GitStatusDetailOutputs()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)
        func enqueue(_ work: @escaping @Sendable () -> Void) {
            group.enter()
            queue.async {
                defer { group.leave() }
                work()
            }
        }

        if !reuseCachedDetails {
            enqueue {
                let refs = statusGit.run(
                    ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
                    in: repoRoot
                )
                guard refs.status == 0 else { return }
                let branches = refs.stdout.split(separator: "\n").map(String.init).sorted()
                outputs.lock.lock()
                outputs.branches = branches
                outputs.lock.unlock()
            }
            enqueue {
                let remoteRun = statusGit.run(["remote"], in: repoRoot)
                guard remoteRun.status == 0 else { return }
                let remotes = remoteRun.stdout.split(separator: "\n").map(String.init).sorted()
                outputs.lock.lock()
                outputs.remotes = remotes
                outputs.lock.unlock()
            }
            // NUL-delimited name-status records preserve every valid path while
            // supplying the nested file rows used by the native commit graph.
            enqueue {
                let log = statusGit.run([
                    "log", "-n", "\(recentCommitLimit + 1)", "--decorate=short",
                    "--pretty=format:%x1e%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1f%P%x1f%D",
                    "--name-status", "-z",
                ], in: repoRoot)
                guard log.status == 0 else { return }
                outputs.lock.lock()
                outputs.logOutput = log.stdout
                outputs.lock.unlock()
            }
            // Prefer origin while remotes are still loading. A clone records
            // its remote's default branch as a symbolic HEAD; origin is the
            // repository the local branch list conventionally belongs to.
            enqueue {
                let remoteHead = statusGit.run(
                    ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                    in: repoRoot
                )
                outputs.lock.lock()
                outputs.originHeadStatus = remoteHead.status
                outputs.originHeadOutput = remoteHead.stdout
                outputs.lock.unlock()
            }
        }

        enqueue {
            let stash = statusGit.run(
                ["rev-list", "--walk-reflogs", "--count", "refs/stash"],
                in: repoRoot
            )
            guard stash.status == 0 else { return }
            let count = Int(
                stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 0
            outputs.lock.lock()
            outputs.stashCount = count
            outputs.lock.unlock()
        }
        enqueue {
            let gitDir = statusGit.run(
                ["rev-parse", "--absolute-git-dir"], in: repoRoot
            )
            guard gitDir.status == 0 else { return }
            let path = Self.strippingTrailingLineEnding(gitDir.stdout)
            outputs.lock.lock()
            outputs.gitDirectory = path
            outputs.lock.unlock()
        }

        let remaining = deadline.timeIntervalSinceNow
        let detailsTimedOut =
            group.wait(timeout: remaining > 0 ? .now() + remaining : .now())
            == .timedOut

        outputs.lock.lock()
        let fetchedBranches = outputs.branches
        let fetchedRemotes = outputs.remotes
        let fetchedLog = outputs.logOutput
        let fetchedStashCount = outputs.stashCount
        let fetchedGitDirectory = outputs.gitDirectory
        let originHeadStatus = outputs.originHeadStatus
        let originHeadOutput = outputs.originHeadOutput
        outputs.lock.unlock()

        if reuseCachedDetails, let cachedDetails {
            result.branches = cachedDetails.branches
            result.defaultBranch = cachedDetails.defaultBranch
            result.remotes = cachedDetails.remotes
            result.recentCommits = Array(
                cachedDetails.recentCommits.prefix(recentCommitLimit)
            )
            result.hasMoreRecentCommits =
                cachedDetails.hasMoreRecentCommits
                || cachedDetails.recentCommits.count > recentCommitLimit
        } else {
            result.branches = fetchedBranches
            result.remotes = fetchedRemotes
            if fetchedRemotes.contains("origin") {
                result.defaultBranch = Self.defaultBranch(
                    remote: "origin",
                    symbolicRefStatus: originHeadStatus,
                    symbolicRefOutput: originHeadOutput,
                    branches: fetchedBranches
                )
            } else if let remote = fetchedRemotes.first {
                let remoteHead = statusGit.run(
                    [
                        "symbolic-ref", "--quiet", "--short",
                        "refs/remotes/\(remote)/HEAD",
                    ],
                    in: repoRoot
                )
                result.defaultBranch = Self.defaultBranch(
                    remote: remote,
                    symbolicRefStatus: remoteHead.status,
                    symbolicRefOutput: remoteHead.stdout,
                    branches: fetchedBranches
                )
            }
            if let fetchedLog {
                let commits = parseRecentCommits(fetchedLog)
                result.hasMoreRecentCommits = commits.count > recentCommitLimit
                result.recentCommits = Array(commits.prefix(recentCommitLimit))
            }
            // A timed-out snapshot can be missing log or refs. Skip the cache
            // so the next refresh retries instead of freezing empty history.
            if !detailsTimedOut {
                GitStatusSharedCaches.shared.storeDetails(
                    CachedGitDetails(
                        key: detailsKey,
                        branches: result.branches,
                        defaultBranch: result.defaultBranch,
                        remotes: result.remotes,
                        recentCommits: result.recentCommits,
                        hasMoreRecentCommits: result.hasMoreRecentCommits
                    )
                )
            }
        }

        if let fetchedStashCount {
            result.stashCount = fetchedStashCount
        }
        if let fetchedGitDirectory {
            result.repositoryOperation = detectRepositoryOperation(
                gitDirectory: fetchedGitDirectory
            )
        }
        return .repository(result)
    }

    private nonisolated static func resolveRepositoryRoot(in root: String) -> String? {
        let top = runGit(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else { return nil }
        let path = strippingTrailingLineEnding(top.stdout)
        return path.isEmpty ? nil : path
    }

    /// A malformed `.git` directory/file can produce the same rev-parse text
    /// as a plain folder. Preserve that as an actionable status error instead
    /// of offering to initialize a nested repository on top of broken metadata.
    private nonisolated static func containsGitMetadata(atOrAbove root: String) -> Bool {
        let fm = FileManager.default
        // Walk path strings, not URLs: `URL.deletingLastPathComponent()` keeps
        // appending ".." at the filesystem root, so a URL ascent never
        // reaches its fixed point and spins forever. The NSString walk
        // terminates at "/".
        var directory = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL.path as NSString
        while true {
            if fm.fileExists(atPath: directory.appendingPathComponent(".git")) {
                return true
            }
            let parent = directory.deletingLastPathComponent as NSString
            if parent.isEqual(to: directory as String) { return false }
            directory = parent
        }
    }

    private nonisolated static func strippingTrailingLineEnding(_ value: String) -> String {
        var value = value
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        return value
    }

    /// A clone records its remote's default branch as `refs/remotes/<remote>/HEAD`.
    /// The short name is only used when it still exists locally.
    private nonisolated static func defaultBranch(
        remote: String,
        symbolicRefStatus: Int32,
        symbolicRefOutput: String,
        branches: [String]
    ) -> String? {
        let prefix = "\(remote)/"
        let ref = strippingTrailingLineEnding(symbolicRefOutput)
        guard symbolicRefStatus == 0, ref.hasPrefix(prefix) else { return nil }
        let branch = String(ref.dropFirst(prefix.count))
        return branches.contains(branch) ? branch : nil
    }

    private nonisolated static func gitFailureMessage(
        _ run: (status: Int32, stdout: String, stderr: String), fallback: String
    ) -> String {
        let message = [run.stderr, run.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return message ?? fallback
    }

    /// Counts porcelain entries in `directory`'s repository. Ignored paths
    /// are omitted. Returns 0 when `directory` is not a git worktree.
    nonisolated static func dirtyFileCount(in directory: String) -> Int {
        guard !directory.isEmpty else { return 0 }
        let top = runGit(["rev-parse", "--show-toplevel"], in: directory, timeout: 2)
        guard top.status == 0 else { return 0 }
        let root = strippingTrailingLineEnding(top.stdout)
        guard !root.isEmpty else { return 0 }
        let status = runGit(
            [
                "status", "--porcelain=v2", "-z",
                "--untracked-files=all", "--ignored=no",
            ],
            in: root,
            timeout: 2
        )
        guard status.status == 0 else { return 0 }
        return dirtyFileCount(from: parseStatus(status.stdout))
    }

    nonisolated static func dirtyFileCount(from result: StatusResult) -> Int {
        result.entries.count
    }

    /// Parses NUL-delimited porcelain v2. Unlike Git's default quoted output,
    /// this preserves spaces, quotes, tabs, and newlines in file names.
    nonisolated static func parseStatus(_ output: String) -> StatusResult {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result = StatusResult()
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.oid ") {
                let oid = String(record.dropFirst("# branch.oid ".count))
                result.hasHead = oid != "(initial)"
                result.headOID = result.hasHead ? oid : nil
            } else if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? "detached HEAD" : name
            } else if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8)
                if fields.count == 9, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        Entry(path: String(fields[8]), staged: xy[0], unstaged: xy[1])
                    )
                }
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9)
                if fields.count == 10, fields[1].count == 2, index + 1 < records.count {
                    let xy = Array(fields[1])
                    // With -z, the destination is in this record and the
                    // original path is the following NUL-delimited token.
                    result.entries.append(
                        Entry(
                            path: String(fields[9]), staged: xy[0], unstaged: xy[1],
                            origPath: records[index + 1]
                        )
                    )
                    index += 1
                }
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10)
                if fields.count == 11, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        Entry(
                            path: String(fields[10]), staged: xy[0], unstaged: xy[1],
                            isConflict: true
                        )
                    )
                }
            } else if record.hasPrefix("? ") {
                result.entries.append(
                    Entry(path: String(record.dropFirst(2)), staged: "?", unstaged: "?")
                )
            } else if record.hasPrefix("! ") {
                result.ignoredPaths.insert(String(record.dropFirst(2)))
            }
            index += 1
        }
        return result
    }

    /// Adds the numeric columns from `git diff --numstat`. Binary-file rows
    /// use `-` instead of a count and therefore contribute zero lines.
    nonisolated static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        output.split(separator: "\n").reduce(into: (additions: 0, deletions: 0)) { total, row in
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            total.additions += Int(fields[0]) ?? 0
            total.deletions += Int(fields[1]) ?? 0
        }
    }

    /// Git's numstat output has no representation for untracked files. Mirror
    /// its new-text-file behavior without spawning one Git process per path.
    private nonisolated static func untrackedLineAdditions(
        for entries: [Entry], in root: String
    ) -> Int {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

        // Line totals are secondary metadata. Keep generated or accidentally
        // enormous untracked trees from delaying the repository itself.
        let maximumFiles = 2_048
        let maximumFileBytes = 8 * 1_024 * 1_024
        var remainingBytes = 32 * 1_024 * 1_024
        var visitedFiles = 0
        var total = 0
        for entry in entries where entry.staged == "?" {
            guard visitedFiles < maximumFiles, remainingBytes > 0 else { break }
            visitedFiles += 1
            let fileURL = rootURL.appendingPathComponent(entry.path).standardizedFileURL
            guard fileURL.path.hasPrefix(rootPrefix) else { continue }
            let count = textLineCount(
                at: fileURL,
                maximumBytes: min(maximumFileBytes, remainingBytes)
            )
            total += count.lines
            remainingBytes -= count.bytesRead
        }
        return total
    }

    /// Counts logical lines while using Git's usual NUL-byte binary heuristic.
    /// Symlink content is its destination path, which is one added line.
    private nonisolated static func textLineCount(
        at url: URL,
        maximumBytes: Int
    ) -> (lines: Int, bytesRead: Int) {
        guard let values = try? url.resourceValues(
            forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey,
            ]
        ) else { return (0, 0) }
        if values.isSymbolicLink == true {
            let count = (lines: 1, bytesRead: 0)
            if let cacheKey = untrackedLineCacheKey(
                path: url.path,
                modificationDate: values.contentModificationDate,
                size: values.fileSize
            ) {
                GitStatusSharedCaches.shared.storeUntrackedLineCount(count, for: cacheKey)
            }
            return count
        }
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumBytes else { return (0, 0) }

        let cacheKey = untrackedLineCacheKey(
            path: url.path,
            modificationDate: values.contentModificationDate,
            size: fileSize
        )
        if let cacheKey,
           let cached = GitStatusSharedCaches.shared.untrackedLineCount(for: cacheKey)
        {
            return cached
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
        defer { try? handle.close() }

        let binaryProbeSize = 8_000
        guard let probe = try? handle.read(upToCount: binaryProbeSize) else {
            return (0, 0)
        }
        guard !probe.contains(0) else {
            let count = (lines: 0, bytesRead: probe.count)
            if let cacheKey {
                GitStatusSharedCaches.shared.storeUntrackedLineCount(count, for: cacheKey)
            }
            return count
        }

        var byteCount = probe.count
        var newlineCount = probe.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        var lastByte = probe.last

        while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            byteCount += chunk.count
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            lastByte = chunk.last
        }

        let count: (lines: Int, bytesRead: Int)
        if byteCount == 0 {
            count = (0, 0)
        } else {
            count = (newlineCount + (lastByte == 0x0A ? 0 : 1), byteCount)
        }
        if let cacheKey {
            GitStatusSharedCaches.shared.storeUntrackedLineCount(count, for: cacheKey)
        }
        return count
    }

    private nonisolated static func fileDecoration(for entry: Entry) -> FileDecoration {
        let statuses = [entry.staged, entry.unstaged]
        if entry.isConflict || statuses.contains("U") { return .conflict }
        if statuses.contains("?") { return .untracked }
        if entry.staged == "A" { return .added }
        if statuses.contains("D") { return .deleted }
        if statuses.contains("R") { return .renamed }
        if statuses.contains("C") { return .copied }
        return .modified
    }

    nonisolated static func parseRecentCommits(_ output: String) -> [RecentCommit] {
        output.split(separator: "\u{1e}").compactMap { record in
            var chunks = record.split(separator: "\u{0}", omittingEmptySubsequences: false)
                .map(String.init)
            guard !chunks.isEmpty else { return nil }

            // With --name-status -z, the first status follows the pretty
            // header after a newline; subsequent statuses are their own NUL
            // fields. Rename/copy records carry both old and new paths.
            let headerAndStatus = chunks.removeFirst()
            let boundary = headerAndStatus.lastIndex(of: "\n")
            let header = boundary.map { String(headerAndStatus[..<$0]) } ?? headerAndStatus
            var statusToken = boundary.map {
                String(headerAndStatus[headerAndStatus.index(after: $0)...])
            } ?? ""
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 7, let timestamp = TimeInterval(fields[4]) else {
                return nil
            }

            var files: [RecentCommit.FileChange] = []
            var index = 0
            while !statusToken.isEmpty, index < chunks.count {
                guard let status = statusToken.first else { break }
                if status == "R" || status == "C" {
                    guard index + 1 < chunks.count else { break }
                    files.append(.init(
                        status: status,
                        path: chunks[index + 1],
                        originalPath: chunks[index]
                    ))
                    index += 2
                } else {
                    files.append(.init(
                        status: status,
                        path: chunks[index],
                        originalPath: nil
                    ))
                    index += 1
                }
                guard index < chunks.count else { break }
                statusToken = chunks[index]
                index += 1
            }

            let parentHash = fields[5]
                .split(separator: " ")
                .first
                .map(String.init)
            let references = fields[6]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return RecentCommit(
                hash: String(fields[0]), shortHash: String(fields[1]),
                subject: String(fields[2]), author: String(fields[3]),
                date: Date(timeIntervalSince1970: timestamp),
                parentHash: parentHash,
                references: references,
                files: files
            )
        }
    }

    nonisolated static func detectRepositoryOperation(gitDirectory: String) -> String? {
        let fm = FileManager.default
        let git = URL(fileURLWithPath: gitDirectory, isDirectory: true)
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: git.appendingPathComponent(name).path)
        }

        if exists("rebase-merge") || exists("rebase-apply") {
            return String(localized: "Rebase in progress")
        }
        if exists("MERGE_HEAD") {
            return String(localized: "Merge in progress")
        }
        if exists("CHERRY_PICK_HEAD") {
            return String(localized: "Cherry-pick in progress")
        }
        if exists("REVERT_HEAD") {
            return String(localized: "Revert in progress")
        }
        if exists("BISECT_LOG") {
            return String(localized: "Bisect in progress")
        }
        return nil
    }
}
