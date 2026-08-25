//
//  TerminalMetalRendererTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class TerminalMetalRendererTests: XCTestCase {
    func testGenerationChangePlansEveryViewportRowForRebuild() {
        let rowIDs = Array(0..<24).map(UInt64.init)
        let plan = rowIDs.withUnsafeBufferPointer { rowIDs in
            TerminalMetalRenderer.rebuildPlan(
                columns: 80,
                rows: 24,
                cachedColumns: 80,
                cachedRows: 24,
                snapshotRowGeneration: 9,
                cachedRowGeneration: 8,
                atlasGeneration: 3,
                cachedAtlasGeneration: 3,
                needsLiveCensus: false,
                dirtyRows: [2],
                rowIDs: rowIDs.baseAddress,
                cachedRowIDs: rowIDs.map { $0 }
            )
        }

        XCTAssertTrue(plan.isFullCensus)
        XCTAssertEqual(plan.rows, Array(0..<24))
    }
}
