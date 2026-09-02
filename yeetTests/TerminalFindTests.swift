//
//  TerminalFindTests.swift
//  yeetTests
//

import AppKit
import XCTest
@testable import yeet

@MainActor
final class TerminalFindTests: XCTestCase {
    func testInvalidationRetainsTheLastReportedTotalWhileClearingSelection() {
        let find = TerminalFind(surface: TerminalFindTestSurface())
        find.update(total: 12)
        find.update(selected: 4)

        find.invalidateResults(lastReportedTotal: 12)

        XCTAssertEqual(find.total, 12)
        XCTAssertNil(find.selected)
        XCTAssertTrue(find.isRefreshing)
    }

    func testInvalidationRestoresTheBackendLastReportedTotal() {
        let find = TerminalFind(surface: TerminalFindTestSurface())
        find.update(total: 8)

        find.invalidateResults(lastReportedTotal: 12)

        XCTAssertEqual(find.total, 12)
        XCTAssertTrue(find.isRefreshing)
    }

    func testFreshTotalEndsTheRefreshingState() {
        let find = TerminalFind(surface: TerminalFindTestSurface())
        find.update(total: 12)
        find.invalidateResults()

        find.update(total: 15)

        XCTAssertEqual(find.total, 15)
        XCTAssertFalse(find.isRefreshing)
    }

    func testInvalidatedResultsDoNotNavigateStaleCoordinates() {
        let surface = TerminalFindTestSurface()
        let find = TerminalFind(surface: surface)
        find.started(needle: "needle")
        find.update(total: 12)
        find.invalidateResults()

        find.navigate(forward: true)

        XCTAssertEqual(surface.stepFindCalls, 0)
        find.ended()
    }
}

@MainActor
private final class TerminalFindTestSurface: NSView, TerminalFindSurface {
    var hasSelection = false
    private(set) var stepFindCalls = 0

    func beginFind(_: String) {}
    func endFind() {}
    func stepFind(forward _: Bool) { stepFindCalls += 1 }
    func findSelection() {}
}
