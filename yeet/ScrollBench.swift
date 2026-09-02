//
//  ScrollBench.swift
//  yeet
//
//  Terminal scroll performance check. It is opt-in:
//  yeet --scroll-bench
//
//  The display-link callback only sends scroll input and polls the worker
//  record. Timing comes from Metal's presented-drawable callback.
//

import AppKit
import QuartzCore

enum ScrollBenchExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let skipped: Int32 = 77
    static let usage: Int32 = 64
    static let timeout: Int32 = 124
}

enum ScrollBenchStatus: String, Codable, Equatable {
    case passed
    case failed
    case skipped
}

struct ScrollBenchChildExitValidationResult: Equatable, Sendable {
    let status: ScrollBenchStatus
    let isConsistent: Bool
}

enum ScrollBenchChildExitValidation {
    static func validate(
        terminationStatus: Int32,
        reportedStatus: ScrollBenchStatus
    ) -> ScrollBenchChildExitValidationResult {
        let expectedStatus: ScrollBenchStatus
        switch terminationStatus {
        case ScrollBenchExitCode.success:
            expectedStatus = .passed
        case ScrollBenchExitCode.skipped:
            expectedStatus = .skipped
        default:
            expectedStatus = .failed
        }

        let isConsistent = expectedStatus == reportedStatus
        return ScrollBenchChildExitValidationResult(
            status: isConsistent ? reportedStatus : .failed,
            isConsistent: isConsistent
        )
    }
}

struct ScrollBenchPresentationReadiness: Equatable, Sendable {
    let status: ScrollBenchStatus
    let exitCode: Int32

    static func evaluate(
        windowVisible: Bool,
        metalViewReady: Bool,
        validPresentedFrames: Int
    ) -> Self {
        guard windowVisible, metalViewReady, validPresentedFrames > 0 else {
            return Self(status: .skipped, exitCode: ScrollBenchExitCode.skipped)
        }
        return Self(status: .passed, exitCode: ScrollBenchExitCode.success)
    }
}

struct ScrollBenchPresentedFrame: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let viewportOffset: Int
}

enum ScrollBenchDisplayLinkPacing {
    static func validInterval(
        timestamp: TimeInterval,
        targetTimestamp: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        let targetInterval = targetTimestamp - timestamp
        if timestamp.isFinite,
           targetTimestamp.isFinite,
           targetInterval.isFinite,
           targetInterval > 0
        {
            return targetInterval
        }
        // Before a display link is scheduled, Core Animation can expose invalid
        // target times; retain that callback only when its nominal duration is usable.
        guard duration.isFinite, duration > 0 else { return nil }
        return duration
    }
}

struct ScrollBenchDisplayLinkPhaseStats: Codable, Equatable, Sendable {
    let callbackSamples: Int
    let validIntervalSamples: Int
    let invalidIntervalSamples: Int
    let targetIntervalP50Ms: Double
    let targetIntervalP95Ms: Double
    let targetFPSMedian: Double
    let targetFPSP95: Double

    init(
        intervals: [TimeInterval],
        invalidIntervalSamples: Int = 0,
        callbackSamples: Int? = nil
    ) {
        let validIntervals = intervals.filter { $0.isFinite && $0 > 0 }
        let sortedIntervals = validIntervals.sorted()
        let sortedFPS = validIntervals.map { 1 / $0 }.sorted()

        self.callbackSamples = callbackSamples ?? validIntervals.count + invalidIntervalSamples
        validIntervalSamples = validIntervals.count
        self.invalidIntervalSamples = max(0, invalidIntervalSamples)
        targetIntervalP50Ms = Self.percentile(sortedIntervals, 0.50) * 1_000
        targetIntervalP95Ms = Self.percentile(sortedIntervals, 0.95) * 1_000
        targetFPSMedian = Self.percentile(sortedFPS, 0.50)
        targetFPSP95 = Self.percentile(sortedFPS, 0.95)
    }

    var supportsFPSGate: Bool {
        targetFPSMedian >= 114
    }

    private static func percentile(_ values: [Double], _ value: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(
            values.count - 1,
            max(0, Int((Double(values.count - 1) * value).rounded()))
        )
        return values[index]
    }
}

enum ScrollBenchTiming {
    static let openDuration: TimeInterval = 2
    static let scrollDuration: TimeInterval = 3
    static let drainDuration: TimeInterval = 0.1
    static let presentationReadinessTimeout: TimeInterval = 2
    // Keep retained history longer than the scroll phase, including the 120Hz input rate.
    static let minimumHistoryLines = 2_000
    static let minimumCoverageFraction = 0.8
    static let minimumPresentedFraction = 0.75
}

struct ScrollBenchPhaseStats: Codable, Equatable, Sendable {
    let presentedFrames: Int
    let presentedSamples: Int
    let timeCoverageMs: Double
    let presentFPS: Double
    let frameTimeP50Ms: Double
    let frameTimeP95Ms: Double
    let frameTimeMaxMs: Double
    let initialViewportOffset: Int?
    let finalViewportOffset: Int?

    init(
        presentedFrames: Int,
        presentFPS: Double,
        frameTimeP50Ms: Double,
        frameTimeP95Ms: Double,
        frameTimeMaxMs: Double,
        presentedSamples: Int? = nil,
        timeCoverageMs: Double? = nil,
        initialViewportOffset: Int? = nil,
        finalViewportOffset: Int? = nil
    ) {
        self.presentedFrames = presentedFrames
        self.presentedSamples = presentedSamples ?? (presentedFrames > 0 ? presentedFrames + 1 : 0)
        self.timeCoverageMs = timeCoverageMs
            ?? (presentFPS > 0 ? Double(presentedFrames) / presentFPS * 1_000 : 0)
        self.presentFPS = presentFPS
        self.frameTimeP50Ms = frameTimeP50Ms
        self.frameTimeP95Ms = frameTimeP95Ms
        self.frameTimeMaxMs = frameTimeMaxMs
        self.initialViewportOffset = initialViewportOffset
        self.finalViewportOffset = finalViewportOffset
    }

