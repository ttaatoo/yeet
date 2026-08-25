//
//  AlacrittyFindTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class AlacrittyFindTests: XCTestCase {
    func testLatestRequestUsesTheAlreadyScheduledPoll() {
        var state = AlacrittyFindPollState()
        state.replacePending(generation: 1)
        let token = try! XCTUnwrap(state.armPoll())

        // A fast step or a new query replaces the request while the first
        // main-queue callback is still scheduled.
        state.replacePending(generation: 2)
        state.replacePending(generation: 3)
        XCTAssertNil(state.armPoll())
        XCTAssertEqual(state.beginPoll(token: token), 3)
    }

    func testCancelInvalidatesAStaleCallbackBeforeItCanPoll() {
        var state = AlacrittyFindPollState()
        state.replacePending(generation: 4)
        let staleToken = try! XCTUnwrap(state.armPoll())

        state.cancel()

        XCTAssertNil(state.beginPoll(token: staleToken))
        XCTAssertNil(state.pendingGeneration)
        XCTAssertFalse(state.pollScheduled)
    }

    func testARequestAfterCancelGetsItsOwnCallbackToken() {
        var state = AlacrittyFindPollState()
        state.replacePending(generation: 6)
        let staleToken = try! XCTUnwrap(state.armPoll())
        state.cancel()

        state.replacePending(generation: 7)
        let currentToken = try! XCTUnwrap(state.armPoll())

        XCTAssertNotEqual(staleToken, currentToken)
        XCTAssertNil(state.beginPoll(token: staleToken))
        XCTAssertEqual(state.beginPoll(token: currentToken), 7)
    }

    func testWakeCancelsQueuedPollWithoutDroppingPendingGeneration() {
        var state = AlacrittyFindPollState()
        state.replacePending(generation: 8)
        let token = try! XCTUnwrap(state.armPoll())

        XCTAssertEqual(state.cancelScheduledPoll(), 8)
        XCTAssertFalse(state.pollScheduled)
        XCTAssertEqual(state.pendingGeneration, 8)
        XCTAssertNil(state.beginPoll(token: token))

        let replacement = try! XCTUnwrap(state.armPoll())
        XCTAssertEqual(state.beginPoll(token: replacement), 8)
    }

    func testInvalidatedFindRefreshIsDebouncedPerGeneration() {
        var state = AlacrittyFindRefreshState()
        state.activate(generation: 10)

        XCTAssertTrue(state.schedule(generation: 10))
        XCTAssertFalse(state.schedule(generation: 10))
        XCTAssertFalse(state.schedule(generation: 9))
        XCTAssertFalse(state.begin(generation: 9))
        XCTAssertTrue(state.begin(generation: 10))

        // A new generation can own one new refresh after the previous one
        // starts; repeated invalidations for the same generation stay coalesced.
        state.activate(generation: 11)
        XCTAssertTrue(state.schedule(generation: 11))
        XCTAssertFalse(state.schedule(generation: 11))
        state.cancel()
        XCTAssertFalse(state.schedule(generation: 11))
    }
}
