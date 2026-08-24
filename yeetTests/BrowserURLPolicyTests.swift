//
//  BrowserURLPolicyTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class BrowserURLPolicyTests: XCTestCase {
    func testDestinationAllowsHttpAndAboutBlank() {
        XCTAssertEqual(
            BrowserURLPolicy.destination(for: "https://example.com")?.scheme,
            "https"
        )
        XCTAssertEqual(
            BrowserURLPolicy.destination(for: "about:blank")?.absoluteString,
            "about:blank"
        )
        XCTAssertNil(BrowserURLPolicy.destination(for: "file:///etc/passwd"))
        XCTAssertNil(BrowserURLPolicy.destination(for: "data:text/html,hi"))
        XCTAssertNil(BrowserURLPolicy.destination(for: "javascript:alert(1)"))
    }

    func testBareHostGainsHttps() {
        XCTAssertEqual(
            BrowserURLPolicy.destination(for: "example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            BrowserURLPolicy.destination(for: "localhost:8080")?.scheme,
            "http"
        )
    }

    func testSearchFallback() {
        let url = BrowserURLPolicy.destination(for: "how to yeet")
        XCTAssertEqual(url?.host, "www.google.com")
    }

    func testWebViewPolicy() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        let file = try XCTUnwrap(URL(string: "file:///tmp/x"))
        let data = try XCTUnwrap(URL(string: "data:text/plain,hi"))
        let blank = try XCTUnwrap(URL(string: "about:blank"))
        XCTAssertTrue(BrowserURLPolicy.allowsWebViewNavigation(https))
        XCTAssertTrue(BrowserURLPolicy.allowsWebViewNavigation(blank))
        XCTAssertFalse(BrowserURLPolicy.allowsWebViewNavigation(file))
        XCTAssertFalse(BrowserURLPolicy.allowsWebViewNavigation(data))
        XCTAssertFalse(BrowserURLPolicy.shouldOpenExternally(file))
    }

    func testTerminalLinksPreferHttpHttps() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        let javascript = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        XCTAssertTrue(BrowserURLPolicy.allowsTerminalWebURL(https))
        XCTAssertFalse(BrowserURLPolicy.allowsTerminalWebURL(javascript))
    }

    func testQuoteAndDotDotAreNotFileSchemes() {
        XCTAssertNil(BrowserURLPolicy.destination(for: "file://../etc/passwd"))
        XCTAssertNotNil(BrowserURLPolicy.destination(for: "example.com/../ok"))
    }
}