    init(samples: [ScrollBenchPresentedFrame]) {
        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }
        let intervals = zip(sortedSamples, sortedSamples.dropFirst()).compactMap { first, second in
            let interval = second.timestamp - first.timestamp
            return interval > 0 ? interval : nil
        }
        let sortedIntervals = intervals.sorted()
        let seconds = intervals.reduce(0, +)
        let fps = seconds > 0 ? Double(intervals.count) / seconds : 0

        func percentile(_ value: Double) -> Double {
            guard !sortedIntervals.isEmpty else { return 0 }
            let index = min(
                sortedIntervals.count - 1,
                max(0, Int((Double(sortedIntervals.count - 1) * value).rounded()))
            )
            return sortedIntervals[index] * 1000
        }

        self.init(
            presentedFrames: intervals.count,
            presentFPS: fps,
            frameTimeP50Ms: percentile(0.50),
            frameTimeP95Ms: percentile(0.95),
            frameTimeMaxMs: (sortedIntervals.last ?? 0) * 1000,
            presentedSamples: sortedSamples.count,
            timeCoverageMs: ((sortedSamples.last?.timestamp ?? 0)
                - (sortedSamples.first?.timestamp ?? 0)) * 1_000,
            initialViewportOffset: sortedSamples.first?.viewportOffset,
            finalViewportOffset: sortedSamples.last?.viewportOffset
        )
    }

    var viewportMovement: Int {
        guard let initialViewportOffset, let finalViewportOffset else { return 0 }
        return abs(finalViewportOffset - initialViewportOffset)
    }
}

struct ScrollBenchScenarioAggregate: Equatable, Sendable {
    let mode: String
    let movement: Int
    let scroll: ScrollBenchPhaseStats
    let open: ScrollBenchPhaseStats?
    let allChildrenPassed: Bool
    let hasSkippedChild: Bool

    init(
        movement: Int,
        open: ScrollBenchPhaseStats? = nil,
        scroll: ScrollBenchPhaseStats,
        allChildrenPassed: Bool = true,
        hasSkippedChild: Bool = false,
        mode: String = "quiet"
    ) {
        self.mode = mode
        self.movement = movement
        self.scroll = scroll
        self.open = open
        self.allChildrenPassed = allChildrenPassed
        self.hasSkippedChild = hasSkippedChild
    }

    init(
        open: ScrollBenchPhaseStats? = nil,
        scroll: ScrollBenchPhaseStats,
        allChildrenPassed: Bool = true,
        hasSkippedChild: Bool = false,
        mode: String = "quiet"
    ) {
        self.init(
            movement: scroll.viewportMovement,
            open: open,
            scroll: scroll,
            allChildrenPassed: allChildrenPassed,
            hasSkippedChild: hasSkippedChild,
            mode: mode
        )
    }
}

struct ScrollBenchGateResult: Equatable, Sendable {
    let status: ScrollBenchStatus
    let exitCode: Int32
}

enum ScrollBenchGate {
    static func evaluate(
        refreshHz: Int,
        displayLinkPacing: ScrollBenchDisplayLinkPhaseStats? = nil,
        scenarios: [ScrollBenchScenarioAggregate],
        expectedScrollDuration: TimeInterval = ScrollBenchTiming.scrollDuration
    ) -> ScrollBenchGateResult {
        guard refreshHz >= 120 else {
            return ScrollBenchGateResult(
                status: .skipped,
                exitCode: ScrollBenchExitCode.skipped
            )
        }
        if let displayLinkPacing, !displayLinkPacing.supportsFPSGate {
            return ScrollBenchGateResult(
                status: .skipped,
                exitCode: ScrollBenchExitCode.skipped
            )
        }
        if scenarios.contains(where: \.hasSkippedChild) {
            return ScrollBenchGateResult(
                status: .skipped,
                exitCode: ScrollBenchExitCode.skipped
            )
        }
        let passed = !scenarios.isEmpty && scenarios.allSatisfy { scenario in
            let scrollPasses = Self.phasePasses(
                scenario.scroll,
                refreshHz: refreshHz,
                expectedDuration: expectedScrollDuration
            )
            let openPasses = scenario.mode == "quiet"
                || scenario.open.map {
                    Self.phasePasses(
                        $0,
                        refreshHz: refreshHz,
                        expectedDuration: ScrollBenchTiming.openDuration
                    )
                } == true
            return scenario.allChildrenPassed
                && scenario.movement > 0
                && openPasses
                && scrollPasses
        }
        return ScrollBenchGateResult(
            status: passed ? .passed : .failed,
            exitCode: passed ? ScrollBenchExitCode.success : ScrollBenchExitCode.failure
        )
    }

    private static func phasePasses(
        _ phase: ScrollBenchPhaseStats,
        refreshHz: Int,
        expectedDuration: TimeInterval
    ) -> Bool {
        let expectedCoverageMs = max(0, expectedDuration)
            * ScrollBenchTiming.minimumCoverageFraction
            * 1_000
        let expectedPresentedFrames = max(
            2,
            Int(
                (max(0, expectedDuration)
                    * Double(min(refreshHz, 120))
                    * ScrollBenchTiming.minimumPresentedFraction).rounded(.up)
            )
        )
        return phase.presentedFrames >= expectedPresentedFrames
            && phase.presentedSamples >= expectedPresentedFrames + 1
            && phase.timeCoverageMs >= expectedCoverageMs
            && phase.presentFPS >= 114
            && phase.frameTimeP50Ms <= 9
            && phase.frameTimeP95Ms <= 16
    }
}

struct ScrollBenchArguments: Equatable, Sendable {
    let isChild: Bool
    let isDryRun: Bool
    let scenarios: [String]

