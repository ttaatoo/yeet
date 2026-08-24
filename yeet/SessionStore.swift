//
//  SessionStore.swift
//  kero
//

import Foundation

/// Snapshot of open projects and tabs, saved so a relaunch restores the
/// previous layout. Terminal sessions restore as fresh shells started in
/// their last known working directory — with their previous scrollback
/// replayed above the prompt when the "Restore session history" setting is on
/// (see `historyKey` and `TerminalHistoryStore`); file and diff panes reload
/// from disk.
struct SessionSnapshot: Codable {
    struct ProjectSnapshot: Codable {
        /// A single pane's content — the terminal, file, browser, or diff it
        /// holds. The original case shapes stay unchanged, so old saved tabs
        /// still decode; see `TabSnapshot`.
        enum PaneContentSnapshot: Codable {
            /// `agentKind`/`agentSessionID` are set only when a coding agent
            /// was live in the pane at save time and reported its native
            /// session identifier, so relaunch can resume that conversation.
            /// Both optional so snapshots written before agent restore decode.
            case session(
                workingDirectory: String,
                agentKind: String?,
                agentSessionID: String?
            )
            case file(path: String, editorState: EditorState?)
            case browser(url: String?)
            case diff(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?)
            case commitDiff(
                repoRoot: String,
                path: String,
                commitHash: String,
                parentHash: String?,
                status: String,
                origPath: String?
            )

            private enum SessionCodingKeys: String, CodingKey {
                case workingDirectory, agentKind, agentSessionID
            }
            private enum FileCodingKeys: String, CodingKey {
                case path, editorState
            }
            private enum BrowserCodingKeys: String, CodingKey {
                case url
            }
            private enum DiffCodingKeys: String, CodingKey {
                case repoRoot, path, staged, untracked, origPath
            }
            private enum CommitDiffCodingKeys: String, CodingKey {
                case repoRoot, path, commitHash, parentHash, status, origPath
            }

            init(from decoder: any Decoder) throws {
                // Optional associated values decode as absent when the key is
                // missing, so pre-agent-restore sessions (and older optional
                // fields) still load. Distinctive keys decide the case:
                // commitDiff before diff and file, because its payload also
                // carries `path`.
                if let container = try? decoder.container(
                    keyedBy: SessionCodingKeys.self
                ), container.contains(.workingDirectory) {
                    self = .session(
                        workingDirectory: try container.decode(
                            String.self, forKey: .workingDirectory
                        ),
                        agentKind: try? container.decodeIfPresent(
                            String.self, forKey: .agentKind
                        ),
                        agentSessionID: try? container.decodeIfPresent(
                            String.self, forKey: .agentSessionID
                        )
                    )
                    return
                }
                if let container = try? decoder.container(
                    keyedBy: BrowserCodingKeys.self
                ), container.contains(.url) {
                    self = .browser(
                        url: try container.decodeIfPresent(String.self, forKey: .url)
                    )
                    return
                }
                if let container = try? decoder.container(
                    keyedBy: CommitDiffCodingKeys.self
                ), container.contains(.commitHash) {
                    self = .commitDiff(
                        repoRoot: try container.decode(String.self, forKey: .repoRoot),
                        path: try container.decode(String.self, forKey: .path),
                        commitHash: try container.decode(String.self, forKey: .commitHash),
                        parentHash: try? container.decodeIfPresent(
                            String.self, forKey: .parentHash
                        ),
                        status: try container.decode(String.self, forKey: .status),
                        origPath: try? container.decodeIfPresent(
                            String.self, forKey: .origPath
                        )
                    )
                    return
                }
                if let container = try? decoder.container(
                    keyedBy: DiffCodingKeys.self
                ), container.contains(.repoRoot) {
                    self = .diff(
                        repoRoot: try container.decode(String.self, forKey: .repoRoot),
                        path: try container.decode(String.self, forKey: .path),
                        staged: try container.decode(Bool.self, forKey: .staged),
                        untracked: try container.decode(Bool.self, forKey: .untracked),
                        origPath: try? container.decodeIfPresent(
                            String.self, forKey: .origPath
                        )
                    )
                    return
                }
                if let container = try? decoder.container(
                    keyedBy: FileCodingKeys.self
                ), container.contains(.path) {
                    self = .file(
                        path: try container.decode(String.self, forKey: .path),
                        editorState: try? container.decodeIfPresent(
                            EditorState.self, forKey: .editorState
                        )
                    )
                    return
                }
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized pane content snapshot"
                ))
            }

