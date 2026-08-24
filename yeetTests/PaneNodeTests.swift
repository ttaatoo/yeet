//
//  PaneNodeTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

@MainActor
final class PaneNodeTests: XCTestCase {
    func testInsertAndRemoveCollapseSplit() {
        let first = Pane(content: .file(FileTab(path: "/tmp/kero-pane-a.swift")))
        let second = Pane(content: .file(FileTab(path: "/tmp/kero-pane-b.swift")))
        var node = PaneNode.pane(first)
        node = node.inserting(second, toward: .right, beside: first.id)

        guard case .split(let split) = node else {
            return XCTFail("insert should create a split")
        }
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(node.allPanes.count, 2)

        let removed = node.removingPane(second.id)
        XCTAssertEqual(removed.pane?.id, second.id)
        guard case .pane(let remaining) = removed.node else {
            return XCTFail("removing one side should collapse the split")
        }
        XCTAssertEqual(remaining.id, first.id)
    }
}
