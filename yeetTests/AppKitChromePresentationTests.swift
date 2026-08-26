//
//  AppKitChromePresentationTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

@MainActor
final class AppKitChromePresentationTests: XCTestCase {
    func testSidebarRowSubtitleUsesStringCatalog() {
        let expected = String(
            localized: "2 sessions",
            comment: "Number of sessions in a project row."
        )

        XCTAssertEqual(SidebarRowDisplayState.subtitle(for: 2), expected)
        XCTAssertNil(SidebarRowDisplayState.subtitle(for: 1))
    }

    func testSidebarRowHidesTransientTrailingContentWhileRenaming() {
        let state = SidebarRowDisplayState(
            title: "workspace",
            sessionCount: 2,
            pendingReviewCount: 4,
            agentRollup: KeroAgentRollup(phase: .working, count: 1),
            index: 0,
            isRenaming: true,
            directory: "/tmp/workspace"
        )

        XCTAssertEqual(state.subtitle, "2 sessions")
        XCTAssertFalse(state.showsReviewCount)
        XCTAssertFalse(state.showsAgentBadge)
        XCTAssertEqual(state.trailingContent, .none)
    }

    func testSidebarRowUsesStableShortcutSlotForFirstNineProjects() {
        let state = SidebarRowDisplayState(
            title: "workspace",
            sessionCount: 1,
            pendingReviewCount: nil,
            agentRollup: nil,
            index: 8,
            isRenaming: false,
            directory: ""
        )

        XCTAssertEqual(state.trailingContent, .shortcut("⌘9"))
        XCTAssertEqual(state.accessibilityLabel, "workspace")
    }

    func testSidebarRowOmitsShortcutAfterTheNinthProject() {
        let state = SidebarRowDisplayState(
            title: "workspace",
            sessionCount: 1,
            pendingReviewCount: nil,
            agentRollup: nil,
            index: 9,
            isRenaming: false,
            directory: ""
        )

        XCTAssertEqual(state.trailingContent, .none)
    }

    func testPaneActivityBarOnlyPaintsLiveAgentPhases() {
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .created),
            .progress
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .working),
            .progress
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .done),
            .progress
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .blocked),
            .attention
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: .idle),
            .hidden
        )
        XCTAssertEqual(
            AppKitPaneActivityBarStyle.style(for: nil),
            .hidden
        )
    }

    func testSidebarRowAccessibilityPressSelectsTheProject() {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        var selected = false
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: { selected = true },
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertTrue(selected)
    }

    func testSidebarRowSupportsFullKeyboardActivationAndFocus() {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        var activationCount = 0
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: { activationCount += 1 },
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        XCTAssertTrue(row.acceptsFirstResponder, "row must accept first responder")
        XCTAssertTrue(row.canBecomeKeyView, "row must be in the key-view loop")
        XCTAssertEqual(row.focusRingType, .default, "row must draw a focus ring")

        row.keyDown(with: Self.keyEvent(keyCode: 36, characters: "\r"))
        row.keyDown(with: Self.keyEvent(keyCode: 49, characters: " "))

        XCTAssertEqual(activationCount, 2)
    }

    func testSidebarRowExposesReviewCountAsAnAccessibilityChild() {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        project.pendingReview = PendingReview(fileCount: 2, sessionID: nil)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: {},
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        let children = row.accessibilityAttributeValue(.children) as? [Any]
        XCTAssertTrue(
            children?.contains { child in
                (child as? NSCell)?.stringValue == "2"
            } == true
        )
    }

    func testSidebarRowRepaintsSelectionStripeWhenChromeAccentChanges() async {
        Theme.reloadChromeAccent(.coral)
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            project: project,
            index: 0,
            isSelected: true,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: {},
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        let coral = row.debugSelectionStripeColor
        XCTAssertNotNil(coral)

        Theme.reloadChromeAccent(.vividPurple)
        await Self.drainMainQueue(times: 2)

        let purple = row.debugSelectionStripeColor
        XCTAssertNotNil(purple)
        XCTAssertNotEqual(coral, purple)

        Theme.reloadChromeAccent(.coral)
    }

    func testSidebarRowRefreshesAfterPublishedProjectValueIsWritten() async {
        let project = Project(fallbackName: "workspace", createInitialSession: false)
        let row = AppKitSidebarProjectRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            project: project,
            index: 0,
            isSelected: false,
            isDragging: false,
            fontSize: AppSettings.defaultSidebarFontSize,
            onSelect: {},
            onClose: {},
            onDrag: { _ in },
            onDragEnded: {}
        )

        project.customName = "renamed"
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        XCTAssertEqual(row.accessibilityLabel(), "renamed")
    }

    private static func drainMainQueue(times: Int) async {
        for _ in 0..<times {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    private static func keyEvent(keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

}
