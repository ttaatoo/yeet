import Foundation
import XCTest
@testable import yeet

@MainActor
final class GitInspectorWaitTests: XCTestCase {
    func testSatisfiedStateDoesNotTimeOutWithZeroBudget() async throws {
        let value = try await waitUntil(timeout: 0, description: "ready state") {
            true
        } satisfies: { $0 }
        XCTAssertTrue(value)
    }

    func testLastSuccessfulSampleIsCheckedBeforeTheDeadline() async throws {
        var sampleCount = 0
        let value = try await waitUntil(timeout: 1, description: "delayed final sample") {
            sampleCount += 1
            guard sampleCount > 1 else { return false }
            // A busy AppKit turn can delay a successful final sample beyond
            // the polling deadline. Its value must still be checked.
            Thread.sleep(forTimeInterval: 1.05)
            return true
        } satisfies: { $0 }
        XCTAssertTrue(value)
        XCTAssertEqual(sampleCount, 2)
    }

    func testUnresolvedStateStillThrowsWithItsLastValue() async throws {
        do {
            _ = try await waitUntil(timeout: 0, description: "pending state") {
                "pending"
            } satisfies: { $0 == "ready" }
            XCTFail("an unresolved state must time out")
        } catch let error as GitInspectorTimedOut {
            XCTAssertTrue(error.message.contains("pending state"))
            XCTAssertTrue(error.message.contains("last value: pending"))
        }
    }
}
