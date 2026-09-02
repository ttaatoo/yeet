//
//  AlacrittyTerminalViewFrameTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class AlacrittyTerminalViewFrameTests: XCTestCase {
    func testGridSizeCapsOversizedRestoredLayout() {
        let size = AlacrittyGridSize.from(
            viewportSize: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            cellSize: CGSize(width: 1, height: 1),
            padding: .zero
        )

        XCTAssertEqual(size.columns, AlacrittyGridSize.maximumColumns)
        XCTAssertEqual(size.rows, 256)
        XCTAssertLessThanOrEqual(
            size.columns * size.rows,
            AlacrittyGridSize.maximumCellCount
        )
    }

    func testGridSizeRejectsNonFiniteLayout() {
        let size = AlacrittyGridSize.from(
            viewportSize: CGSize(width: CGFloat.infinity, height: 800),
            cellSize: CGSize(width: 8, height: 16),
            padding: .zero
        )

        XCTAssertEqual(size, AlacrittyGridSize(columns: 2, rows: 2))
    }

    func testGridSizeKeepsTheEmulatorMinimumAndDelaysTinyPaneStartup() {
        let size = AlacrittyGridSize.from(
            viewportSize: CGSize(width: 1, height: 1),
            cellSize: CGSize(width: 8, height: 16),
            padding: .zero
        )

        XCTAssertEqual(size, AlacrittyGridSize(columns: 2, rows: 2))
        XCTAssertFalse(size.isStableForBackend)
    }

    func testPlausibleViewportAllowsNormalPaneAndRejectsRestoredOverflow() {
        let display = CGSize(width: 1_512, height: 949)

        XCTAssertTrue(AlacrittyGridSize.isPlausibleViewport(
            CGSize(width: 1_508, height: 945), within: display
        ))
        XCTAssertFalse(AlacrittyGridSize.isPlausibleViewport(
            CGSize(width: 100_000, height: 100_000), within: display
        ))
    }

    func testHiddenRenderingCursorKeepsIndependentIMEAnchor() {
        var cache = AlacrittyCursorCache()

        cache.update(
            line: -1,
            column: -1,
            imeLine: 2,
            imeColumn: 4,
            shape: 0,
            color: 0
        )

        XCTAssertNil(cache.position)
        XCTAssertEqual(
            cache.imePosition,
            AlacrittyCursorPosition(line: 2, column: 4, shape: 0, color: 0)
        )

        cache.update(
            line: -1,
            column: -1,
            imeLine: -1,
            imeColumn: -1,
            shape: 0,
            color: 0
        )
        XCTAssertNil(cache.imePosition)
    }

    @MainActor
    func testFirstRectUsesIMEAnchorWhenRenderingCursorIsHidden() {
        let view = AlacrittyTerminalView(
            frame: NSRect(x: 37, y: 29, width: 320, height: 200)
        )
        let contentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 120, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrame(
            NSRect(x: 100, y: 120, width: 500, height: 400),
            display: false
        )
        window.contentView = contentView
        contentView.addSubview(view)
        view.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }

        var cache = AlacrittyCursorCache()
        cache.update(
            line: -1,
            column: -1,
            imeLine: 2,
            imeColumn: 4,
            shape: 0,
            color: 0
        )
        view.setCursorCacheForTesting(cache)

        let metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize),
            fontThicken: AppSettings.shared.fontThicken
        )
        let expectedLocal = NSRect(
            x: 10 + 4 * metrics.cellWidth,
            y: view.bounds.maxY - 8 - 3 * metrics.cellHeight,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
        let expected = window.convertToScreen(view.convert(expectedLocal, to: nil))

        XCTAssertEqual(
            view.firstRect(
                forCharacterRange: NSRange(location: 0, length: 0),
                actualRange: nil
            ),
            expected
        )

        cache.update(
            line: -1,
            column: -1,
            imeLine: -1,
            imeColumn: -1,
            shape: 0,
            color: 0
        )
        view.setCursorCacheForTesting(cache)
        XCTAssertEqual(
            view.firstRect(
                forCharacterRange: NSRange(location: 0, length: 0),
                actualRange: nil
            ),
            .zero
        )
    }

    @MainActor
    func testAcceptingHiddenCursorSnapshotFeedsFirstRectAndOverlay() {
        let view = AlacrittyTerminalView(
            frame: NSRect(x: 37, y: 29, width: 320, height: 200)
        )
        let contentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 120, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrame(
            NSRect(x: 100, y: 120, width: 500, height: 400),
            display: false
        )
        window.contentView = contentView
        contentView.addSubview(view)
        view.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }

        var snapshot = KeroSnapshot()
        snapshot.cursor_line = -1
        snapshot.cursor_column = -1
        snapshot.ime_cursor_line = 2
        snapshot.ime_cursor_column = 4
        snapshot.cursor_shape = 0
        snapshot.cursor_color = 0

        view.setMarkedTextForTesting("ni")
        view.acceptSnapshotForTesting(snapshot)

        let cache = view.cursorCacheForTesting()
        XCTAssertNil(cache.position)
        XCTAssertEqual(
            cache.imePosition,
            AlacrittyCursorPosition(line: 2, column: 4, shape: 0, color: 0)
        )

        let metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize),
            fontThicken: AppSettings.shared.fontThicken
        )
        let expectedLocal = NSRect(
            x: 10 + 4 * metrics.cellWidth,
            y: view.bounds.maxY - 8 - 3 * metrics.cellHeight,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
        let expected = window.convertToScreen(view.convert(expectedLocal, to: nil))

        XCTAssertEqual(
            view.firstRect(
                forCharacterRange: NSRange(location: 0, length: 0),
                actualRange: nil
            ),
            expected
        )

        let overlay = view.markedTextOverlayFrameForTesting
        XCTAssertEqual(overlay?.origin.x, expectedLocal.origin.x)
        XCTAssertEqual(overlay?.origin.y, expectedLocal.origin.y)
        XCTAssertEqual(overlay?.height, expectedLocal.height)

        snapshot.ime_cursor_line = -1
        snapshot.ime_cursor_column = -1
        view.acceptSnapshotForTesting(snapshot)
        XCTAssertNil(view.cursorCacheForTesting().imePosition)
        XCTAssertNil(view.markedTextOverlayFrameForTesting)
        XCTAssertEqual(
            view.firstRect(
                forCharacterRange: NSRange(location: 0, length: 0),
                actualRange: nil
            ),
            .zero
        )
    }

    func testPresentationPolicyKeepsBenchmarkMetalActiveWithoutChangingDefault() {
        let normal = AlacrittyPresentationPolicy(benchmarkMode: false)
        XCTAssertTrue(normal.shouldKeepMetalLayerActive(
            surfaceVisible: true, appActive: true, windowIsKey: true
        ))
        XCTAssertFalse(normal.shouldKeepMetalLayerActive(
            surfaceVisible: true, appActive: false, windowIsKey: false
        ))
        XCTAssertTrue(normal.shouldFreezeOnApplicationResignActive)

        let benchmark = AlacrittyPresentationPolicy(benchmarkMode: true)
        XCTAssertTrue(benchmark.shouldKeepMetalLayerActive(
            surfaceVisible: true, appActive: false, windowIsKey: false
        ))
        XCTAssertFalse(benchmark.shouldKeepMetalLayerActive(
            surfaceVisible: false, appActive: false, windowIsKey: false
        ))
        XCTAssertFalse(benchmark.shouldFreezeOnApplicationResignActive)
    }

    func testAbsoluteTargetOverridesEarlierDelta() {
        var intent = AlacrittyFrameIntent()

        intent.addScroll(lines: Int.max)
        intent.addScroll(lines: 4)
        intent.setScrollTarget(Int64.max)
        intent.addScroll(lines: Int.max)

        XCTAssertEqual(intent.scrollDeltaArgument, 0)
        XCTAssertEqual(intent.scrollTargetArgument, Int64.max)
        XCTAssertTrue(intent.hasAbsoluteTarget)
    }

    func testDeltaAfterTargetIsFoldedIntoTheAbsoluteFFIArgument() {
        var intent = AlacrittyFrameIntent()

        intent.addScroll(lines: 7)
        intent.setScrollTarget(20)
        intent.addScroll(lines: 3)

        XCTAssertEqual(intent.scrollTargetArgument, 23)
        XCTAssertEqual(intent.scrollDeltaArgument, 0)
    }

    func testRelativeDeltaCannotTurnAnAbsoluteTargetIntoTheNoTargetSentinel() {
        var intent = AlacrittyFrameIntent()

        intent.setScrollTarget(2)
        intent.addScroll(lines: -3)

        XCTAssertEqual(intent.scrollTargetArgument, 0)
        XCTAssertEqual(intent.scrollDeltaArgument, 0)
        XCTAssertTrue(intent.hasAbsoluteTarget)
    }

    func testBusyRetryRestoresWholeRequestAndMergesNewEvents() {
        var pending = AlacrittyFrameIntent()
        pending.addScroll(lines: 2)
        pending.setScrollTarget(10)
        pending.requestTerminalDamageCheck()
        pending.request(forceFull: true)

        let inFlight = pending.take()

        pending.addScroll(lines: 3)
        pending.request(cursorOnly: true)
        pending.restore(inFlight)

        XCTAssertEqual(pending.scrollDeltaArgument, 0)
        XCTAssertEqual(pending.scrollTargetArgument, 13)
        XCTAssertTrue(pending.needsTerminalDamageCheck)
        XCTAssertTrue(pending.forceFull)
        XCTAssertTrue(pending.cursorOnly)
    }

    func testTerminalWakeRequestsAFrameWithoutForcingFullDamage() {
        var pending = AlacrittyFrameIntent()

        pending.requestTerminalDamageCheck()

        XCTAssertFalse(pending.isEmpty)
        XCTAssertTrue(pending.needsTerminalDamageCheck)
        XCTAssertFalse(pending.forceFull)
        XCTAssertFalse(pending.cursorOnly)
    }

    func testSuccessfulFrameConsumesIntent() {
        var pending = AlacrittyFrameIntent()
        pending.addScroll(lines: 7)
        pending.setScrollTarget(3)
        pending.request(forceFull: true)

        let consumed = pending.take()

        XCTAssertEqual(consumed.scrollDeltaArgument, 0)
        XCTAssertEqual(consumed.scrollTarget, 3)
        XCTAssertTrue(pending.isEmpty)
    }

    func testPresentationFailureForcesFreshSnapshotWithoutReplayingAppliedScroll() {
        var pending = AlacrittyFrameIntent()
        pending.setScrollTarget(80)
        pending.addScroll(lines: 4)
        _ = pending.take()

        pending.recoverAfterAcceptedFrameFailure()

        XCTAssertEqual(pending.scrollDeltaArgument, 0)
        XCTAssertEqual(pending.scrollTargetArgument, -1)
        XCTAssertTrue(pending.forceFull)
    }

    func testFailedFrameWithoutRetryPausesDisplayLink() {
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldPauseDisplayLink(
            renderSucceeded: false
        ))
    }

    func testSuccessfulFrameDoesNotPauseDisplayLink() {
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldPauseDisplayLink(
            renderSucceeded: true
        ))
    }

    func testPresentationRecoveryUsesBoundedBackoff() {
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecovery(
            framePending: true,
            recoveryScheduled: false,
            attempts: 0
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecovery(
            framePending: true,
            recoveryScheduled: true,
            attempts: 0
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecovery(
            framePending: true,
            recoveryScheduled: false,
            attempts: AlacrittyFrameRetryPolicy.maxPresentationRecoveryAttempts
        ))

        var delays: [Int] = []
        for attempt in 0...AlacrittyFrameRetryPolicy.maxPresentationRecoveryAttempts {
            delays.append(
                AlacrittyFrameRetryPolicy
                    .presentationRecoveryDelayMilliseconds(for: attempt)
            )
        }
        XCTAssertEqual(delays, [1, 4, 16, 64, 250, 250])
    }

    func testExhaustedRecoveryUsesOneHertzProbeInsteadOfContinuousWakeups() {
        let exhausted = AlacrittyFrameRetryPolicy.maxPresentationRecoveryAttempts
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecovery(
            framePending: true,
            recoveryScheduled: false,
            attempts: exhausted
        ))
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecoveryProbe(
            framePending: true,
            probeScheduled: false,
            attempts: exhausted
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecoveryProbe(
            framePending: true,
            probeScheduled: true,
            attempts: exhausted
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecoveryProbe(
            framePending: true,
            probeScheduled: false,
            attempts: exhausted - 1
        ))
        XCTAssertEqual(
            AlacrittyFrameRetryPolicy.presentationRecoveryProbeDelayMilliseconds,
            1_000
        )
    }

    func testExhaustedSelectionRetrySchedulesOneLowFrequencyProbe() {
        XCTAssertFalse(AlacrittySelectionRetryPolicy.shouldWakeDisplayLink(
            retryWaiting: true,
            hasOtherPendingWork: false
        ))
        XCTAssertTrue(AlacrittySelectionRetryPolicy.shouldWakeDisplayLink(
            retryWaiting: true,
            hasOtherPendingWork: true
        ))
        XCTAssertTrue(AlacrittySelectionRetryPolicy.shouldWakeDisplayLink(
            retryWaiting: false,
            hasOtherPendingWork: false
        ))

        XCTAssertTrue(AlacrittySelectionRetryPolicy.shouldScheduleProbe(
            actionPending: true,
            retryWindowExhausted: true,
            probeScheduled: false
        ))
        XCTAssertFalse(AlacrittySelectionRetryPolicy.shouldScheduleProbe(
            actionPending: true,
            retryWindowExhausted: true,
            probeScheduled: true
        ))
        XCTAssertFalse(AlacrittySelectionRetryPolicy.shouldScheduleProbe(
            actionPending: true,
            retryWindowExhausted: false,
            probeScheduled: false
        ))
        XCTAssertFalse(AlacrittySelectionRetryPolicy.shouldScheduleProbe(
            actionPending: false,
            retryWindowExhausted: true,
            probeScheduled: false
        ))
        XCTAssertEqual(
            AlacrittySelectionRetryPolicy.probeDelayMilliseconds,
            1_000
        )
    }

    func testSelectionRetryProbeStateDeduplicatesAndCancels() {
        var probe = AlacrittySelectionRetryProbeState()

        XCTAssertTrue(probe.schedule(generation: 3))
        XCTAssertFalse(probe.schedule(generation: 3))
        XCTAssertFalse(probe.begin(generation: 2))
        XCTAssertTrue(probe.isScheduled)

        probe.cancel()
        XCTAssertFalse(probe.isScheduled)
        XCTAssertFalse(probe.begin(generation: 3))

        XCTAssertTrue(probe.schedule(generation: 4))
        XCTAssertTrue(probe.begin(generation: 4))
        XCTAssertFalse(probe.isScheduled)
    }

    func testOrdinaryDamageCannotWakeDisplayLinkDuringRecovery() {
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldWakeDisplayLinkForDamage(
            recoveryScheduled: true,
            recoveryAttempts: 1
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldWakeDisplayLinkForDamage(
            recoveryScheduled: false,
            recoveryAttempts: AlacrittyFrameRetryPolicy.maxPresentationRecoveryAttempts
        ))
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldWakeDisplayLinkForDamage(
            recoveryScheduled: false,
            recoveryAttempts: 0
        ))
    }

    func testPresentationOpportunityCanStartFreshRecoveryBudget() {
        let exhaustedAttempts = AlacrittyFrameRetryPolicy.maxPresentationRecoveryAttempts
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecovery(
            framePending: true,
            recoveryScheduled: false,
            attempts: exhaustedAttempts
        ))

        // A presentation opportunity resets the state to zero attempts and no
        // queued timer before asking ordinary scheduling to wake the link.
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldWakeDisplayLinkForDamage(
            recoveryScheduled: false,
            recoveryAttempts: 0
        ))
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecovery(
            framePending: true,
            recoveryScheduled: false,
            attempts: 0
        ))
    }

    func testSelectionOnlyBusyPausesDisplayLinkWhileRetryWaits() {
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldPauseDisplayLinkForSelectionRetry(
            renderSucceeded: true,
            retryWaiting: true,
            hasOtherPendingWork: false
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldPauseDisplayLinkForSelectionRetry(
            renderSucceeded: true,
            retryWaiting: true,
            hasOtherPendingWork: true
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldPauseDisplayLinkForSelectionRetry(
            renderSucceeded: true,
            retryWaiting: false,
            hasOtherPendingWork: false
        ))
    }

    func testBusyFrameSchedulesOnlyWhileBoundedRetriesRemain() {
        XCTAssertTrue(AlacrittyFrameRetryPolicy.shouldScheduleBusyRetry(
            framePending: true,
            retryScheduled: false,
            retriesRemaining: 2
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldScheduleBusyRetry(
            framePending: true,
            retryScheduled: true,
            retriesRemaining: 2
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldScheduleBusyRetry(
            framePending: false,
            retryScheduled: false,
            retriesRemaining: 2
        ))
        XCTAssertFalse(AlacrittyFrameRetryPolicy.shouldScheduleBusyRetry(
            framePending: true,
            retryScheduled: false,
            retriesRemaining: 0
        ))
    }

    func testSelectionStartCommitsAnchorOnlyAfterBridgeAcceptsIt() {
        var selection = AlacrittySelectionIntent()
        let anchor = AlacrittySelectionAnchor(line: 4, column: 9)

        selection.start(anchor, accepted: false)
        XCTAssertNil(selection.anchor)

        selection.start(anchor, accepted: true)
        XCTAssertEqual(selection.anchor, anchor)
    }

    func testBusySelectionDragKeepsAnchorForTheNextRetry() {
        var selection = AlacrittySelectionIntent()
        let anchor = AlacrittySelectionAnchor(line: 2, column: 3)
        selection.start(anchor, accepted: true)

        XCTAssertFalse(selection.update(accepted: false))
        XCTAssertEqual(selection.anchor, anchor)
        XCTAssertTrue(selection.update(accepted: true))
    }

    func testSelectionRetryMergesTheLatestDragEndpointBeforeMouseUp() {
        var retry = AlacrittySelectionRetryIntent()
        let start = AlacrittySelectionStartIntent(
            line: 2, column: 3, kind: 0, rightHalf: false
        )
        let first = AlacrittySelectionEndpoint(line: 4, column: 5, rightHalf: false)
        let last = AlacrittySelectionEndpoint(line: 7, column: 9, rightHalf: true)

        retry.enqueueStart(start)
        retry.enqueueUpdate(first)
        retry.enqueueUpdate(last)

        XCTAssertEqual(
            retry.action,
            .start(start: start, endpoint: last)
        )
    }

    func testSelectionRetryAdvancesAcceptedStartToTheSavedEndpoint() {
        var retry = AlacrittySelectionRetryIntent()
        let start = AlacrittySelectionStartIntent(
            line: 2, column: 3, kind: 0, rightHalf: false
        )
        let endpoint = AlacrittySelectionEndpoint(line: 7, column: 9, rightHalf: true)

        retry.enqueueStart(start)
        retry.enqueueUpdate(endpoint)
        XCTAssertTrue(retry.beginAttempt())
        retry.acceptStart()

        XCTAssertEqual(retry.action, .update(endpoint))
    }

    func testSelectionReadWaitsBehindAnUncommittedDragEndpoint() {
        var retry = AlacrittySelectionRetryIntent()
        let endpoint = AlacrittySelectionEndpoint(line: 7, column: 9, rightHalf: true)

        retry.enqueueUpdate(endpoint)
        retry.enqueue(.copySelection)

        XCTAssertEqual(retry.action, .update(endpoint))
        XCTAssertEqual(retry.followUp, .copySelection)

        XCTAssertTrue(retry.beginAttempt())
        retry.acceptCurrent()
        XCTAssertEqual(retry.action, .copySelection)
        XCTAssertNil(retry.followUp)
    }

    func testSelectionReadAndSelectAllRetryRemainPendingUntilSuccessOrExplicitOpportunity() {
        var retry = AlacrittySelectionRetryIntent()
        retry.enqueue(.copySelection)

        XCTAssertTrue(retry.beginAttempt())
        XCTAssertEqual(retry.action, .copySelection)
        retry.complete()
        XCTAssertTrue(retry.isEmpty)

        retry.enqueue(.selectAll)
        for _ in 0..<AlacrittySelectionRetryIntent.maximumRetryAttempts {
            XCTAssertTrue(retry.beginAttempt())
        }
        XCTAssertFalse(retry.beginAttempt())
        XCTAssertEqual(retry.action, .selectAll)
        XCTAssertTrue(retry.retryWindowExhausted)

        // An explicit new opportunity opens another finite window without
        // dropping the pending action.
        retry.resetRetryWindow()
        XCTAssertFalse(retry.retryWindowExhausted)
        XCTAssertTrue(retry.beginAttempt())
    }

    func testSustainedOutputWakeDoesNotReopenExhaustedSelectionRetryWindow() {
        var retry = AlacrittySelectionRetryIntent()
        retry.enqueue(.selectAll)

        for _ in 0..<AlacrittySelectionRetryIntent.maximumRetryAttempts {
            XCTAssertTrue(retry.beginAttempt())
        }
        XCTAssertTrue(retry.retryWindowExhausted)

        // Model repeated KERO_EVENT_WAKEUP damage while the bridge stays
        // busy. The pending intent remains available, but ordinary output
        // must not reset it to attempt one and create an unbounded loop.
        for _ in 0..<120 {
            XCTAssertFalse(retry.beginAttempt())
        }
        XCTAssertTrue(retry.retryWindowExhausted)
        XCTAssertEqual(retry.action, .selectAll)

        var probe = AlacrittySelectionRetryProbeState()
        XCTAssertTrue(probe.schedule(generation: 1))
        for _ in 0..<120 {
            XCTAssertFalse(probe.schedule(generation: 1))
        }
        XCTAssertTrue(probe.isScheduled)
    }

    func testSelectionRetryBackoffCapsAt64Milliseconds() {
        var retry = AlacrittySelectionRetryIntent()
        retry.enqueue(.copySelection)

        var delays: [Int] = []
        for _ in 0..<8 {
            XCTAssertTrue(retry.beginAttempt())
            delays.append(retry.retryDelayMilliseconds)
        }

        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 64, 64])
        XCTAssertEqual(retry.action, .copySelection)
        XCTAssertTrue(retry.retryWindowExhausted)
    }

    func testSelectAllCannotBeOverwrittenByAReadRequest() {
        var retry = AlacrittySelectionRetryIntent()
        retry.enqueue(.selectAll)
        retry.enqueue(.copySelection)
        retry.enqueue(.findSelection)

        XCTAssertEqual(retry.action, .selectAll)
        XCTAssertEqual(retry.followUp, .findSelection)
    }

    func testDirectDragSuccessDoesNotConsumeAnUnrelatedReadRequest() {
        var retry = AlacrittySelectionRetryIntent()
        let endpoint = AlacrittySelectionEndpoint(line: 3, column: 4, rightHalf: false)

        retry.enqueue(.copySelection)
        XCTAssertFalse(retry.acceptUpdate())
        XCTAssertEqual(retry.action, .copySelection)

        retry.enqueueUpdate(endpoint)
        retry.enqueue(.copySelection)
        XCTAssertTrue(retry.acceptUpdate())
        XCTAssertEqual(retry.action, .copySelection)
    }

    func testBusySelectionStateRemainsActionableButEmptyStateDoesNot() {
        XCTAssertTrue(TerminalSelectionAvailability.busy.allowsSelectionCommand)
        XCTAssertTrue(TerminalFind.shouldRequestSelectionFind(for: .busy))
        XCTAssertFalse(TerminalSelectionAvailability.empty.allowsSelectionCommand)
        XCTAssertFalse(TerminalFind.shouldRequestSelectionFind(for: .empty))
        XCTAssertTrue(TerminalSelectionAvailability.selected.allowsSelectionCommand)
        XCTAssertTrue(TerminalFind.shouldRequestSelectionFind(for: .selected))
    }

    func testSelectionRetryCancelStopsWorkAfterDetach() {
        var retry = AlacrittySelectionRetryIntent()
        retry.enqueue(.findSelection)

        retry.cancel()

        XCTAssertTrue(retry.isEmpty)
        XCTAssertFalse(retry.beginAttempt())
    }

    func testTerminalInputSupersedesBusySelectionBeforeDelayedRetry() {
        var retry = AlacrittySelectionRetryIntent()
        let start = AlacrittySelectionStartIntent(
            line: 2, column: 3, kind: 0, rightHalf: false
        )
        let endpoint = AlacrittySelectionEndpoint(
            line: 7, column: 9, rightHalf: true
        )

        retry.enqueueStart(start)
        retry.enqueueUpdate(endpoint)
        retry.enqueue(.copySelection)
        XCTAssertTrue(retry.beginAttempt())
        XCTAssertEqual(retry.followUp, .copySelection)

        // The worker may clear the selection while the user starts typing.
        // No delayed retry may recreate the stale drag or its follow-up read.
        retry.supersedeForTerminalInput()
        XCTAssertTrue(retry.isEmpty)
        XCTAssertFalse(retry.beginAttempt())

        // A later explicit copy remains a valid, independent command.
        retry.enqueue(.findSelection)
        XCTAssertEqual(retry.action, .findSelection)
    }

    func testBackendReleaseRunsOffMainActorAndCanBeAwaited() async {
        let recorder = BackendReleaseRecorder()

        let release = AlacrittyHandleRelease.schedule(rawValue: 0xCAFE) { rawValue in
            recorder.record(rawValue: rawValue, ranOnMain: Thread.isMainThread)
        }
        await release.value

        XCTAssertEqual(recorder.rawValues, [0xCAFE])
        XCTAssertEqual(recorder.ranOnMain, [false])
    }

    @MainActor
    func testDetachStopsOwnDisplayLinkBeforeReleasingBackend() {
        let view = AlacrittyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 200)
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.setBenchmarkPresentationMode(true)
        view.setSurfaceVisible(true)

        XCTAssertNotNil(view.displayLink)

        view.detach()

        XCTAssertNil(view.displayLink)
        window.contentView = nil
        window.close()
    }

    func testCursorCacheUsesTheLastAcceptedFramePosition() {
        var cache = AlacrittyCursorCache()

        cache.update(
            line: 7,
            column: 11,
            imeLine: 7,
            imeColumn: 11,
            shape: 2,
            color: 0x00FF00
        )

        XCTAssertEqual(
            cache.position,
            AlacrittyCursorPosition(line: 7, column: 11, shape: 2, color: 0x00FF00)
        )
        XCTAssertEqual(
            cache.imePosition,
            AlacrittyCursorPosition(line: 7, column: 11, shape: 2, color: 0x00FF00)
        )
    }

}

private nonisolated final class BackendReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var rawValues: [UInt] = []
    private(set) var ranOnMain: [Bool] = []

    func record(rawValue: UInt, ranOnMain: Bool) {
        lock.lock()
        rawValues.append(rawValue)
        self.ranOnMain.append(ranOnMain)
        lock.unlock()
    }
}
