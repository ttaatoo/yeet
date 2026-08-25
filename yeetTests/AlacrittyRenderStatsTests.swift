//
//  AlacrittyRenderStatsTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class AlacrittyRenderStatsTests: XCTestCase {
    func testSubmittedFrameIsNotCountedAsPresentedUntilDrawablePresents() {
        let stats = AlacrittyRenderStats(enabled: true)

        stats.recordFrame(rebuiltRows: 24, packedInstances: 480, submitted: true)

        XCTAssertEqual(stats.snapshot().submittedFrames, 1)
        XCTAssertEqual(stats.snapshot().presentedFrames, 0)

        stats.recordPresented(displayOffset: 17, at: 42.5)

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.presentedFrames, 1)
        XCTAssertEqual(snapshot.lastPresented?.displayOffset, 17)
        XCTAssertEqual(snapshot.lastPresented?.timestamp, 42.5)
    }

    func testRenderStatsKeepsActualRebuildAndPackedCounts() {
        let stats = AlacrittyRenderStats(enabled: true)

        stats.recordFrame(rebuiltRows: 6, packedInstances: 143, submitted: true)
        stats.recordFrame(rebuiltRows: 0, packedInstances: 0, submitted: false)
        stats.recordCompleted(success: true)
        stats.recordCompleted(success: false)

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.submittedFrames, 1)
        XCTAssertEqual(snapshot.rejectedFrames, 1)
        XCTAssertEqual(snapshot.completedFrames, 1)
        XCTAssertEqual(snapshot.failedCompletions, 1)
        XCTAssertEqual(snapshot.rebuiltRows, 6)
        XCTAssertEqual(snapshot.packedInstances, 143)
    }

    func testPresentationObservationIsOptInAndPublishesEachValidPresentedFrame() {
        let stats = AlacrittyRenderStats(enabled: false)

        stats.recordPresented(displayOffset: 1, at: 10)
        XCTAssertEqual(stats.snapshot().presentedFrames, 0)

        stats.startPresentationObservation()
        stats.recordPresented(displayOffset: 1, at: 10)
        stats.recordPresented(displayOffset: 2, at: 11)
        stats.recordPresented(displayOffset: 3, at: 0)

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.presentedFrames, 2)
        XCTAssertEqual(snapshot.invalidPresentedTimes, 1)
        XCTAssertEqual(
            stats.presentedFrames(since: 1).map(\.displayOffset),
            [2]
        )
        XCTAssertEqual(snapshot.lastPresented?.displayOffset, 2)
        XCTAssertEqual(snapshot.lastPresented?.timestamp, 11)

        stats.stopPresentationObservation()
        stats.recordPresented(displayOffset: 4, at: 12)
        XCTAssertEqual(stats.snapshot().presentedFrames, 2)
    }

    func testBridgeTimingSnapshotKeepsBusyAndPhaseTotals() {
        let stats = AlacrittyRenderStats(enabled: true)

        stats.recordBridgeFrame(
            busy: true,
            busyCount: 7,
            lockWaitNs: 11,
            snapshotNs: 13,
            buildNs: 17,
            packedRows: 19
        )
        stats.recordBridgeFrame(
            busy: false,
            busyCount: 8,
            lockWaitNs: 23,
            snapshotNs: 29,
            buildNs: 31,
            packedRows: 37
        )

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.bridgeAttempts, 2)
        XCTAssertEqual(snapshot.bridgeBusyAttempts, 1)
        XCTAssertEqual(snapshot.bridgeBusyCount, 8)
        XCTAssertEqual(snapshot.bridgeLockWaitNs, 34)
        XCTAssertEqual(snapshot.bridgeSnapshotNs, 42)
        XCTAssertEqual(snapshot.bridgeBuildNs, 48)
        XCTAssertEqual(snapshot.bridgePackedRows, 56)
    }

    func testReportingClearsOnlyTheWindowAndKeepsCumulativeSnapshot() {
        let stats = AlacrittyRenderStats(enabled: true)

        stats.recordFrame(rebuiltRows: 2, packedInstances: 5, submitted: true)
        stats.flushForTesting()
        stats.recordFrame(rebuiltRows: 3, packedInstances: 7, submitted: true)
        stats.flushForTesting()

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.submittedFrames, 2)
        XCTAssertEqual(snapshot.rebuiltRows, 5)
        XCTAssertEqual(snapshot.packedInstances, 12)
    }
}