    init(arguments: [String]) {
        isChild = arguments.contains("--scroll-bench-child")
        isDryRun = arguments.contains("--scroll-bench-dry-run")
        let raw = arguments.first { $0.hasPrefix("--bench-scenario=") }
            .map { String($0.dropFirst("--bench-scenario=".count)) }
        scenarios = raw?.split(separator: ",").map(String.init)
            ?? ["quiet-small", "lines-small", "lines-large", "spinner-small"]
    }
}

enum ScrollBenchProcessPlan {
    static let runsPerScenario = 5

    static func childArguments(executable _: String, scenario: String) -> [String] {
        [
            "--scroll-bench",
            "--scroll-bench-child",
            "--bench-scenario=\(scenario)",
        ]
    }
}

enum ScrollBenchReportOutput {
    static func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

enum ScrollBenchWindowOwnership {
    @MainActor
    static func retainUntilScopeExit(_ window: NSWindow) {
        // `run()` owns benchmark windows across suspension points. AppKit's
        // default release-on-close would free them before ARC leaves the scope.
        window.isReleasedWhenClosed = false
    }
}

enum ScrollBench {
    static var shouldRun: Bool {
        CommandLine.arguments.contains("--scroll-bench")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ScrollBenchAppDelegate()
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor
private final class ScrollBenchAppDelegate: NSObject, NSApplicationDelegate {
    private var runner: ScrollBenchRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runner = ScrollBenchRunner(
            arguments: ScrollBenchArguments(arguments: CommandLine.arguments)
        )
        self.runner = runner
        Task { @MainActor in
            exit(await runner.run())
        }
    }
}

@MainActor
private final class ScrollBenchRunner: NSObject {
    private let openDuration = ScrollBenchTiming.openDuration
    private let scrollDuration = ScrollBenchTiming.scrollDuration
    private let scrollLinesPerTick: CGFloat = 3
    private let runsPerScenario = ScrollBenchProcessPlan.runsPerScenario
    private let childTimeout: TimeInterval = 30
    private let arguments: ScrollBenchArguments

    private var phase = "idle"
    private var displayLink: CADisplayLink?
    private var terminal: AlacrittyTerminalView?

    init(arguments: ScrollBenchArguments) {
        self.arguments = arguments
    }

    private func configureDiagnosticWindow(_ window: NSWindow) {
        ScrollBenchWindowOwnership.retainUntilScopeExit(window)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.orderFrontRegardless()
    }

    private func enableBenchmarkPresentationMode(on view: AlacrittyTerminalView) {
        view.setBenchmarkPresentationMode(true)
    }

    func run() async -> Int32 {
        if arguments.isDryRun {
            return emitDryRun()
                ? ScrollBenchExitCode.success : ScrollBenchExitCode.failure
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fputs("scroll-bench: no screen\n", stderr)
            return ScrollBenchExitCode.failure
        }

        let refreshProbe = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        refreshProbe.isOpaque = false
        refreshProbe.backgroundColor = .clear
        configureDiagnosticWindow(refreshProbe)
        refreshProbe.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let refreshHz = await waitForRefresh(on: screen)
        refreshProbe.orderOut(nil)
        refreshProbe.close()
        guard refreshHz >= 120 else {
            fputs("scroll-bench: refreshHz=\(refreshHz); status=skipped\n", stderr)
            let emitted: Bool
            if arguments.isChild {
                emitted = emit(ScrollBenchChildReport(
                    status: .skipped, refreshHz: refreshHz, scenario: nil
                ))
            } else {
                emitted = emit(ScrollBenchParentReport(
                    status: .skipped,
                    refreshHz: refreshHz,
                    runsPerScenario: runsPerScenario,
                    scenarios: []
                ))
            }
            return emitted ? ScrollBenchExitCode.skipped : ScrollBenchExitCode.failure
        }

        if arguments.isChild {
            guard arguments.scenarios.count == 1, let scenario = scenarios().first else {
                fputs("scroll-bench: child needs one known --bench-scenario\n", stderr)
                return ScrollBenchExitCode.usage
            }
            let report = await runChild(scenario, screen: screen, refreshHz: refreshHz)
            guard emit(report) else { return ScrollBenchExitCode.failure }
            switch report.status {
            case .passed: return ScrollBenchExitCode.success
            case .failed: return ScrollBenchExitCode.failure
            case .skipped: return ScrollBenchExitCode.skipped
            }
        }

        let wanted = scenarios()
        guard !wanted.isEmpty else {
            fputs("scroll-bench: no known scenarios selected\n", stderr)
            return ScrollBenchExitCode.usage
        }

        var aggregates: [ScrollBenchScenarioAggregateReport] = []
        for scenario in wanted {
            var children: [ScrollBenchChildReport] = []
            for _ in 0..<runsPerScenario {
                children.append(runChildProcess(scenario.name))
            }
            aggregates.append(aggregate(scenario: scenario, children: children))
        }

        let values = aggregates.map {
            ScrollBenchScenarioAggregate(
                movement: $0.allChildrenMoved ? $0.viewportMovementMinimum : 0,
                open: $0.open.asGateStats,
                scroll: $0.scroll.asGateStats,
                allChildrenPassed: $0.allChildrenPassed,
                hasSkippedChild: $0.hasSkippedChild,
                mode: $0.mode
            )
        }
        let gate = ScrollBenchGate.evaluate(
            refreshHz: refreshHz,
            scenarios: values,
            expectedScrollDuration: scrollDuration
        )
        guard emit(ScrollBenchParentReport(
            status: gate.status,
            refreshHz: refreshHz,
            runsPerScenario: runsPerScenario,
            scenarios: aggregates
        )) else { return ScrollBenchExitCode.failure }
        return gate.exitCode
    }

    private func waitForRefresh(on screen: NSScreen) async -> Int {
        let probeLink = screen.displayLink(
            target: self,
            selector: #selector(tick(_:))
        )
        probeLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120
        )
        probeLink.add(to: .main, forMode: .common)
        defer { probeLink.invalidate() }

