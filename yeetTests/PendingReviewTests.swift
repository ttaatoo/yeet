//
//  PendingReviewTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

@MainActor
final class PendingReviewTests: XCTestCase {
    func testCaptureArmsTheQueueAndZeroClearsIt() {
        let project = Project(fallbackName: "demo", createInitialSession: false)
        let sessionID = UUID()
        project.capturePendingReview(sessionID: sessionID, fileCount: 3)
        XCTAssertEqual(project.pendingReview?.fileCount, 3)
        XCTAssertEqual(project.pendingReview?.sessionID, sessionID)

        project.updatePendingReviewFileCount(1)
        XCTAssertEqual(project.pendingReview?.fileCount, 1)

        project.updatePendingReviewFileCount(0)
        XCTAssertNil(project.pendingReview)
    }

    func testUpdateIsNoOpUntilCaptureArmsTheQueue() {
        let project = Project(fallbackName: "demo", createInitialSession: false)
        project.updatePendingReviewFileCount(4)
        XCTAssertNil(project.pendingReview)
    }

    func testAttentionOrderPutsPendingReviewAheadOfBareDone() {
        let project = Project(fallbackName: "demo", createInitialSession: false)
        let sessionID = UUID()
        project.capturePendingReview(sessionID: sessionID, fileCount: 2)
        let refs = TerminalManager.agentAttentionRefs(in: [project])
        XCTAssertEqual(refs, [
            AgentAttentionRef(
                sessionID: sessionID,
                projectID: project.id,
                kind: .pendingReview
            ),
        ])
    }

    func testEmptyProjectsHaveNoAttention() {
        let project = Project(fallbackName: "demo", createInitialSession: false)
        XCTAssertTrue(TerminalManager.agentAttentionRefs(in: [project]).isEmpty)
    }
}
