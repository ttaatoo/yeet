//
//  AlacrittyRendererTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class AlacrittyRendererTests: XCTestCase {
    private let paneBackground: UInt32 = 0x0B0A09
    private let selection: UInt32 = 0x5C2418
    private let foreground: UInt32 = 0xE8E2DC
    /// Matches `KERO_CELL_INVERSE` / `KERO_CELL_SELECTED` in `kero_alacritty.h`.
    private let inverseFlag: UInt16 = 1 << 0
    private let selectedFlag: UInt16 = 1 << 9

    func testSelectedCellUsesThemeSelectionBackgroundNotReverseVideo() {
        XCTAssertEqual(
            AlacrittyRenderer.resolvedBackground(
                fg: foreground, bg: paneBackground, flags: selectedFlag,
                default: paneBackground, selection: selection
            ),
            selection
        )
        XCTAssertEqual(
            AlacrittyRenderer.resolvedForeground(
                fg: foreground, bg: paneBackground, flags: selectedFlag,
                default: paneBackground
            ),
            foreground
        )
    }

    func testSelectedInverseCellKeepsGlyphColorAndUsesSelectionFill() {
        let flags = inverseFlag | selectedFlag
        XCTAssertEqual(
            AlacrittyRenderer.resolvedBackground(
                fg: foreground, bg: paneBackground, flags: flags,
                default: paneBackground, selection: selection
            ),
            selection
        )
        XCTAssertEqual(
            AlacrittyRenderer.resolvedForeground(
                fg: foreground, bg: paneBackground, flags: flags,
                default: paneBackground
            ),
            paneBackground
        )
    }

    func testUnselectedInverseCellStillSwapsFill() {
        XCTAssertEqual(
            AlacrittyRenderer.resolvedBackground(
                fg: foreground, bg: paneBackground, flags: inverseFlag,
                default: paneBackground, selection: selection
            ),
            foreground
        )
        XCTAssertEqual(
            AlacrittyRenderer.resolvedForeground(
                fg: foreground, bg: paneBackground, flags: inverseFlag,
                default: paneBackground
            ),
            paneBackground
        )
    }

    func testSelectionDoesNotFloodPanePadding() {
        XCTAssertFalse(AlacrittyRenderer.shouldFloodPadding(flags: selectedFlag))
        XCTAssertFalse(AlacrittyRenderer.shouldFloodPadding(flags: inverseFlag | selectedFlag))
        XCTAssertTrue(AlacrittyRenderer.shouldFloodPadding(flags: 0))
        XCTAssertTrue(AlacrittyRenderer.shouldFloodPadding(flags: inverseFlag))
    }

    func testPackedSelectionHexMatchesYeetDark() {
        XCTAssertEqual(AlacrittyRenderer.packed(hex: "5C2418"), 0x5C2418)
        XCTAssertEqual(AlacrittyRenderer.packed(hex: "#F0C2B0"), 0xF0C2B0)
        XCTAssertEqual(AlacrittyRenderer.packed(hex: "bad"), 0)
    }
}
