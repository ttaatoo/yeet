//
//  GitRefNameTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class GitRefNameTests: XCTestCase {
    func testRejectsEmptyAndDashLeading() {
        XCTAssertEqual(GitRefName.sanitizedUserName("   "), .failure(.empty))
        XCTAssertEqual(GitRefName.sanitizedUserName("-hotfix"), .failure(.leadingDash))
        XCTAssertEqual(GitRefName.sanitizedUserName("  feature  "), .success("feature"))
    }

    func testSwitchArgumentsEndOptions() {
        XCTAssertEqual(GitRefName.switchArguments(to: "feature"), ["switch", "--", "feature"])
        XCTAssertNil(GitRefName.switchArguments(to: "-evil"))
        XCTAssertNil(GitRefName.switchArguments(to: ""))
    }

    func testCreateArgumentsDoNotTreatNameAsOption() {
        XCTAssertEqual(
            GitRefName.createArguments(named: "topic"),
            ["switch", "-c", "topic", "--"]
        )
        XCTAssertNil(GitRefName.createArguments(named: "-c"))
    }

    func testLocalFormatRejectsDotDotAndAtBrace() {
        XCTAssertFalse(GitRefName.passesLocalFormat("a..b"))
        XCTAssertFalse(GitRefName.passesLocalFormat("foo@{bar}"))
        XCTAssertFalse(GitRefName.passesLocalFormat("spaces here"))
        XCTAssertTrue(GitRefName.passesLocalFormat("feature/ok"))
    }
}
