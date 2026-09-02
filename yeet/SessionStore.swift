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
        /// A single pane's content: the terminal, file, browser, or diff it
        /// holds. Optional fields added after v0.1.47 keep that format readable.
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
        /// position.
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
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                layout = try container.decode(LayoutSnapshot.self, forKey: .layout)
                focusedPaneIndex =
                    (try? container.decode(Int.self, forKey: .focusedPaneIndex)) ?? 0
                customName = try? container.decode(String.self, forKey: .customName)
                contextSessionIndex = try? container.decode(
                    Int.self, forKey: .contextSessionIndex
                )
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
/// window-creation order. The only unversioned input supported is the
/// recursive multi-window format written by v0.1.47 and later.
private struct AppSnapshot: Codable {
    static let currentVersion = 1
    var version: Int
    var generation: String?
    var windows: [SessionSnapshot]

    init(windows: [SessionSnapshot], generation: String? = nil) {
        version = Self.currentVersion
        self.generation = generation
        self.windows = windows
    }

    enum CodingKeys: String, CodingKey { case version, generation, windows }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentVersion
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "Unsupported workspace snapshot version \(version)"
            )
        }
        self.version = version
        generation = try container.decodeIfPresent(String.self, forKey: .generation)
        windows = try container.decode([SessionSnapshot].self, forKey: .windows)
    }
}

enum SessionStore {
    private static let key = "sessionSnapshot"
    private static let recoveryKey = "sessionSnapshotRecovery"

    struct Loaded {
        let windows: [SessionSnapshot]
        let generation: String?
    }

    @discardableResult
    static func save(
        _ windows: [SessionSnapshot],
        generation: String? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        do {
            let data = try encode(windows, generation: generation)
            defaults.set(data, forKey: key)
            return true
        } catch {
            // A failed encode must be visible: silent success at quit would
            // look like the session was saved when it was not.
            NSLog("SessionStore: failed to encode snapshot: \(error)")
            return false
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Loaded {
        guard let data = defaults.data(forKey: key) else {
            return Loaded(windows: [], generation: nil)
        }
        if let loaded = try? decode(data) {
            return loaded
        }
        // The next autosave can replace the active key. Keep the rejected
        // bytes separately so starting a fresh workspace does not erase them.
        defaults.set(data, forKey: recoveryKey)
        NSLog("SessionStore: unsupported or corrupt workspace snapshot; copied to \(recoveryKey)")
        return Loaded(windows: [], generation: nil)
    }

    static func encode(
        _ windows: [SessionSnapshot], generation: String?
    ) throws -> Data {
        try JSONEncoder().encode(AppSnapshot(windows: windows, generation: generation))
    }

    static func decode(_ data: Data) throws -> Loaded {
        let app = try JSONDecoder().decode(AppSnapshot.self, from: data)
        return Loaded(windows: app.windows, generation: app.generation)
    }
}
