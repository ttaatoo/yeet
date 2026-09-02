import Foundation
import XCTest
@testable import yeet

@MainActor
final class WorkspaceStateStoreTests: XCTestCase {
    private typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot

    func testVersionedMultiWindowSnapshotRoundTrips() throws {
        let data = try SessionStore.encode(
            [snapshot(directory: "/tmp/one"), snapshot(directory: "/tmp/two")],
            generation: "capture-1"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["generation"] as? String, "capture-1")

        let loaded = try SessionStore.decode(data)
        XCTAssertEqual(loaded.windows.count, 2)
        XCTAssertEqual(loaded.generation, "capture-1")
        let tab = try XCTUnwrap(loaded.windows.first?.projects.first?.tabs.first)
        XCTAssertEqual(tab.focusedPaneIndex, 1)
        guard case .split(let axis, let fraction, let first, _) = tab.layout,
              case .pane(let pane) = first else {
            return XCTFail("expected a recursive split")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(fraction, 0.4)
        XCTAssertEqual(pane.historyKey, "history-1")
    }

    func testUnversionedCurrentFormatRemainsReadable() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: SessionStore.encode(
                [snapshot()], generation: nil
            )) as? [String: Any]
        )
        object.removeValue(forKey: "version")
        let loaded = try SessionStore.decode(
            JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(loaded.windows.count, 1)
        XCTAssertNil(loaded.generation)
    }

    func testUnknownSnapshotVersionsAreRejected() throws {
        for version in [-1, 0, 2] {
            let data = try JSONSerialization.data(withJSONObject: [
                "version": version,
                "windows": [],
            ])
            XCTAssertThrowsError(try SessionStore.decode(data))
        }
    }

    func testRetiredSingleWindowFormatIsRejected() throws {
        let data = try JSONEncoder().encode(snapshot())
        XCTAssertThrowsError(try SessionStore.decode(data))
    }

    func testRetiredTabFormatsAreRejected() throws {
        let singleContent: [String: Any] = ["workingDirectory": "/tmp/old"]
        let columns: [String: Any] = [
            "columns": [[
                "panes": [["content": singleContent, "weight": 1]],
                "weight": 1,
            ]],
            "focusedColumn": 0,
            "focusedRow": 0,
        ]
        for tab in [singleContent, columns] {
            let data = try JSONSerialization.data(withJSONObject: [
                "windows": [["projects": [["tabs": [tab]]]]],
            ])
            XCTAssertThrowsError(try SessionStore.decode(data))
        }
    }

    func testRejectedSnapshotSurvivesTheNextSave() throws {
        let suite = "sh.yeet.tests.workspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rejected = Data("{\"version\":99,\"windows\":[]}".utf8)
        defaults.set(rejected, forKey: "sessionSnapshot")

        XCTAssertTrue(SessionStore.load(defaults: defaults).windows.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "sessionSnapshot"), rejected)
        XCTAssertTrue(SessionStore.save(
            [snapshot()], generation: "new", defaults: defaults
        ))
        XCTAssertEqual(defaults.data(forKey: "sessionSnapshotRecovery"), rejected)
        XCTAssertEqual(SessionStore.load(defaults: defaults).generation, "new")
    }

    func testFailedEncodeDoesNotReplaceSavedLayout() throws {
        let suite = "sh.yeet.tests.workspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SessionStore.save(
            [snapshot()], generation: "valid", defaults: defaults
        ))
        let previous = defaults.data(forKey: "sessionSnapshot")

        var invalid = snapshot()
        invalid.projects[0].tabs[0].layout = .split(
            axis: .horizontal,
            fraction: .nan,
            first: .pane(.init(content: .browser(url: nil), weight: 1)),
            second: .pane(.init(content: .browser(url: nil), weight: 1))
        )
        XCTAssertFalse(SessionStore.save(
            [invalid], generation: "invalid", defaults: defaults
        ))
        XCTAssertEqual(defaults.data(forKey: "sessionSnapshot"), previous)
    }

    func testLayoutChangesCanReuseHistoryGeneration() throws {
        let first = try SessionStore.decode(
            SessionStore.encode([snapshot(directory: "/tmp/one")], generation: "history")
        )
        let second = try SessionStore.decode(
            SessionStore.encode([snapshot(directory: "/tmp/two")], generation: first.generation)
        )
        XCTAssertEqual(second.generation, "history")
    }

    func testHistoryArchiveRoundTrips() throws {
        let histories = ["history-1": "\u{1b}[31mred\u{1b}[0m\n"]
        let data = try TerminalHistoryStore.encode(histories, generation: "capture-1")
        let loaded = try TerminalHistoryStore.decode(data)
        XCTAssertEqual(loaded.generation, "capture-1")
        XCTAssertEqual(loaded.histories, histories)
        XCTAssertEqual(
            data, try TerminalHistoryStore.encode(histories, generation: "capture-1")
        )
    }

    func testUnversionedLayoutAndHistoryRemainPaired() throws {
        let histories = ["history-1": "old output\n"]
        let history = try TerminalHistoryStore.decode(JSONEncoder().encode(histories))
        let state = WorkspaceStateStore.reconcile(
            layout: .init(windows: [snapshot()], generation: nil),
            history: history
        )
        XCTAssertNil(history.generation)
        XCTAssertEqual(state.histories, histories)
    }

    func testMatchingGenerationsRestoreHistory() {
        let histories = ["history-1": "output\n"]
        let state = WorkspaceStateStore.reconcile(
            layout: .init(windows: [snapshot()], generation: "same"),
            history: .init(generation: "same", histories: histories)
        )
        XCTAssertEqual(state.snapshots.count, 1)
        XCTAssertEqual(state.histories, histories)
    }

    func testMismatchedGenerationsKeepLayoutWithoutHistory() {
        for historyGeneration in ["older", nil] {
            let state = WorkspaceStateStore.reconcile(
                layout: .init(windows: [snapshot()], generation: "newer"),
                history: .init(
                    generation: historyGeneration,
                    histories: ["history-1": "stale output\n"]
                )
            )
            XCTAssertEqual(state.snapshots.count, 1)
            XCTAssertEqual(state.generation, "newer")
            XCTAssertTrue(state.histories.isEmpty)
        }
    }

    func testMissingHistoryAndEmptyLayoutDoNotRestoreStaleOutput() throws {
        XCTAssertTrue(try TerminalHistoryStore.encode([:], generation: "empty").isEmpty)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = TerminalHistoryStore(
            fileURL: directory.appendingPathComponent("missing.json")
        ).load()
        let state = WorkspaceStateStore.reconcile(
            layout: .init(windows: [snapshot()], generation: "layout-only"),
            history: missing
        )
        XCTAssertTrue(state.histories.isEmpty)
        XCTAssertEqual(state.snapshots.count, 1)

        let empty = WorkspaceStateStore.reconcile(
            layout: .init(windows: [], generation: nil),
            history: .init(generation: nil, histories: ["history-1": "stale"])
        )
        XCTAssertTrue(empty.histories.isEmpty)
    }

    func testCorruptHistoryIsPreservedForRecovery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)

        let loaded = TerminalHistoryStore(fileURL: url).load()
        XCTAssertTrue(loaded.histories.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("recovery")), corrupt)
    }

    func testLayoutAutosavePreservesCapturedHistoryAndGeneration() throws {
        try withStore { store, defaults, historyURL in
            XCTAssertTrue(store.load().snapshots.isEmpty)
            let histories = ["history-1": "saved terminal output"]
            store.save(snapshots: [snapshot()], histories: histories)
            store.waitForPendingWrites()
            let capture = store.load()
            XCTAssertNotNil(capture.generation)
            let bytes = try Data(contentsOf: historyURL)
            let unchangedDate = Date(timeIntervalSince1970: 1)
            try FileManager.default.setAttributes(
                [.modificationDate: unchangedDate], ofItemAtPath: historyURL.path
            )

            store.saveLayout([snapshot(directory: "/tmp/renamed")])
            store.waitForPendingWrites()

            let reopened = WorkspaceStateStore(defaults: defaults, historyURL: historyURL).load()
            XCTAssertEqual(reopened.histories, histories)
            XCTAssertEqual(reopened.generation, capture.generation)
            XCTAssertEqual(reopened.snapshots.first?.projects.first?.customDirectory, "/tmp/renamed")
            XCTAssertEqual(try Data(contentsOf: historyURL), bytes)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: historyURL.path)[.modificationDate] as? Date,
                unchangedDate
            )
        }
    }

    func testRepeatedCapturesKeepTheLatestMultiWindowAggregate() throws {
        try withStore { store, defaults, historyURL in
            for index in 0..<5 {
                store.save(
                    snapshots: [snapshot(directory: "/tmp/\(index)"), snapshot(directory: "/tmp/other")],
                    histories: ["history-1": "capture \(index)", "history-2": "other window"]
                )
            }
            store.waitForPendingWrites()

            let reopened = WorkspaceStateStore(defaults: defaults, historyURL: historyURL).load()
            XCTAssertEqual(reopened.snapshots.count, 2)
            XCTAssertEqual(reopened.snapshots.first?.projects.first?.customDirectory, "/tmp/4")
            XCTAssertEqual(reopened.histories, ["history-1": "capture 4", "history-2": "other window"])
            XCTAssertEqual(
                try TerminalHistoryStore.decode(Data(contentsOf: historyURL)).generation,
                reopened.generation
            )
        }
    }

    func testFullSaveWithNoHistoryRemovesTheSidecar() throws {
        try withStore { store, _, historyURL in
            store.save(snapshots: [snapshot()], histories: ["history-1": "output"])
            store.waitForPendingWrites()
            XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))

            store.save(snapshots: [snapshot()], histories: [:])
            store.waitForPendingWrites()

            XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
            XCTAssertTrue(store.load().histories.isEmpty)
            XCTAssertEqual(store.load().snapshots.count, 1)
        }
    }

    func testUnversionedAggregateMigratesThroughTheOwner() throws {
        try withStore { store, defaults, historyURL in
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: SessionStore.encode([snapshot()], generation: nil))
                    as? [String: Any]
            )
            object.removeValue(forKey: "version")
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "sessionSnapshot")
            let histories = ["history-1": "unversioned output"]
            try JSONEncoder().encode(histories).write(to: historyURL)
            let legacy = store.load()
            XCTAssertNil(legacy.generation)
            XCTAssertEqual(legacy.histories, histories)

            store.save(snapshots: legacy.snapshots, histories: legacy.histories)
            store.waitForPendingWrites()
            let reopened = WorkspaceStateStore(defaults: defaults, historyURL: historyURL).load()
            XCTAssertNotNil(reopened.generation)
            XCTAssertEqual(reopened.histories, histories)
            XCTAssertEqual(reopened.snapshots.count, 1)
        }
    }

    func testFailedLayoutEncodeKeepsThePreviousAggregate() throws {
        try withStore { store, defaults, historyURL in
            store.save(snapshots: [snapshot()], histories: ["history-1": "valid"])
            store.waitForPendingWrites()
            let previousLayout = defaults.data(forKey: "sessionSnapshot")
            let previousHistory = try Data(contentsOf: historyURL)
            var invalid = snapshot()
            invalid.projects[0].tabs[0].layout = .split(
                axis: .horizontal, fraction: .nan,
                first: .pane(.init(content: .browser(url: nil), weight: 1)),
                second: .pane(.init(content: .browser(url: nil), weight: 1))
            )

            store.save(snapshots: [invalid], histories: ["history-1": "invalid"])
            store.waitForPendingWrites()

            XCTAssertEqual(defaults.data(forKey: "sessionSnapshot"), previousLayout)
            XCTAssertEqual(try Data(contentsOf: historyURL), previousHistory)
            XCTAssertEqual(store.load().histories, ["history-1": "valid"])
        }
    }

    func testFailedRecoveryCopyPreventsHistoryOverwrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let corrupt = Data("unreadable JSON".utf8)
        try corrupt.write(to: url)
        try FileManager.default.createDirectory(
            at: url.appendingPathExtension("recovery"), withIntermediateDirectories: false
        )
        let history = TerminalHistoryStore(fileURL: url)
        XCTAssertTrue(history.load().histories.isEmpty)

        history.save(["history-1": "replacement"], generation: "new")
        history.waitForPendingWrites()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testRejectedLayoutPreservesItsValidHistoryBeforeAReplacementSave() throws {
        try withStore { store, defaults, historyURL in
            let rejected = Data("{\"version\":99,\"windows\":[]}".utf8)
            defaults.set(rejected, forKey: "sessionSnapshot")
            let oldHistory = try TerminalHistoryStore.encode(
                ["history-1": "recoverable output"], generation: "old"
            )
            try oldHistory.write(to: historyURL)
            XCTAssertTrue(store.load().histories.isEmpty)

            store.save(snapshots: [snapshot()], histories: [:])
            store.waitForPendingWrites()

            XCTAssertEqual(defaults.data(forKey: "sessionSnapshotRecovery"), rejected)
            let recoveryURL = historyURL.appendingPathExtension("recovery")
            XCTAssertEqual(try Data(contentsOf: recoveryURL), oldHistory)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: recoveryURL.path)[.posixPermissions] as? Int,
                0o600
            )
        }
    }

    private func withStore(
        _ body: (WorkspaceStateStore, UserDefaults, URL) throws -> Void
    ) throws {
        let suite = "sh.yeet.tests.workspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = try temporaryDirectory()
        let historyURL = directory.appendingPathComponent("history.json")
        let store = WorkspaceStateStore(defaults: defaults, historyURL: historyURL)
        defer {
            store.waitForPendingWrites()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(store, defaults, historyURL)
    }

    private func snapshot(directory: String = "/tmp/repo") -> SessionSnapshot {
        let terminal = ProjectSnapshot.PaneSnapshot(
            content: .session(
                workingDirectory: directory, agentKind: nil, agentSessionID: nil
            ),
            weight: 1,
            historyKey: "history-1"
        )
        let file = ProjectSnapshot.PaneSnapshot(
            content: .file(path: directory + "/file.swift", editorState: nil),
            weight: 1
        )
        let tab = ProjectSnapshot.TabSnapshot(
            layout: .split(
                axis: .horizontal, fraction: 0.4,
                first: .pane(terminal), second: .pane(file)
            ),
            focusedPaneIndex: 1
        )
        return SessionSnapshot(
            projects: [.init(
                customName: "Project", customDirectory: directory,
                tabs: [tab], selectedTabIndex: 0
            )],
            selectedProjectIndex: 0,
            isLeftSidebarVisible: true,
            isRightPanelVisible: false,
            rightPanelTab: .files
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yeet-workspace-tests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
