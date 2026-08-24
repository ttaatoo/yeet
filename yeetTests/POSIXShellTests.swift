//
//  POSIXShellTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class POSIXShellTests: XCTestCase {
    func testQuoteWrapsAndEscapesSingleQuotes() {
        XCTAssertEqual(POSIXShell.quote("plain"), "'plain'")
        XCTAssertEqual(POSIXShell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(POSIXShell.quote(""), "''")
    }
}
