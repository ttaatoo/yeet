//
//  FileTreeModelTests.swift
//  yeetTests
//
//  Locks the flattened file-tree snapshot that the inspector Files tab
//  renders. Git decorations are applied on top of this list; the AppKit
//  Files panel must not change which paths the tree shows.

import XCTest
@testable import yeet

final class FileTreeModelTests: XCTestCase {
    func testSnapshotListsFilesAndHidesGitDirectory() throws {
        let root = try makeTempDirectory(prefix: "yeet-tree-snap")
        defer { try? FileManager.default.removeItem(at: root) }
        try "a\n".write(
            to: root.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try "print(1)\n".write(
            to: root.appendingPathComponent("src/main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let items = FileTreeModel.snapshot(
            root: root.path, expanded: [], draft: nil
        )
        XCTAssertTrue(items.contains { $0.name == "alpha.txt" && !$0.isDirectory })
        XCTAssertTrue(items.contains { $0.name == "src" && $0.isDirectory && $0.depth == 0 })
        XCTAssertFalse(items.contains { $0.name == "main.swift" })
        XCTAssertFalse(items.contains { $0.name == ".git" })
    }

    func testSnapshotIncludesChildrenOfExpandedDirectories() throws {
        let root = try makeTempDirectory(prefix: "yeet-tree-expand")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try "print(1)\n".write(
            to: root.appendingPathComponent("src/main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let src = root.appendingPathComponent("src").path
        let items = FileTreeModel.snapshot(
            root: root.path, expanded: [src], draft: nil
        )
        XCTAssertTrue(items.contains { $0.name == "src" && $0.isDirectory })
        XCTAssertTrue(items.contains {
            $0.name == "main.swift" && !$0.isDirectory && $0.depth == 1
        })
    }

    func testSnapshotInsertsDraftRowAtTopOfParent() throws {
        let root = try makeTempDirectory(prefix: "yeet-tree-draft")
        defer { try? FileManager.default.removeItem(at: root) }
        try "k\n".write(
            to: root.appendingPathComponent("kept.txt"),
            atomically: true,
            encoding: .utf8
        )

        let items = FileTreeModel.snapshot(
            root: root.path,
            expanded: [],
            draft: FileTreeModel.Draft(parentDir: root.path, isDirectory: false)
        )
        XCTAssertEqual(items.first?.isDraft, true)
        XCTAssertTrue(items.contains { $0.name == "kept.txt" })
    }

    @MainActor
    func testToggleExpandsThenCollapsesDirectory() async throws {
        let root = try makeTempDirectory(prefix: "yeet-tree-toggle")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try "print(1)\n".write(
            to: root.appendingPathComponent("src/main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let tree = FileTreeModel()
        tree.sync(root: root.path)
        let collapsed = try await waitUntil(timeout: 5) {
            tree.items
        } satisfies: { items in
            items.contains { $0.name == "src" && $0.isDirectory }
        }
        let folder = try XCTUnwrap(collapsed.first { $0.name == "src" })
        XCTAssertFalse(tree.isExpanded(folder))

        tree.toggle(folder)
        let expanded = try await waitUntil(timeout: 5) {
            tree.items
        } satisfies: { items in
            items.contains { $0.name == "main.swift" }
        }
        XCTAssertTrue(tree.isExpanded(folder))
        XCTAssertTrue(expanded.contains { $0.name == "main.swift" && $0.depth == 1 })

        tree.toggle(folder)
        let recollapsed = try await waitUntil(timeout: 5) {
            tree.items
        } satisfies: { items in
            !items.contains { $0.name == "main.swift" }
        }
        XCTAssertFalse(tree.isExpanded(folder))
        XCTAssertTrue(recollapsed.contains { $0.name == "src" })
    }
}

private extension FileTreeModelTests {
    func makeTempDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func waitUntil<T>(
        timeout: TimeInterval,
        _ sample: @MainActor () -> T,
        satisfies predicate: (T) -> Bool
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var last = sample()
        while Date() < deadline {
            if predicate(last) { return last }
            try await Task.sleep(for: .milliseconds(50))
            last = sample()
        }
        return last
    }
}