        var hz = screen.maximumFramesPerSecond
        for _ in 0..<80 where hz < 120 {
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(100))
            hz = NSScreen.main?.maximumFramesPerSecond ?? screen.maximumFramesPerSecond
        }
        return hz
    }

    private func runChild(
        _ scenario: Scenario,
        screen: NSScreen,
        refreshHz: Int
    ) async -> ScrollBenchChildReport {
        let report = await measure(scenario, screen: screen)
        guard report.measurementStatus == .passed else {
            return ScrollBenchChildReport(
                status: report.measurementStatus,
                refreshHz: refreshHz,
                scenario: report
            )
        }
        guard report.displayLinkPacing.supportsFPSGate else {
            return ScrollBenchChildReport(
                status: .skipped,
                refreshHz: refreshHz,
                scenario: report
            )
        }
        let gate = ScrollBenchGate.evaluate(
            refreshHz: refreshHz,
            displayLinkPacing: report.displayLinkPacing,
            scenarios: [ScrollBenchScenarioAggregate(
                open: report.open,
                scroll: report.scroll,
                hasSkippedChild: report.measurementStatus == .skipped,
                mode: report.mode
            )],
            expectedScrollDuration: scrollDuration
        )
        return ScrollBenchChildReport(
            status: gate.status,
            refreshHz: refreshHz,
            scenario: report
        )
    }

    private func runChildProcess(_ scenario: String) -> ScrollBenchChildReport {
        let process = Process()
        let executable = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
            ?? ""
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ScrollBenchProcessPlan.childArguments(
            executable: executable,
            scenario: scenario
        )
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["YEET_RENDER_STATS"] = "1"

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let timeoutState = ChildTimeoutState()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + childTimeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            timeoutState.markTimedOut()
            process.terminate()
        }

        do {
            try process.run()
            timer.resume()
            process.waitUntilExit()
            timer.cancel()
        } catch {
            timer.cancel()
            fputs("scroll-bench: child launch failed for \(scenario): \(error)\n", stderr)
            return ScrollBenchChildReport(status: .failed, refreshHz: 0, scenario: nil)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard !timeoutState.didTimeout, let report = decodeChildReport(data) else {
            let reason = timeoutState.didTimeout ? "timeout" : "invalid child JSON"
            fputs("scroll-bench: child \(scenario) failed: \(reason)\n", stderr)
            return ScrollBenchChildReport(status: .failed, refreshHz: 0, scenario: nil)
        }
        let validation = ScrollBenchChildExitValidation.validate(
            terminationStatus: process.terminationStatus,
            reportedStatus: report.status
        )
        guard validation.isConsistent else {
            fputs(
                "scroll-bench: child \(scenario) exit \(process.terminationStatus) "
                    + "does not match JSON status \(report.status.rawValue)\n",
                stderr
            )
            return ScrollBenchChildReport(
                status: .failed,
                refreshHz: report.refreshHz,
                scenario: report.scenario
            )
        }
        return report
    }

