//
//  ScrollBenchTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class ScrollBenchTests: XCTestCase {
    @MainActor
    func testBenchmarkWindowRemainsOwnedAfterClose() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        ScrollBenchWindowOwnership.retainUntilScopeExit(window)

        XCTAssertFalse(window.isReleasedWhenClosed)
        window.close()
    }

    func testPresentedSamplesUseMetalTimestampsForFrameTime() {
        let samples = (0..<6).map { index in
            ScrollBenchPresentedFrame(
                timestamp: Double(index) / 120,
                viewportOffset: index == 0 ? 4 : 5
            )
        }

        let stats = ScrollBenchPhaseStats(samples: samples)

        XCTAssertEqual(stats.presentedFrames, 5)
        XCTAssertEqual(stats.presentFPS, 120, accuracy: 0.001)
        XCTAssertEqual(stats.frameTimeP50Ms, 1000.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(stats.frameTimeP95Ms, 1000.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(stats.frameTimeMaxMs, 1000.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(stats.viewportMovement, 1)
    }

    func testDisplayLinkPacingPrefersValidTargetTimestampInterval() {
        guard let interval = ScrollBenchDisplayLinkPacing.validInterval(
            timestamp: 10,
            targetTimestamp: 10.008333,
            duration: 1.0 / 60
        ) else {
            return XCTFail("expected a valid target interval")
        }

        XCTAssertEqual(interval, 0.008333, accuracy: 0.000001)
    }

    func testDisplayLinkPacingFiltersInvalidIntervalsBeforeMeasuringTarget() {
        guard let fallback = ScrollBenchDisplayLinkPacing.validInterval(
            timestamp: .nan,
            targetTimestamp: .nan,
            duration: 1.0 / 60
        ) else {
            return XCTFail("expected duration fallback")
        }
        XCTAssertEqual(fallback, 1.0 / 60, accuracy: 0.000001)
        XCTAssertNil(
            ScrollBenchDisplayLinkPacing.validInterval(
                timestamp: 10,
                targetTimestamp: 9,
                duration: .nan
            )
        )
    }

    func testGateSkipsWhenDisplayLinkPacingCannotSupport114FPS() {
        let pacing = ScrollBenchDisplayLinkPhaseStats(
            intervals: Array(repeating: 0.010, count: 120)
        )

        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            displayLinkPacing: pacing,
            scenarios: [ScrollBenchScenarioAggregate(
                movement: 3,
                scroll: .passing
            )]
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.skipped)
    }

    func test120HzDisplayLinkPacingStillUsesStrictPresentationGate() {
        let pacing = ScrollBenchDisplayLinkPhaseStats(
            intervals: Array(repeating: 1.0 / 120, count: 120)
        )
        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            displayLinkPacing: pacing,
            scenarios: [ScrollBenchScenarioAggregate(
                movement: 3,
                scroll: ScrollBenchPhaseStats(
                    presentedFrames: 360,
                    presentFPS: 100,
                    frameTimeP50Ms: 10,
                    frameTimeP95Ms: 18,
                    frameTimeMaxMs: 20,
                    presentedSamples: 361,
                    timeCoverageMs: 3_000
                )
            )]
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.failure)
    }

    func testGateSkipsAtRefreshRatesThatCannotProve120Hz() {
        let result = ScrollBenchGate.evaluate(
            refreshHz: 60,
            scenarios: [ScrollBenchScenarioAggregate(movement: 3, scroll: .passing)]
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.skipped)
    }

    func testGateSkipsWhenAChildCannotMeasurePresentation() {
        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            scenarios: [ScrollBenchScenarioAggregate(
                movement: 0,
                scroll: .empty,
                hasSkippedChild: true
            )]
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.skipped)
    }

    func testPresentationReadinessSkipsWithoutVisibleMetalOrTimestamp() {
        let hiddenWindow = ScrollBenchPresentationReadiness.evaluate(
            windowVisible: false,
            metalViewReady: true,
            validPresentedFrames: 120
        )
        let noTimestamp = ScrollBenchPresentationReadiness.evaluate(
            windowVisible: true,
            metalViewReady: true,
            validPresentedFrames: 0
        )

        XCTAssertEqual(hiddenWindow.status, .skipped)
        XCTAssertEqual(hiddenWindow.exitCode, ScrollBenchExitCode.skipped)
        XCTAssertEqual(noTimestamp.status, .skipped)
        XCTAssertEqual(noTimestamp.exitCode, ScrollBenchExitCode.skipped)
    }

    func testGateFailsWhenScrollViewportDoesNotMove() {
        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            scenarios: [ScrollBenchScenarioAggregate(movement: 0, scroll: .passing)]
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.failure)
    }

    func testGateDoesNotRequireQuietOpenPhaseToPresentFrames() {
        let emptyOpen = ScrollBenchPhaseStats(
            presentedFrames: 0,
            presentFPS: 0,
            frameTimeP50Ms: 0,
            frameTimeP95Ms: 0,
            frameTimeMaxMs: 0
        )
        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            scenarios: [ScrollBenchScenarioAggregate(
                movement: 3,
                open: emptyOpen,
                scroll: .passing,
                mode: "quiet"
            )]
        )

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.success)
    }

    func testGateRequiresOpenPresentationForContinuousOutputScenario() {
        let slowOpen = ScrollBenchPhaseStats(
            presentedFrames: 4,
            presentFPS: 2.18,
            frameTimeP50Ms: 458,
            frameTimeP95Ms: 458,
            frameTimeMaxMs: 458,
            presentedSamples: 5,
            timeCoverageMs: 1_375
        )
        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            scenarios: [ScrollBenchScenarioAggregate(
                movement: 3,
                open: slowOpen,
                scroll: .passing,
                mode: "lines"
            )]
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.failure)
    }

    func testGateAcceptsHealthyOpenPresentationForContinuousOutputScenario() {
        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            scenarios: [ScrollBenchScenarioAggregate(
                movement: 3,
                open: .passing,
                scroll: .passing,
                mode: "spinner"
            )]
        )

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.success)
    }

    func testGateUsesScrollPhaseEndpointsForMovement() {
        let scroll = ScrollBenchPhaseStats(samples: (0...360).map { index in
            ScrollBenchPresentedFrame(
                timestamp: Double(index) / 120,
                viewportOffset: index == 0 ? 8 : 9
            )
        })

        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            scenarios: [ScrollBenchScenarioAggregate(scroll: scroll)]
        )

        XCTAssertEqual(scroll.viewportMovement, 1)
        XCTAssertEqual(result.status, .passed)
    }

    func testGateFailsWhenScrollHasOnlyShortBurstThenNoFrames() {
        let scroll = ScrollBenchPhaseStats(samples: (0..<6).map { index in
            ScrollBenchPresentedFrame(
                timestamp: Double(index) / 120,
                viewportOffset: index == 0 ? 8 : 9
            )
        })

        let result = ScrollBenchGate.evaluate(
            refreshHz: 120,
            scenarios: [ScrollBenchScenarioAggregate(scroll: scroll)]
        )

        XCTAssertEqual(scroll.presentedFrames, 5)
        XCTAssertLessThan(scroll.timeCoverageMs, 100)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.exitCode, ScrollBenchExitCode.failure)
    }

    func testAggregateRetainsPresentedFramesAndCoverageAcrossFiveChildren() {
        let stats = [110, 118, 120, 122, 130].map { frames in
            ScrollBenchPhaseStats(
                presentedFrames: frames,
                presentFPS: 120,
                frameTimeP50Ms: 8,
                frameTimeP95Ms: 10,
                frameTimeMaxMs: 14,
                presentedSamples: frames + 1,
                timeCoverageMs: 3_000
            )
        }

        let aggregate = ScrollBenchPhaseAggregate(stats: stats)

        XCTAssertEqual(aggregate.runCount, 5)
        XCTAssertEqual(aggregate.presentedFramesMedian, 120, accuracy: 0.001)
        XCTAssertEqual(aggregate.presentedFramesMinimum, 110)
        XCTAssertEqual(aggregate.presentedSamplesMedian, 121, accuracy: 0.001)
        XCTAssertEqual(aggregate.presentedSamplesMinimum, 111)
        XCTAssertEqual(aggregate.timeCoverageMsMedian, 3_000, accuracy: 0.001)
        XCTAssertEqual(aggregate.timeCoverageMsMinimum, 3_000, accuracy: 0.001)
        XCTAssertEqual(aggregate.asGateStats.presentedFrames, 120)
        XCTAssertEqual(aggregate.asGateStats.timeCoverageMs, 3_000, accuracy: 0.001)
    }

    func testChildInvocationKeepsOneScenarioAndMarksIndependentChild() {
        XCTAssertGreaterThanOrEqual(ScrollBenchProcessPlan.runsPerScenario, 5)
        let arguments = ScrollBenchArguments(
            arguments: [
                "Yeet",
                "--scroll-bench",
                "--scroll-bench-child",
                "--bench-scenario=lines-small",
            ]
        )

        XCTAssertTrue(arguments.isChild)
        XCTAssertEqual(arguments.scenarios, ["lines-small"])
        XCTAssertEqual(
            ScrollBenchProcessPlan.childArguments(
                executable: "/tmp/Yeet",
                scenario: "lines-small"
            ),
            [
                "--scroll-bench",
                "--scroll-bench-child",
                "--bench-scenario=lines-small",
            ]
        )
    }

    func testDryRunFlagIsParsedWithoutStartingAChild() {
        let arguments = ScrollBenchArguments(
            arguments: ["Yeet", "--scroll-bench", "--scroll-bench-dry-run"]
        )

        XCTAssertTrue(arguments.isDryRun)
        XCTAssertFalse(arguments.isChild)
    }

    func testChildExitCodeAndJSONStatusMustMatch() {
        let matching: [(Int32, ScrollBenchStatus)] = [
            (ScrollBenchExitCode.success, .passed),
            (ScrollBenchExitCode.skipped, .skipped),
            (ScrollBenchExitCode.failure, .failed),
            (9, .failed),
        ]
        for (exitCode, status) in matching {
            let result = ScrollBenchChildExitValidation.validate(
                terminationStatus: exitCode,
                reportedStatus: status
            )
            XCTAssertTrue(result.isConsistent)
            XCTAssertEqual(result.status, status)
        }

        let mismatched: [(Int32, ScrollBenchStatus)] = [
            (ScrollBenchExitCode.success, .failed),
            (ScrollBenchExitCode.success, .skipped),
            (ScrollBenchExitCode.skipped, .passed),
            (ScrollBenchExitCode.skipped, .failed),
            (ScrollBenchExitCode.failure, .passed),
            (ScrollBenchExitCode.failure, .skipped),
        ]
        for (exitCode, status) in mismatched {
            let result = ScrollBenchChildExitValidation.validate(
                terminationStatus: exitCode,
                reportedStatus: status
            )
            XCTAssertFalse(result.isConsistent)
            XCTAssertEqual(result.status, .failed)
        }
    }

    func testReportOutputPropagatesParentDirectoryFailure() throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-scroll-bench-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }

        let report = blockingFile.appendingPathComponent("report.json")
        XCTAssertThrowsError(
            try ScrollBenchReportOutput.write(Data("{}".utf8), to: report.path)
        )
    }

    func testStaticHistoryScenariosCoverTheScrollPhase() {
        XCTAssertEqual(ScrollBenchTiming.minimumHistoryLines, 2_000)
    }
}

private extension ScrollBenchPhaseStats {
    static let passing = ScrollBenchPhaseStats(
        presentedFrames: 360,
        presentFPS: 120,
        frameTimeP50Ms: 8,
        frameTimeP95Ms: 10,
        frameTimeMaxMs: 14,
        presentedSamples: 361,
        timeCoverageMs: 3_000
    )

    static let empty = ScrollBenchPhaseStats(
        presentedFrames: 0,
        presentFPS: 0,
        frameTimeP50Ms: 0,
        frameTimeP95Ms: 0,
        frameTimeMaxMs: 0,
        presentedSamples: 0,
        timeCoverageMs: 0
    )
}
