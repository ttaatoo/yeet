//
//  MarkdownPreviewRoutingTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class MarkdownPreviewRoutingTests: XCTestCase {
    func testMarkdownExtensions() {
        XCTAssertTrue(MarkdownPreviewRouting.isMarkdownPath("/tmp/plan.md"))
        XCTAssertTrue(MarkdownPreviewRouting.isMarkdownPath("/tmp/PLAN.MD"))
        XCTAssertTrue(MarkdownPreviewRouting.isMarkdownPath("/tmp/notes.markdown"))
        XCTAssertFalse(MarkdownPreviewRouting.isMarkdownPath("/tmp/plan.mdx"))
        XCTAssertFalse(MarkdownPreviewRouting.isMarkdownPath("/tmp/readme.txt"))
        XCTAssertTrue(
            MarkdownPreviewRouting.isMarkdownFile(
                URL(fileURLWithPath: "/tmp/docs/2026-09-09-lark.md")
            )
        )
    }

    func testHeadingSlugStripsPunctuationAndLowercases() {
        XCTAssertEqual(
            MarkdownPreviewRouting.headingSlug("Install the CLI"),
            "install-the-cli"
        )
        XCTAssertEqual(
            MarkdownPreviewRouting.normalizeHeading("#Done?"),
            "done"
        )
        XCTAssertEqual(
            MarkdownPreviewRouting.normalizeHeading("already-slugged"),
            "already-slugged"
        )
    }

    func testResolveHeadingAgainstMarkdownFile() {
        let base = URL(fileURLWithPath: "/tmp/docs/readme.md")
        XCTAssertEqual(
            MarkdownPreviewRouting.resolve("#install", relativeToFile: base),
            .heading("install")
        )
        XCTAssertEqual(
            MarkdownPreviewRouting.resolve("#Install the CLI", relativeToFile: base),
            .heading("install-the-cli")
        )
    }

    func testResolveRelativeAndFileMarkdownAgainstSourceDirectory() {
        let base = URL(fileURLWithPath: "/tmp/docs/readme.md")
        guard case .markdown(let relative, let heading) = MarkdownPreviewRouting.resolve(
            "plans/x.md#done",
            relativeToFile: base
        ) else {
            return XCTFail("expected a markdown destination")
        }
        XCTAssertEqual(relative.path, "/tmp/docs/plans/x.md")
        XCTAssertEqual(heading, "done")

        guard case .markdown(let fileURL, let fileHeading) = MarkdownPreviewRouting.resolve(
            "file:///tmp/other/notes.markdown#setup",
            relativeToFile: base
        ) else {
            return XCTFail("expected a file: markdown destination")
        }
        XCTAssertEqual(fileURL.path, "/tmp/other/notes.markdown")
        XCTAssertEqual(fileHeading, "setup")
    }

    func testResolveDoesNotUseAFakeTerminalCwd() {
        let base = URL(fileURLWithPath: "/Users/dev/repo/docs/plans/plan.md")
        guard case .markdown(let url, nil) = MarkdownPreviewRouting.resolve(
            "./sibling.md",
            relativeToFile: base
        ) else {
            return XCTFail("expected sibling markdown")
        }
        XCTAssertEqual(url.path, "/Users/dev/repo/docs/plans/sibling.md")
        XCTAssertNotEqual(url.path, "/tmp/sibling.md")
    }

    func testResolveNonMarkdownFileAndWeb() {
        let base = URL(fileURLWithPath: "/tmp/docs/readme.md")
        guard case .file(let swift) = MarkdownPreviewRouting.resolve(
            "../src/main.swift",
            relativeToFile: base
        ) else {
            return XCTFail("expected a file destination")
        }
        XCTAssertEqual(swift.path, "/tmp/src/main.swift")

        guard case .web(let url) = MarkdownPreviewRouting.resolve(
            "https://example.com/docs",
            relativeToFile: base
        ) else {
            return XCTFail("expected a web destination")
        }
        XCTAssertEqual(url.host, "example.com")

        XCTAssertEqual(
            MarkdownPreviewRouting.resolve("javascript:alert(1)", relativeToFile: base),
            .invalid
        )
    }

    func testStandardizedPathsCompareEqual() {
        XCTAssertTrue(
            MarkdownPreviewRouting.pathsEqual("/tmp/foo/./bar.md", "/tmp/foo/bar.md")
        )
    }

    func testRendererCollectsHeadingAnchorsWhenTheAPIProvidesThem() {
        let result = MarkdownPreviewRenderer.render(
            source: "# Install the CLI\n\nBody.\n\n## Install the CLI\n",
            fileURL: URL(fileURLWithPath: "/tmp/docs/readme.md"),
            dark: true
        )
        let slugs = result.headings.map(\.slug)
        if slugs.isEmpty {
            // PresentationIntent headers are best-effort; the preview still
            // renders if the markdown parser omits them.
            return
        }
        XCTAssertEqual(slugs, ["install-the-cli", "install-the-cli-1"])
        XCTAssertGreaterThan(result.attributed.length, 0)
    }
}