    private func decodeChildReport(_ data: Data) -> ScrollBenchChildReport? {
        let decoder = JSONDecoder()
        if let report = try? decoder.decode(ScrollBenchChildReport.self, from: data) {
            return report
        }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}")
        else { return nil }
        return try? decoder.decode(
            ScrollBenchChildReport.self,
            from: Data(text[start...end].utf8)
        )
    }

    private func aggregate(
        scenario: Scenario,
        children: [ScrollBenchChildReport]
    ) -> ScrollBenchScenarioAggregateReport {
        let reports = children.compactMap(\.scenario)
        return ScrollBenchScenarioAggregateReport(
            name: scenario.name,
            mode: scenario.mode,
            window: [
                "width": Int(scenario.size.width),
                "height": Int(scenario.size.height),
            ],
            childCount: children.count,
            allChildrenPassed: children.count == runsPerScenario
                && children.allSatisfy { $0.status == .passed },
            hasSkippedChild: children.contains { $0.status == .skipped },
            allChildrenMoved: children.count == runsPerScenario
                && children.allSatisfy {
                    $0.status == .passed && ($0.scenario?.viewportMovement ?? 0) > 0
                },
            viewportMovementMinimum: reports.map(\.viewportMovement).min() ?? 0,
            viewportMovementMedian: percentile(
                reports.map { Double($0.viewportMovement) },
                0.50
            ),
            viewportMovementP95: percentile(
                reports.map { Double($0.viewportMovement) },
                0.95
            ),
            open: ScrollBenchPhaseAggregate(stats: reports.map(\.open)),
            scroll: ScrollBenchPhaseAggregate(stats: reports.map(\.scroll)),
            displayLinkPacing: ScrollBenchDisplayLinkAggregate(
                stats: reports.map(\.displayLinkPacing)
            ),
            bridge: ScrollBenchBridgeAggregate(metrics: reports.map(\.bridge)),
            children: children.map(ScrollBenchChildSummary.init)
        )
    }

    private func percentile(_ values: [Double], _ value: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * value).rounded()))
        )
        return sorted[index]
    }

    private func measure(
        _ scenario: Scenario,
        screen: NSScreen
    ) async -> ScrollBenchScenarioReport {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: scenario.size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "scroll-bench — \(scenario.name)"
        window.setFrameAutosaveName("")
        configureDiagnosticWindow(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        let launch = TerminalLaunch(
            program: "/bin/zsh",
            arguments: ["-c", scenario.command],
            workingDirectory: NSHomeDirectory(),
            environment: ["TERM": "xterm-256color"]
        )
        let view = AlacrittyTerminalView(launch: launch)
        window.contentView = view
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()
        // Observe before the first forced frame. A quiet shell can fill all
        // retained history before the delay below and never damage another row.
        let collector = ScrollBenchPresentationCollector()
        collector.reset()
        enableBenchmarkPresentationMode(on: view)
        view.setSurfaceVisible(true)
        terminal = view

        let link = (window.screen ?? screen).displayLink(
            target: self,
            selector: #selector(tick(_:))
        )
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLink = link

        // Let the PTY fill retained history before collecting phase metrics.
        try? await Task.sleep(for: .milliseconds(600))
        phase = "preflight"
        let preflightBefore = AlacrittyRenderStats.shared.snapshot()
        let preflight = await waitForPresentationReadiness(
            window: window,
            view: view,
            collector: collector
        )
        let readiness = ScrollBenchPresentationReadiness.evaluate(
            windowVisible: preflight.windowVisible,
            metalViewReady: preflight.metalViewReady,
            validPresentedFrames: preflight.validPresentedFrames
        )
        if readiness.status != .passed {
            let metricsAfter = AlacrittyRenderStats.shared.snapshot()
            await cleanup(window: window, view: view)
            AlacrittyRenderStats.shared.stopPresentationObservation()
            return ScrollBenchScenarioReport(
                name: scenario.name,
                mode: scenario.mode,
                window: [
                    "width": Int(scenario.size.width),
                    "height": Int(scenario.size.height),
                ],
                measurementStatus: readiness.status,
                presentation: preflight,
                open: ScrollBenchPhaseStats(
                    presentedFrames: 0,
                    presentFPS: 0,
                    frameTimeP50Ms: 0,
                    frameTimeP95Ms: 0,
                    frameTimeMaxMs: 0
                ),
                scroll: ScrollBenchPhaseStats(
                    presentedFrames: 0,
                    presentFPS: 0,
                    frameTimeP50Ms: 0,
                    frameTimeP95Ms: 0,
                    frameTimeMaxMs: 0
                ),
                displayLinkPacing: ScrollBenchDisplayLinkPhaseStats(intervals: []),
                viewportStart: nil,
                viewportEnd: nil,
                viewportMovement: 0,
                bridge: ScrollBenchBridgeMetrics(
                    before: preflightBefore,
                    after: metricsAfter
                )
            )
        }

        collector.reset()
        let metricsBefore = AlacrittyRenderStats.shared.snapshot()
        phase = "open"
        try? await Task.sleep(for: .seconds(openDuration))
        collector.poll(phase: phase)
        let openSamples = collector.samples(for: "open")

        phase = "scroll"
        try? await Task.sleep(for: .seconds(scrollDuration))
        try? await Task.sleep(for: .seconds(ScrollBenchTiming.drainDuration))
        collector.poll(phase: phase)
        let scrollSamples = collector.samples(for: "scroll")
        let scrollStats = ScrollBenchPhaseStats(samples: scrollSamples)
        let displayLinkPacing = collector.pacingStats(for: "scroll")

        await cleanup(window: window, view: view)
        let metricsAfter = AlacrittyRenderStats.shared.snapshot()
        AlacrittyRenderStats.shared.stopPresentationObservation()

        return ScrollBenchScenarioReport(
            name: scenario.name,
            mode: scenario.mode,
            window: [
                "width": Int(scenario.size.width),
                "height": Int(scenario.size.height),
            ],
            measurementStatus: .passed,
            presentation: preflight,
            open: ScrollBenchPhaseStats(samples: openSamples),
            scroll: scrollStats,
            displayLinkPacing: displayLinkPacing,
            viewportStart: scrollStats.initialViewportOffset,
            viewportEnd: scrollStats.finalViewportOffset,
            viewportMovement: scrollStats.viewportMovement,
            bridge: ScrollBenchBridgeMetrics(before: metricsBefore, after: metricsAfter)
        )
    }

    private func waitForPresentationReadiness(
        window: NSWindow,
        view: AlacrittyTerminalView,
        collector: ScrollBenchPresentationCollector
    ) async -> ScrollBenchPresentationDiagnostics {
        let deadline = Date().addingTimeInterval(
            ScrollBenchTiming.presentationReadinessTimeout
        )
        var diagnostics = ScrollBenchPresentationDiagnostics(
            windowVisible: false,
            metalViewReady: false,
            validPresentedFrames: 0,
            invalidPresentedTimes: 0
        )
        while Date() < deadline {
            collector.poll(phase: "preflight")
            let windowVisible = window.occlusionState.contains(.visible)
            let metalViewReady = view.window === window
                && view.layer is CAMetalLayer
                && view.bounds.width > 0
                && view.bounds.height > 0
            let snapshot = AlacrittyRenderStats.shared.snapshot()
            diagnostics = ScrollBenchPresentationDiagnostics(
                windowVisible: windowVisible,
                metalViewReady: metalViewReady,
                validPresentedFrames: snapshot.presentedFrames,
                invalidPresentedTimes: snapshot.invalidPresentedTimes
            )
            let readiness = ScrollBenchPresentationReadiness.evaluate(
                windowVisible: windowVisible,
                metalViewReady: metalViewReady,
                validPresentedFrames: snapshot.presentedFrames
            )
            if readiness.status == .passed {
                return diagnostics
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return diagnostics
    }

    private func cleanup(window: NSWindow, view: AlacrittyTerminalView) async {
        phase = "idle"
        displayLink?.invalidate()
        displayLink = nil
        await view.detachAndWaitForBackend()
        terminal = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    @objc nonisolated private func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let targetTimestamp = link.targetTimestamp
        let duration = link.duration
        assumeMainActor {
            ScrollBenchPresentationCollector.shared?.poll(phase: phase)
            ScrollBenchPresentationCollector.shared?.recordDisplayLink(
                timestamp: timestamp,
                targetTimestamp: targetTimestamp,
                duration: duration,
                phase: phase
            )
            if phase == "scroll" {
                stepScroll()
            }
        }
    }

    private func stepScroll() {
        guard let view = terminal else { return }
        guard
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: Int32(scrollLinesPerTick),
                wheel2: 0,
                wheel3: 0
            ),
            let event = NSEvent(cgEvent: cgEvent)
        else { return }
        view.scrollWheel(with: event)
    }

    private func emitDryRun() -> Bool {
        if arguments.isChild {
            return emit(ScrollBenchChildReport(
                status: .passed, refreshHz: 0, scenario: nil
            ))
        } else {
            return emit(ScrollBenchParentReport(
                status: .passed,
                refreshHz: 0,
                runsPerScenario: runsPerScenario,
                scenarios: []
            ))
        }
    }

    private func emit<T: Encodable>(_ report: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let json = String(data: data, encoding: .utf8)
        else {
            fputs("scroll-bench: encode failed\n", stderr)
            return false
        }
        fputs(json + "\n", stdout)
        if let out = CommandLine.arguments.first(where: { $0.hasPrefix("--bench-out=") }) {
            let path = String(out.dropFirst("--bench-out=".count))
            do {
                try ScrollBenchReportOutput.write(data, to: path)
            } catch {
                fputs("scroll-bench: write \(path) failed: \(error)\n", stderr)
                return false
            }
        }
        return true
    }

    private struct Scenario {
        let name: String
        let mode: String
        let size: NSSize
        let command: String
    }

    private func scenarios() -> [Scenario] {
        let wanted = Set(arguments.scenarios)
        let historyLines = ScrollBenchTiming.minimumHistoryLines
        let lineFlood = """
        i=0; while :; do print -r -- "$i 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ"; ((i++)); done
        """
        let spinnerFlood = """
        for i in {1..\(historyLines)}; do print -r -- "history $i 0123456789 abcdefghijklmnopqrstuvwxyz"; done; i=0; while :; do printf '\\rBuilding %3d%% done' $((i % 100)); ((i++)); done
        """
        var list: [Scenario] = []
        if wanted.contains("quiet-small") {
            list.append(Scenario(
                name: "quiet-small",
                mode: "quiet",
                size: NSSize(width: 900, height: 600),
                command: "for i in {1..\(historyLines)}; do print -r -- \"history $i 0123456789 abcdefghijklmnopqrstuvwxyz\"; done; sleep 10000"
            ))
        }
        if wanted.contains("lines-small") {
            list.append(Scenario(
                name: "lines-small",
                mode: "lines",
                size: NSSize(width: 900, height: 600),
                command: lineFlood
            ))
        }
        if wanted.contains("lines-large") {
            list.append(Scenario(
                name: "lines-large",
                mode: "lines",
                size: NSSize(width: 1600, height: 1000),
                command: lineFlood
            ))
        }
        if wanted.contains("spinner-small") {
            list.append(Scenario(
                name: "spinner-small",
                mode: "spinner",
                size: NSSize(width: 900, height: 600),
                command: spinnerFlood
            ))
        }
        return list
    }
}

@MainActor
private final class ScrollBenchPresentationCollector {
    static weak var shared: ScrollBenchPresentationCollector?

    private let stats = AlacrittyRenderStats.shared
    private var lastSequence: UInt64 = 0
    private(set) var records: [(phase: String, frame: ScrollBenchPresentedFrame)] = []
    private(set) var displayLinkIntervals: [(phase: String, interval: TimeInterval?)] = []

    init() {
        Self.shared = self
    }

    func reset() {
        stats.startPresentationObservation()
        lastSequence = 0
        records.removeAll(keepingCapacity: true)
        displayLinkIntervals.removeAll(keepingCapacity: true)
    }

    func poll(phase: String) {
        for presented in stats.presentedFrames(since: lastSequence) {
            lastSequence = max(lastSequence, presented.sequence)
            records.append((
                phase,
                ScrollBenchPresentedFrame(
                    timestamp: presented.timestamp,
                    viewportOffset: presented.displayOffset
                )
            ))
        }
    }

    func recordDisplayLink(
        timestamp: TimeInterval,
        targetTimestamp: TimeInterval,
        duration: TimeInterval,
        phase: String
    ) {
        displayLinkIntervals.append((
            phase,
            ScrollBenchDisplayLinkPacing.validInterval(
                timestamp: timestamp,
                targetTimestamp: targetTimestamp,
                duration: duration
            )
        ))
    }

    func samples(for phase: String) -> [ScrollBenchPresentedFrame] {
        records.filter { $0.phase == phase }.map(\.frame)
    }

    func pacingStats(for phase: String) -> ScrollBenchDisplayLinkPhaseStats {
        let phaseIntervals = displayLinkIntervals.filter { $0.phase == phase }
        return ScrollBenchDisplayLinkPhaseStats(
            intervals: phaseIntervals.compactMap(\.interval),
            invalidIntervalSamples: phaseIntervals.reduce(into: 0) { count, record in
                if record.interval == nil { count += 1 }
            },
            callbackSamples: phaseIntervals.count
        )
    }

}

private final class ChildTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var didTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private struct ScrollBenchChildReport: Codable {
    let status: ScrollBenchStatus
    let refreshHz: Int
    let scenario: ScrollBenchScenarioReport?
}

private struct ScrollBenchParentReport: Codable {
    let status: ScrollBenchStatus
    let refreshHz: Int
    let runsPerScenario: Int
    let scenarios: [ScrollBenchScenarioAggregateReport]
}

private struct ScrollBenchScenarioReport: Codable {
    let name: String
    let mode: String
    let window: [String: Int]
    let measurementStatus: ScrollBenchStatus
    let presentation: ScrollBenchPresentationDiagnostics
    let open: ScrollBenchPhaseStats
    let scroll: ScrollBenchPhaseStats
    let displayLinkPacing: ScrollBenchDisplayLinkPhaseStats
    let viewportStart: Int?
    let viewportEnd: Int?
    let viewportMovement: Int
    let bridge: ScrollBenchBridgeMetrics
}

struct ScrollBenchPresentationDiagnostics: Codable, Equatable, Sendable {
    let windowVisible: Bool
    let metalViewReady: Bool
    let validPresentedFrames: Int
    let invalidPresentedTimes: Int
}

private struct ScrollBenchBridgeMetrics: Codable {
    let submittedFrames: Int
    let rejectedFrames: Int
    let presentedFrames: Int
    let invalidPresentedTimes: Int
    let bridgeAttempts: UInt64
    let bridgeBusyAttempts: UInt64
    let bridgeBusyCountMax: UInt64
    let lockWaitNsTotal: UInt64
    let lockWaitNsMean: Double
    let snapshotNsTotal: UInt64
    let snapshotNsMean: Double
    let buildNsTotal: UInt64
    let buildNsMean: Double
    let packedRowsTotal: UInt64
    let packedRowsMean: Double

    init(before: AlacrittyRenderStatsSnapshot, after: AlacrittyRenderStatsSnapshot) {
        submittedFrames = Self.delta(after.submittedFrames, before.submittedFrames)
        rejectedFrames = Self.delta(after.rejectedFrames, before.rejectedFrames)
        presentedFrames = Self.delta(after.presentedFrames, before.presentedFrames)
        invalidPresentedTimes = Self.delta(
            after.invalidPresentedTimes,
            before.invalidPresentedTimes
        )
        bridgeAttempts = Self.delta(after.bridgeAttempts, before.bridgeAttempts)
        bridgeBusyAttempts = Self.delta(after.bridgeBusyAttempts, before.bridgeBusyAttempts)
        bridgeBusyCountMax = after.bridgeBusyCount
        lockWaitNsTotal = Self.delta(after.bridgeLockWaitNs, before.bridgeLockWaitNs)
        snapshotNsTotal = Self.delta(after.bridgeSnapshotNs, before.bridgeSnapshotNs)
        buildNsTotal = Self.delta(after.bridgeBuildNs, before.bridgeBuildNs)
        packedRowsTotal = Self.delta(after.bridgePackedRows, before.bridgePackedRows)
        let divisor = Double(max(bridgeAttempts, 1))
        lockWaitNsMean = Double(lockWaitNsTotal) / divisor
        snapshotNsMean = Double(snapshotNsTotal) / divisor
        buildNsMean = Double(buildNsTotal) / divisor
        packedRowsMean = Double(packedRowsTotal) / divisor
    }

    private static func delta<T: FixedWidthInteger>(_ after: T, _ before: T) -> T {
        after >= before ? after - before : after
    }
}

struct ScrollBenchPhaseAggregate: Codable, Equatable, Sendable {
    let runCount: Int
    let presentedFramesMedian: Double
    let presentedFramesMinimum: Int
    let presentedSamplesMedian: Double
    let presentedSamplesMinimum: Int
    let timeCoverageMsMedian: Double
    let timeCoverageMsMinimum: Double
    let presentFPSMedian: Double
    let presentFPSP95: Double
    let frameTimeP50MsMedian: Double
    let frameTimeP50MsP95: Double
    let frameTimeP95MsMedian: Double
    let frameTimeP95MsP95: Double
    let frameTimeMaxMsMedian: Double
    let frameTimeMaxMsP95: Double

    init(stats: [ScrollBenchPhaseStats]) {
        runCount = stats.count
        presentedFramesMedian = Self.percentile(
            stats.map { Double($0.presentedFrames) },
            0.50
        )
        presentedFramesMinimum = stats.map(\.presentedFrames).min() ?? 0
        presentedSamplesMedian = Self.percentile(
            stats.map { Double($0.presentedSamples) },
            0.50
        )
        presentedSamplesMinimum = stats.map(\.presentedSamples).min() ?? 0
        timeCoverageMsMedian = Self.percentile(stats.map(\.timeCoverageMs), 0.50)
        timeCoverageMsMinimum = stats.map(\.timeCoverageMs).min() ?? 0
        presentFPSMedian = Self.percentile(stats.map(\.presentFPS), 0.50)
        presentFPSP95 = Self.percentile(stats.map(\.presentFPS), 0.95)
        frameTimeP50MsMedian = Self.percentile(stats.map(\.frameTimeP50Ms), 0.50)
        frameTimeP50MsP95 = Self.percentile(stats.map(\.frameTimeP50Ms), 0.95)
        frameTimeP95MsMedian = Self.percentile(stats.map(\.frameTimeP95Ms), 0.50)
        frameTimeP95MsP95 = Self.percentile(stats.map(\.frameTimeP95Ms), 0.95)
        frameTimeMaxMsMedian = Self.percentile(stats.map(\.frameTimeMaxMs), 0.50)
        frameTimeMaxMsP95 = Self.percentile(stats.map(\.frameTimeMaxMs), 0.95)
    }

    var asGateStats: ScrollBenchPhaseStats {
        ScrollBenchPhaseStats(
            presentedFrames: Int(presentedFramesMedian.rounded()),
            presentFPS: presentFPSMedian,
            frameTimeP50Ms: frameTimeP50MsMedian,
            frameTimeP95Ms: frameTimeP95MsMedian,
            frameTimeMaxMs: frameTimeMaxMsMedian,
            presentedSamples: Int(presentedSamplesMedian.rounded()),
            timeCoverageMs: timeCoverageMsMedian
        )
    }

    private static func percentile(_ values: [Double], _ value: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * value).rounded()))
        )
        return sorted[index]
    }
}

