import Foundation

/// Owns the persisted workspace aggregate. Layout and history remain separate
/// physical records because history can be large, but callers use one boundary
/// and one generation marker for each save.
@MainActor
final class WorkspaceStateStore {
    static let shared = WorkspaceStateStore()

    struct Aggregate {
        let snapshots: [SessionSnapshot]
        let histories: [String: String]
        let generation: String?
    }

    private let defaults: UserDefaults
    private let history: TerminalHistoryStore
    private var currentGeneration: String?

    init(
        defaults: UserDefaults = .standard,
        historyURL: URL = TerminalHistoryStore.defaultFileURL
    ) {
        self.defaults = defaults
        history = TerminalHistoryStore(fileURL: historyURL)
    }

    func load() -> Aggregate {
        var layout = SessionStore.load(defaults: defaults)
        let loadedHistory = history.load()
        if layout.generation != loadedHistory.generation,
           let checkpoint = loadedHistory.layout,
           let capturedLayout = try? SessionStore.decode(checkpoint),
           capturedLayout.generation == loadedHistory.generation {
            // The sidecar is the full-save commit point. A crash can leave
            // UserDefaults at the preceding generation; restore the layout
            // written atomically with this transcript instead of dropping it.
            layout = capturedLayout
            SessionStore.commit(checkpoint, defaults: defaults)
        }
        if !loadedHistory.histories.isEmpty,
           layout.windows.isEmpty || layout.generation != loadedHistory.generation {
            // The layout may have been rejected and copied to its recovery
            // key. Keep the matching history bytes too before a new workspace
            // can replace the sidecar.
            history.preserveForRecovery()
        }
        let state = Self.reconcile(layout: layout, history: loadedHistory)
        currentGeneration = state.generation
        return state
    }

    static func reconcile(
        layout: SessionStore.Loaded,
        history: TerminalHistoryStore.Loaded
    ) -> Aggregate {
        let histories: [String: String]
        if layout.windows.isEmpty || history.histories.isEmpty {
            histories = [:]
        } else if layout.generation == history.generation {
            histories = history.histories
        } else {
            NSLog("WorkspaceStateStore: layout/history generations differ; dropping history")
            histories = [:]
        }
        return Aggregate(
            snapshots: layout.windows,
            histories: histories,
            generation: layout.generation
        )
    }

    @discardableResult
    func save(
        snapshots: [SessionSnapshot], histories: [String: String]
    ) -> Bool {
        let generation = UUID().uuidString
        let layout: Data
        do {
            layout = try SessionStore.encode(snapshots, generation: generation)
        } catch {
            NSLog("WorkspaceStateStore: failed to encode layout: \(error)")
            return false
        }
        guard history.save(histories, generation: generation, layout: layout) else {
            return false
        }
        SessionStore.commit(layout, defaults: defaults)
        currentGeneration = generation
        return true
    }

    /// Saves layout changes without rewriting the large history sidecar.
    func saveLayout(_ snapshots: [SessionSnapshot]) {
        SessionStore.save(snapshots, generation: currentGeneration, defaults: defaults)
    }
}
