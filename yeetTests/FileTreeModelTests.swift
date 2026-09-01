//
//  FileTreeModelTests.swift
//  yeetTests
//
//  Locks the flattened file-tree snapshot that the inspector Files tab
//  renders. Git decorations are applied on top of this list; a later Git
//  panel rewrite must not change which paths the tree shows.

import XCTest
@testable import yeet

final class FileTreeModelTests: XCTestCase {
    func testSnapshotListsFilesAndHidesGitDirectory() throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-tree-snap",
            files: [
                "alpha.txt": "a\n",
                "src/main.swift": "print(1)\n",
            ]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let items = FileTreeModel.snapshot(
            root: repo.path, expanded: [], draft: nil
        )
        XCTAssertTrue(items.contains { $0.name == "alpha.txt" && !$0.isDirectory })
        XCTAssertTrue(items.contains { $0.name == "src" && $0.isDirectory && $0.depth == 0 })
        XCTAssertFalse(items.contains { $0.name == "main.swift" })
        XCTAssertFalse(items.contains { $0.name == ".git" })
    }

    func testSnapshotIncludesChildrenOfExpandedDirectories() throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-tree-expand",
            files: ["src/main.swift": "print(1)\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let src = repo.url("src").path
        let items = FileTreeModel.snapshot(
            root: repo.path, expanded: [src], draft: nil
        )
        XCTAssertTrue(items.contains { $0.name == "src" && $0.isDirectory })
        XCTAssertTrue(items.contains {
            $0.name == "main.swift" && !$0.isDirectory && $0.depth == 1
        })
    }

    func testSnapshotInsertsDraftRowAtTopOfParent() throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-tree-draft",
            files: ["kept.txt": "k\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let items = FileTreeModel.snapshot(
            root: repo.path,
            expanded: [],
            draft: FileTreeModel.Draft(parentDir: repo.path, isDirectory: false)
        )
        XCTAssertEqual(items.first?.isDraft, true)
        XCTAssertTrue(items.contains { $0.name == "kept.txt" })
    }

    @MainActor
    func testToggleExpandsThenCollapsesDirectory() async throws {
        let repo = try GitInspectorFixtures.makeRepository(
            prefix: "yeet-tree-toggle",
            files: ["src/main.swift": "print(1)\n"]
        )
        defer { try? FileManager.default.removeItem(at: repo.root) }

        let tree = FileTreeModel()
        tree.sync(root: repo.path)
        let collapsed = try await waitUntil(description: "root listing") {
            tree.items
        } satisfies: { items in
            items.contains { $0.name == "src" && $0.isDirectory }
        }
        let folder = try XCTUnwrap(collapsed.first { $0.name == "src" })
        XCTAssertFalse(tree.isExpanded(folder))

        tree.toggle(folder)
        let expanded = try await waitUntil(description: "expanded src") {
            tree.items
        } satisfies: { items in
            items.contains { $0.name == "main.swift" }
        }
        XCTAssertTrue(tree.isExpanded(folder))
        XCTAssertTrue(expanded.contains { $0.name == "main.swift" && $0.depth == 1 })

        tree.toggle(folder)
        let recollapsed = try await waitUntil(description: "collapsed src") {
            tree.items
        } satisfies: { items in
            !items.contains { $0.name == "main.swift" }
        }
        XCTAssertFalse(tree.isExpanded(folder))
        XCTAssertTrue(recollapsed.contains { $0.name == "src" })
    }
}