private struct ScrollBenchChildSummary: Codable {
    let status: ScrollBenchStatus
    let refreshHz: Int
    let viewportMovement: Int
    let measurementStatus: ScrollBenchStatus?
    let presentation: ScrollBenchPresentationDiagnostics?
    let scroll: ScrollBenchPhaseStats?
    let displayLinkPacing: ScrollBenchDisplayLinkPhaseStats?
    let bridge: ScrollBenchBridgeMetrics?

    init(child: ScrollBenchChildReport) {
        status = child.status
        refreshHz = child.refreshHz
        viewportMovement = child.scenario?.viewportMovement ?? 0
        measurementStatus = child.scenario?.measurementStatus
        presentation = child.scenario?.presentation
        scroll = child.scenario?.scroll
        displayLinkPacing = child.scenario?.displayLinkPacing
        bridge = child.scenario?.bridge
    }
}

private struct ScrollBenchScenarioAggregateReport: Codable {
    let name: String
    let mode: String
    let window: [String: Int]
    let childCount: Int
    let allChildrenPassed: Bool
    let hasSkippedChild: Bool
    let allChildrenMoved: Bool
    let viewportMovementMinimum: Int
    let viewportMovementMedian: Double
    let viewportMovementP95: Double
    let open: ScrollBenchPhaseAggregate
    let scroll: ScrollBenchPhaseAggregate
    let displayLinkPacing: ScrollBenchDisplayLinkAggregate
    let bridge: ScrollBenchBridgeAggregate
    let children: [ScrollBenchChildSummary]
}

