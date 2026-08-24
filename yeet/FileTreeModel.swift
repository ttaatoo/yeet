//
//  FileTreeModel.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// Flattened, lazily-expanded view of a directory tree.
@MainActor
final class FileTreeModel: nonisolated ObservableObject {
    nonisolated struct Item: Identifiable, Equatable, Sendable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        /// True for the transient inline "new file/folder" input row, which
        /// has no backing file yet.
        var isDraft = false
    }

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    nonisolated struct Draft: Equatable, Sendable {
        let parentDir: String
        let isDirectory: Bool
    }

    private(set) var rootPath = ""
    private(set) var items: [Item] = []
    /// Path of the row currently being renamed inline, if any.
    private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    private(set) var draft: Draft?
    /// UI state is not `@Published`; one send per transaction.
    private lazy var changeBatch = ObjectChangeBatch(objectWillChange)
    private var expanded: Set<String> = []
    /// Expansion survives ⇧⌘B hide/show and project switches: keyed by the
    /// panel root so a worktree tree does not inherit another checkout's folds.
    private var expandedByRoot: [String: Set<String>] = [:]
    private var rebuildGeneration: UInt = 0
    private var rebuildTask: Task<Void, Never>?
    private let watcher = DirectoryWatcher()

    init() {
        watcher.onChange = { [weak self] in
            self?.rebuild()
        }
    }

    var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    /// Points the tree at `root` (restoring that root's expansion) and
    /// re-reads visible directories off the main actor. Cheap when nothing
    /// changed.
    func sync(root: String) {
        changeBatch.perform {
            if root != rootPath {
                if !rootPath.isEmpty {
                    expandedByRoot[rootPath] = expanded
                }
                rootPath = root
                expanded = expandedByRoot[root] ?? []
                // Any in-progress inline edit belonged to the old tree.
                renamingPath = nil
                draft = nil
                if root.isEmpty {
                    watcher.stop()
                    items = []
                    return
                }
                watcher.watch(path: root)
            }
            rebuild()
        }
    }

    func toggle(_ item: Item) {
        guard item.isDirectory else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        expandedByRoot[rootPath] = expanded
        rebuild()
    }

    /// Moves `item` to the Trash, then rebuilds so it drops out of the tree.
    func moveToTrash(_ item: Item) {
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: item.path), resultingItemURL: nil
            )
            expanded.remove(item.path)
        } catch {
            presentError(
                String(
                    localized: "Couldn’t move “\(item.name)” to the Trash.",
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
        rebuild()
    }

    // MARK: - Rename

    func beginRename(_ item: Item) {
        changeBatch.perform { renamingPath = item.path }
    }

    func cancelRename() {
        changeBatch.perform { renamingPath = nil }
    }

    /// Renames `item` in place. No-ops on an empty or unchanged name; shows an
    /// alert if the name collides or the filesystem move fails. Returns the new
    /// absolute path when the file actually moved, so callers can follow it
    /// (e.g. re-point open tabs).
    @discardableResult
    func rename(_ item: Item, to newName: String) -> String? {
        changeBatch.perform { renamingPath = nil }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”."),
                String(localized: "A name can’t contain “/” or be “.” or “..”.")
            )
            return nil
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        // A case-only rename ("foo"→"Foo") maps to the same file on a
        // case-insensitive volume, so don't treat that as a collision.
        let caseOnlyChange = trimmed.lowercased() == item.name.lowercased()
        guard caseOnlyChange || !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”."),
                String(localized: "An item named “\(trimmed)” already exists here.")
            )
            return nil
        }
        do {
            try fm.moveItem(atPath: item.path, toPath: dest)
            remapExpanded(from: item.path, to: dest)
        } catch {
            presentError(String(localized: "Couldn’t rename to “\(trimmed)”."), error.localizedDescription)
            return nil
        }
        rebuild()
        return dest
    }

    /// Keeps expansion state after a directory rename by rewriting the old
    /// path prefix (for the folder itself and any expanded descendants).
    private func remapExpanded(from oldPath: String, to newPath: String) {
        guard expanded.contains(where: { $0 == oldPath || $0.hasPrefix(oldPath + "/") })
        else { return }
        expanded = Set(expanded.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") {
                return newPath + String(path.dropFirst(oldPath.count))
            }
            return path
        })
        expandedByRoot[rootPath] = expanded
    }

    // MARK: - Create (inline draft)

    /// Opens an inline input row for a new file inside `directory`.
    func beginNewFile(in directory: String) {
        startDraft(in: directory, isDirectory: false)
    }

    /// Opens an inline input row for a new folder inside `directory`.
    func beginNewFolder(in directory: String) {
        startDraft(in: directory, isDirectory: true)
    }

    private func startDraft(in directory: String, isDirectory: Bool) {
        changeBatch.perform {
            renamingPath = nil
            draft = Draft(parentDir: directory, isDirectory: isDirectory)
            // Reveal the folder's contents so the input row is visible.
            expanded.insert(directory)
        }
        rebuild()
    }

    func cancelDraft() {
        guard draft != nil else { return }
        changeBatch.perform { draft = nil }
        rebuild()
    }

    /// Commits the pending draft, creating the file or folder. An empty name
    /// cancels (matching VS Code). Returns the new file's path — for files
    /// only — so the caller can open it.
    @discardableResult
    func commitDraft(name: String) -> String? {
        guard let draft else { return nil }
        changeBatch.perform { self.draft = nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { rebuild(); return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”."),
                String(localized: "A name can’t contain “/” or be “.” or “..”.")
            )
            rebuild()
            return nil
        }
        let dest = (draft.parentDir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”."),
                String(localized: "An item named “\(trimmed)” already exists here.")
            )
            rebuild()
            return nil
        }
        var createdFile: String?
        if draft.isDirectory {
            do {
                try fm.createDirectory(atPath: dest, withIntermediateDirectories: false)
            } catch {
                presentError(String(localized: "Couldn’t create the folder."), error.localizedDescription)
            }
        } else if fm.createFile(atPath: dest, contents: nil) {
            createdFile = dest
        } else {
            presentError(
                String(localized: "Couldn’t create the file."),
                String(localized: "It could not be written to disk.")
            )
        }
        rebuild()
        return createdFile
    }

    private func presentError(_ messageText: String, _ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func rebuild() {
        guard !rootPath.isEmpty else { return }
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        let root = rootPath
        let expanded = expanded
        let draft = draft
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.snapshot(root: root, expanded: expanded, draft: draft)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.rebuildGeneration == generation,
                  self.rootPath == root
            else { return }
            afterViewUpdate {
                guard self.rebuildGeneration == generation, self.rootPath == root else { return }
                self.changeBatch.perform {
                    if snapshot != self.items {
                        self.items = snapshot
                    }
                }
            }
        }
    }

    /// Directory listing lives off the main actor and times out like Git, so
    /// a dead volume cannot freeze the inspector.
    nonisolated static func snapshot(
        root: String,
        expanded: Set<String>,
        draft: Draft?
    ) -> [Item] {
        var out: [Item] = []
        appendChildren(
            of: root, depth: 0, expanded: expanded, draft: draft, into: &out
        )
        return out
    }

    private nonisolated static func appendChildren(
        of dir: String,
        depth: Int,
        expanded: Set<String>,
        draft: Draft?,
        into out: inout [Item]
    ) {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return }
        // Show the inline new-file/folder input at the top of its folder.
        if let draft, draft.parentDir == dir {
            out.append(
                Item(
                    name: "", path: dir + "/\u{1}draft",
                    isDirectory: draft.isDirectory, depth: depth, isDraft: true
                )
            )
        }
        guard let entries = TimedFileIO.contentsOfDirectoryEntries(atPath: dir) else { return }

        let children = entries
            .filter { $0.name != ".git" }
            .map { entry in
                Item(
                    name: entry.name,
                    path: entry.path,
                    isDirectory: entry.isDirectory,
                    depth: depth
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        for child in children {
            out.append(child)
            if child.isDirectory, expanded.contains(child.path) {
                appendChildren(
                    of: child.path,
                    depth: depth + 1,
                    expanded: expanded,
                    draft: draft,
                    into: &out
                )
            }
        }
    }
}