            func encode(to encoder: any Encoder) throws {
                switch self {
                case .session(let workingDirectory, let agentKind, let agentSessionID):
                    var container = encoder.container(keyedBy: SessionCodingKeys.self)
                    try container.encode(workingDirectory, forKey: .workingDirectory)
                    try container.encodeIfPresent(agentKind, forKey: .agentKind)
                    try container.encodeIfPresent(
                        agentSessionID, forKey: .agentSessionID
                    )
                case .file(let path, let editorState):
                    var container = encoder.container(keyedBy: FileCodingKeys.self)
                    try container.encode(path, forKey: .path)
                    try container.encodeIfPresent(editorState, forKey: .editorState)
                case .browser(let url):
                    var container = encoder.container(keyedBy: BrowserCodingKeys.self)
                    // Always write the key: a nil URL must still decode as a
                    // browser pane rather than an unrecognized snapshot.
                    try container.encode(url, forKey: .url)
                case .diff(let repoRoot, let path, let staged, let untracked, let origPath):
                    var container = encoder.container(keyedBy: DiffCodingKeys.self)
                    try container.encode(repoRoot, forKey: .repoRoot)
                    try container.encode(path, forKey: .path)
                    try container.encode(staged, forKey: .staged)
                    try container.encode(untracked, forKey: .untracked)
                    try container.encodeIfPresent(origPath, forKey: .origPath)
                case .commitDiff(
                    let repoRoot, let path, let commitHash, let parentHash,
                    let status, let origPath
                ):
                    var container = encoder.container(keyedBy: CommitDiffCodingKeys.self)
                    try container.encode(repoRoot, forKey: .repoRoot)
                    try container.encode(path, forKey: .path)
                    try container.encode(commitHash, forKey: .commitHash)
                    try container.encodeIfPresent(parentHash, forKey: .parentHash)
                    try container.encode(status, forKey: .status)
                    try container.encodeIfPresent(origPath, forKey: .origPath)
                }
            }
        }

        struct PaneSnapshot: Codable {
            var content: PaneContentSnapshot
            var weight: Double
            /// Key into the sidecar terminal-history store for a session pane;
            /// nil for files, browsers, diffs, or when history restore is off.
            /// Optional so snapshots written before this feature still decode.
            var historyKey: String?
        }

        struct ColumnSnapshot: Codable {
            var panes: [PaneSnapshot]
            var weight: Double
        }

        /// The persisted recursive pane tree. Fractions belong to individual
        /// splits, so a child can be divided on either axis without affecting
        /// its siblings.
        indirect enum LayoutSnapshot: Codable {
            case pane(PaneSnapshot)
            case split(
                axis: PaneSplitAxis,
                fraction: Double,
                first: LayoutSnapshot,
                second: LayoutSnapshot
            )
        }

        /// One tab's recursive layout plus the focused leaf's tree-order
        /// position. Decodes both the former column/row format and the original
        /// pre-split single-content format.
        struct TabSnapshot: Codable {
            var layout: LayoutSnapshot
            var focusedPaneIndex: Int
            /// User-assigned tab name; nil when the title is automatic.
            /// Optional so older snapshots still decode.
            var customName: String?
            /// Position of the terminal this non-terminal tab was opened
            /// from in the project's flattened session list. Optional so
            /// snapshots written before context persistence still decode.
            var contextSessionIndex: Int?

            init(
                layout: LayoutSnapshot, focusedPaneIndex: Int,
                customName: String? = nil, contextSessionIndex: Int? = nil
            ) {
                self.layout = layout
                self.focusedPaneIndex = focusedPaneIndex
                self.customName = customName
                self.contextSessionIndex = contextSessionIndex
            }

            enum CodingKeys: String, CodingKey {
                case layout, focusedPaneIndex, customName, contextSessionIndex
                case columns, focusedColumn, focusedRow
            }

            init(from decoder: any Decoder) throws {
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   container.contains(.layout) {
                    layout = try container.decode(LayoutSnapshot.self, forKey: .layout)
                    focusedPaneIndex =
                        (try? container.decode(Int.self, forKey: .focusedPaneIndex)) ?? 0
                    customName = try? container.decode(String.self, forKey: .customName)
                    contextSessionIndex = try? container.decode(
                        Int.self, forKey: .contextSessionIndex
                    )
                    return
                }
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   let columns = try? container.decode(
                       [ColumnSnapshot].self, forKey: .columns
                   ), !columns.isEmpty {
                    let nonEmptyColumns = columns.filter { !$0.panes.isEmpty }
                    guard !nonEmptyColumns.isEmpty else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .columns,
                            in: container,
                            debugDescription: "A pane layout must contain at least one pane"
                        )
                    }
                    let focusedColumn =
                        (try? container.decode(Int.self, forKey: .focusedColumn)) ?? 0
                    let focusedRow =
                        (try? container.decode(Int.self, forKey: .focusedRow)) ?? 0
                    layout = Self.layout(from: nonEmptyColumns)
                    let clampedColumn = min(max(0, focusedColumn), columns.count - 1)
                    focusedPaneIndex = columns[..<clampedColumn]
                        .reduce(0) { $0 + $1.panes.count }
                        + min(
                            max(0, focusedRow),
                            max(0, columns[clampedColumn].panes.count - 1)
                        )
                    customName = try? container.decode(String.self, forKey: .customName)
                    contextSessionIndex = nil
                    return
                }
                // Legacy: the tab was a single content enum. Wrap it in a
                // one-pane layout.
                let content = try PaneContentSnapshot(from: decoder)
                layout = .pane(PaneSnapshot(content: content, weight: 1))
                focusedPaneIndex = 0
                customName = nil
                contextSessionIndex = nil
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(layout, forKey: .layout)
                try container.encode(focusedPaneIndex, forKey: .focusedPaneIndex)
                try container.encodeIfPresent(customName, forKey: .customName)
                try container.encodeIfPresent(
                    contextSessionIndex, forKey: .contextSessionIndex
                )
            }

            /// Converts the former row-of-columns layout to an equivalent
            /// recursive tree so existing saved sessions continue to restore.
            private static func layout(from columns: [ColumnSnapshot]) -> LayoutSnapshot {
                let columnLayouts = columns.map { column in
                    (
                        node: stack(
                            column.panes.map { (.pane($0), $0.weight) },
                            axis: .vertical
                        ),
                        weight: column.weight
                    )
                }
                return stack(
                    columnLayouts.map { ($0.node, $0.weight) },
                    axis: .horizontal
                )
            }

            /// Builds a binary tree that preserves an n-item weighted stack.
            private static func stack(
                _ nodes: [(LayoutSnapshot, Double)], axis: PaneSplitAxis
            ) -> LayoutSnapshot {
                precondition(!nodes.isEmpty)
                guard nodes.count > 1 else { return nodes[0].0 }
                let firstWeight = max(0, nodes[0].1)
                let remainingWeight = nodes.dropFirst().reduce(0) {
                    $0 + max(0, $1.1)
                }
                let total = firstWeight + remainingWeight
                let fraction = total > 0
                    ? firstWeight / total
                    : 1 / Double(nodes.count)
                return .split(
                    axis: axis,
                    fraction: fraction,
                    first: nodes[0].0,
                    second: stack(Array(nodes.dropFirst()), axis: axis)
                )
            }
        }

        var customName: String?
        /// User-pinned project directory; nil when the directory is
        /// automatic (the closest git repository, never persisted).
        /// Optional so older snapshots still decode.
        var customDirectory: String?
        var tabs: [TabSnapshot]
        var selectedTabIndex: Int?
    }

    var projects: [ProjectSnapshot]
    var selectedProjectIndex: Int?
    /// Sidebar layout. Optional so snapshots written before these were
    /// captured still decode; nil leaves the window at its defaults.
    var isLeftSidebarVisible: Bool?
    var isRightPanelVisible: Bool?
    var rightPanelTab: RightPanel?
}

/// Persisted top level: one `SessionSnapshot` per open window, in
/// window-creation order.
private struct AppSnapshot: Codable {
    var windows: [SessionSnapshot]
}

enum SessionStore {
    private static let key = "sessionSnapshot"

    static func save(_ windows: [SessionSnapshot]) {
        do {
            let data = try JSONEncoder().encode(AppSnapshot(windows: windows))
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // A failed encode must be visible: silent success at quit would
            // look like the session was saved when it was not.
            NSLog("SessionStore: failed to encode snapshot: \(error)")
        }
    }

    static func load() -> [SessionSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let app = try? JSONDecoder().decode(AppSnapshot.self, from: data) {
            return app.windows
        }
        // Pre-multi-window format: the snapshot of a single window.
        if let single = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            return [single]
        }
        return []
    }
}