private struct ScrollBenchDisplayLinkAggregate: Codable {
    let childCount: Int
    let callbackSamplesMedian: Double
    let callbackSamplesMinimum: Int
    let validIntervalSamplesMedian: Double
    let validIntervalSamplesMinimum: Int
    let invalidIntervalSamplesMedian: Double
    let invalidIntervalSamplesMaximum: Int
    let targetIntervalP50MsMedian: Double
    let targetIntervalP50MsP95: Double
    let targetIntervalP95MsMedian: Double
    let targetIntervalP95MsP95: Double
    let targetFPSMedianMedian: Double
    let targetFPSMedianMinimum: Double
    let targetFPSMedianP95: Double
    let targetFPSP95Median: Double
    let targetFPSP95P95: Double
    let supportsFPSGateAllChildren: Bool

    init(stats: [ScrollBenchDisplayLinkPhaseStats]) {
        childCount = stats.count
        callbackSamplesMedian = Self.percentile(
            stats.map { Double($0.callbackSamples) },
            0.50
        )
        callbackSamplesMinimum = stats.map(\.callbackSamples).min() ?? 0
        validIntervalSamplesMedian = Self.percentile(
            stats.map { Double($0.validIntervalSamples) },
            0.50
        )
        validIntervalSamplesMinimum = stats.map(\.validIntervalSamples).min() ?? 0
        invalidIntervalSamplesMedian = Self.percentile(
            stats.map { Double($0.invalidIntervalSamples) },
            0.50
        )
        invalidIntervalSamplesMaximum = stats.map(\.invalidIntervalSamples).max() ?? 0
        targetIntervalP50MsMedian = Self.percentile(
            stats.map(\.targetIntervalP50Ms),
            0.50
        )
        targetIntervalP50MsP95 = Self.percentile(
            stats.map(\.targetIntervalP50Ms),
            0.95
        )
        targetIntervalP95MsMedian = Self.percentile(
            stats.map(\.targetIntervalP95Ms),
            0.50
        )
        targetIntervalP95MsP95 = Self.percentile(
            stats.map(\.targetIntervalP95Ms),
            0.95
        )
        targetFPSMedianMedian = Self.percentile(
            stats.map(\.targetFPSMedian),
            0.50
        )
        targetFPSMedianMinimum = stats.map(\.targetFPSMedian).min() ?? 0
        targetFPSMedianP95 = Self.percentile(
            stats.map(\.targetFPSMedian),
            0.95
        )
        targetFPSP95Median = Self.percentile(
            stats.map(\.targetFPSP95),
            0.50
        )
        targetFPSP95P95 = Self.percentile(
            stats.map(\.targetFPSP95),
            0.95
        )
        supportsFPSGateAllChildren = !stats.isEmpty && stats.allSatisfy(\.supportsFPSGate)
    }

