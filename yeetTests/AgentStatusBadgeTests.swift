//
//  AgentStatusBadgeTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

@MainActor
final class AgentStatusBadgeTests: XCTestCase {
    func testCreatedUsesStartingArcWithoutDashOrSpin() {
        let badge = AgentStatusBadgeView(frame: .zero)
        badge.apply(phase: .created, count: 1)
        badge.layout()

        XCTAssertFalse(badge.debugRingHidden)
        XCTAssertFalse(badge.debugArcHidden)
        XCTAssertFalse(badge.debugRingHasDash)
        XCTAssertTrue(badge.debugUsesStartingArc)
        XCTAssertFalse(badge.debugUsesWorkingArc)
        XCTAssertFalse(badge.debugSpinnerRunning)
    }

    func testWorkingUsesLongArc() {
        let badge = AgentStatusBadgeView(frame: .zero)
        badge.apply(phase: .working, count: 1)
        badge.layout()

        XCTAssertFalse(badge.debugRingHidden)
        XCTAssertFalse(badge.debugArcHidden)
        XCTAssertFalse(badge.debugRingHasDash)
        XCTAssertTrue(badge.debugUsesWorkingArc)
        XCTAssertFalse(badge.debugUsesStartingArc)
    }

    func testSwitchingCreatedToWorkingReplacesTheShortArc() {
        let badge = AgentStatusBadgeView(frame: .zero)
        badge.apply(phase: .created, count: 1)
        XCTAssertTrue(badge.debugUsesStartingArc)

        badge.apply(phase: .working, count: 1)
        XCTAssertTrue(badge.debugUsesWorkingArc)
        XCTAssertFalse(badge.debugUsesStartingArc)
    }

    func testIdleHidesTheArc() {
        let badge = AgentStatusBadgeView(frame: .zero)
        badge.apply(phase: .created, count: 1)
        badge.apply(phase: .idle, count: 1)

        XCTAssertFalse(badge.debugRingHidden)
        XCTAssertTrue(badge.debugArcHidden)
        XCTAssertFalse(badge.debugRingHasDash)
        XCTAssertFalse(badge.debugSpinnerRunning)
    }

    func testCreatedCountDoesNotChangeTheArc() {
        let badge = AgentStatusBadgeView(frame: .zero)
        badge.apply(phase: .created, count: 3)
        badge.layout()

        XCTAssertTrue(badge.debugUsesStartingArc)
        XCTAssertEqual(
            badge.intrinsicContentSize.height,
            15,
            "Created chrome stays the ring-height badge, not a capsule."
        )
    }
}