    private static func percentile(_ values: [Double], _ value: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * value).rounded()))
        )
        return sorted[index]
    }
}

private struct ScrollBenchBridgeAggregate: Codable {
    let childCount: Int
    let bridgeAttemptsMedian: Double
    let bridgeAttemptsP95: Double
    let bridgeBusyAttemptsMedian: Double
    let bridgeBusyAttemptsP95: Double
    let lockWaitNsMeanMedian: Double
    let lockWaitNsMeanP95: Double
    let snapshotNsMeanMedian: Double
    let snapshotNsMeanP95: Double
    let buildNsMeanMedian: Double
    let buildNsMeanP95: Double
    let packedRowsMeanMedian: Double
    let packedRowsMeanP95: Double

    init(metrics: [ScrollBenchBridgeMetrics]) {
        childCount = metrics.count
        bridgeAttemptsMedian = Self.percentile(metrics.map { Double($0.bridgeAttempts) }, 0.50)
        bridgeAttemptsP95 = Self.percentile(metrics.map { Double($0.bridgeAttempts) }, 0.95)
        bridgeBusyAttemptsMedian = Self.percentile(metrics.map { Double($0.bridgeBusyAttempts) }, 0.50)
        bridgeBusyAttemptsP95 = Self.percentile(metrics.map { Double($0.bridgeBusyAttempts) }, 0.95)
        lockWaitNsMeanMedian = Self.percentile(metrics.map(\.lockWaitNsMean), 0.50)
        lockWaitNsMeanP95 = Self.percentile(metrics.map(\.lockWaitNsMean), 0.95)
        snapshotNsMeanMedian = Self.percentile(metrics.map(\.snapshotNsMean), 0.50)
        snapshotNsMeanP95 = Self.percentile(metrics.map(\.snapshotNsMean), 0.95)
        buildNsMeanMedian = Self.percentile(metrics.map(\.buildNsMean), 0.50)
        buildNsMeanP95 = Self.percentile(metrics.map(\.buildNsMean), 0.95)
        packedRowsMeanMedian = Self.percentile(metrics.map(\.packedRowsMean), 0.50)
        packedRowsMeanP95 = Self.percentile(metrics.map(\.packedRowsMean), 0.95)
    }

    private static func percentile(_ values: [Double], _ value: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * value).rounded()))
        )
        return sorted[index]
    }
}
