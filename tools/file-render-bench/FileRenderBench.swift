// File-editor FPS bench. Compiles kero's SyntaxHighlightPlugin + STTextView.
// Later highlight changes must re-run this and compare JSON.
//
//   scripts/bench-file-render.sh tmp/file-render-bench.json

import AppKit
import QuartzCore
import STTextView

@main
enum FileRenderBench {
    static func main() {
        let app = NSApplication.shared
        // Regular + activate keeps a ProMotion display at 120 Hz. Accessory
        // lets the screen drop to 60 Hz after the first scenario.
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runner: FileRenderBenchRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runner = FileRenderBenchRunner()
        self.runner = runner
        Task { @MainActor in
            if CommandLine.arguments.contains("--interactive") {
                await runner.runInteractive()
                return
            }
            exit(await runner.run())
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
private final class FileRenderBenchRunner: NSObject {
    private let windowSize = NSSize(width: 900, height: 600)
    private let openDuration: TimeInterval = 2.0
    private let scrollDuration: TimeInterval = 3.0
    private let scrollStep: CGFloat = 28

    private var phase = "idle"
    private var frames: [(phase: String, interval: CFTimeInterval)] = []
    private var lastTimestamp: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var scrollY: CGFloat = 0
    private var scrollMaxY: CGFloat = 0
    private weak var scrollingClip: NSClipView?
    private weak var scrollingScrollView: NSScrollView?
    private weak var scrollingTextView: STTextView?
    private var tryWindow: NSWindow?
    private var fpsSamples: [CFTimeInterval] = []
    private var tryName = "md-fence"

    func runInteractive() async {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fputs("file-render-bench: no screen\n", stderr)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1100, height: 760)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let scenario = Self.interactiveScenario()
        tryName = scenario.name
        let editor = makeEditor(path: scenario.path, text: scenario.text)
        window.contentView = editor.scrollView
        window.makeFirstResponder(editor.textView)
        editor.scrollView.layoutSubtreeIfNeeded()
        tryWindow = window
        phase = "try"

        let link = (window.screen ?? screen).displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateTryTitle(fps: 0, hz: window.screen?.maximumFramesPerSecond ?? screen.maximumFramesPerSecond)
    }

    func run() async -> Int32 {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fputs("file-render-bench: no screen\n", stderr)
            return 1
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.title = "file-render-bench"
        window.setFrameAutosaveName("")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let link = (window.screen ?? screen).displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link

        // ProMotion reports 60 Hz until a focused window is driving 120.
        // Wait before scenarios so a 60 Hz start-up does not fail the gate.
        var hz = window.screen?.maximumFramesPerSecond ?? screen.maximumFramesPerSecond
        for _ in 0..<80 {
            if hz >= 120 { break }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(100))
            hz = window.screen?.maximumFramesPerSecond ?? screen.maximumFramesPerSecond
        }
        if hz < 120 {
            fputs("file-render-bench: screen refreshHz is \(hz); 120 FPS gates will not run\n", stderr)
        }

        var reports: [ScenarioReport] = []
        for scenario in Self.scenarios() {
            reports.append(await measure(scenario, in: window))
        }

        displayLink?.invalidate()
        displayLink = nil
        window.close()

        let refreshHz = window.screen?.maximumFramesPerSecond ?? screen.maximumFramesPerSecond
        let payload = BenchReport(
            refreshHz: refreshHz,
            window: ["width": Int(windowSize.width), "height": Int(windowSize.height)],
            scenarios: reports
        )
        emit(payload)
        return Self.assertGates(payload)
    }

    /// On a 120 Hz display, fail the process if open/scroll drop below the
    /// file-render gate. Lower refresh rates cannot prove 120 FPS.
    private static func assertGates(_ report: BenchReport) -> Int32 {
        guard report.refreshHz >= 120 else { return 0 }
        var failed = false
        for scenario in report.scenarios {
            let open = scenario.open
            let scroll = scenario.scroll
            let over = scroll.frames > 0 ? Double(scroll.over16ms) / Double(scroll.frames) : 1
            if open.fps < 114 {
                fputs("file-render-bench: \(scenario.name) open.fps \(open.fps) < 114\n", stderr)
                failed = true
            }
            if scroll.fps < 114 {
                fputs("file-render-bench: \(scenario.name) scroll.fps \(scroll.fps) < 114\n", stderr)
                failed = true
            }
            if scroll.p50Ms > 9.0 {
                fputs("file-render-bench: \(scenario.name) scroll.p50Ms \(scroll.p50Ms) > 9\n", stderr)
                failed = true
            }
            if over > 0.05 {
                fputs("file-render-bench: \(scenario.name) scroll over16ms \(over) > 0.05\n", stderr)
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private func measure(
        _ scenario: Scenario,
        in window: NSWindow
    ) async -> ScenarioReport {
        let editor = makeEditor(path: scenario.path, text: scenario.text)
        window.contentView = editor.scrollView
        window.makeFirstResponder(editor.textView)
        editor.scrollView.layoutSubtreeIfNeeded()
        editor.textView.needsLayout = true
        editor.textView.layoutSubtreeIfNeeded()
        // Let the first highlight pass and query compile land before the
        // open window. Those frames are not scroll, and counting them in
        // open.fps made the first scenario miss 114 on a cold process.
        try? await Task.sleep(for: .milliseconds(350))

        frames.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        scrollY = 0
        scrollingClip = editor.scrollView.contentView
        scrollingScrollView = editor.scrollView
        scrollingTextView = editor.textView
        let clipHeight = editor.scrollView.contentView.bounds.height
        scrollMaxY = max(0, (editor.scrollView.documentView?.frame.height ?? 0) - clipHeight)

        phase = "open"
        try? await Task.sleep(for: .seconds(openDuration))

        // Drive the clip on the display link so 120 FPS means 120 viewport
        // steps, not idle ticks between a 60 Hz timer. Clip-origin +
        // prepareContent is the STTextView scroll path; do not force
        // layoutSubtreeIfNeeded (that is extra vs NSScrollView).
        phase = "scroll"
        try? await Task.sleep(for: .seconds(scrollDuration))

        phase = "idle"
        scrollingClip = nil
        scrollingScrollView = nil
        scrollingTextView = nil
        let captured = frames
        window.contentView = nil

        return ScenarioReport(
            name: scenario.name,
            bytes: scenario.text.utf8.count,
            lines: scenario.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            open: stats(captured.filter { $0.phase == "open" }),
            scroll: stats(captured.filter { $0.phase == "scroll" })
        )
    }

    @objc nonisolated private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        assumeMainActor {
            if lastTimestamp > 0 {
                let interval = now - lastTimestamp
                frames.append((phase, interval))
                if phase == "try" {
                    recordTryFps(interval)
                }
            }
            lastTimestamp = now
            if phase == "scroll" {
                stepScroll()
            }
        }
    }

    private func recordTryFps(_ interval: CFTimeInterval) {
        fpsSamples.append(interval)
        if fpsSamples.count > 120 {
            fpsSamples.removeFirst(fpsSamples.count - 120)
        }
        let seconds = fpsSamples.reduce(0, +)
        let fps = seconds > 0 ? Double(fpsSamples.count) / seconds : 0
        let hz = tryWindow?.screen?.maximumFramesPerSecond ?? 0
        updateTryTitle(fps: fps, hz: hz)
    }

    private func updateTryTitle(fps: Double, hz: Int) {
        if fps <= 0 {
            tryWindow?.title = "file-render-try — \(tryName) — scroll me"
            return
        }
        tryWindow?.title = String(format: "file-render-try — \(tryName) — %.0f fps (screen %d Hz)", fps, hz)
    }

    /// One clip-origin step plus STTextView's own `prepareContent` (the hook
    /// AppKit uses when the document view is not doing a full layout pass).
    private func stepScroll() {
        guard let clip = scrollingClip,
              let scrollView = scrollingScrollView,
              let textView = scrollingTextView
        else { return }
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        scrollMaxY = max(scrollMaxY, max(0, contentHeight - clip.bounds.height))
        scrollY += scrollStep
        let y: CGFloat
        if scrollMaxY > 0 {
            // Triangle wave: wrapping from the document end to y=0 forced a
            // full relocateViewport hitch that is not a real scroll.
            let cycle = scrollMaxY * 2
            let t = scrollY.truncatingRemainder(dividingBy: cycle)
            y = t <= scrollMaxY ? t : (cycle - t)
        } else {
            y = 0
        }
        clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        // AppKit calls prepareContent when the visible rect leaves the
        // prepared band. Forcing it every vsync made layoutViewport the
        // common 20 ms hitch. Match that: prepare only when we walk out.
        let visible = textView.visibleRect
        let prepared = textView.preparedContentRect
        if prepared.isNull || prepared.isEmpty || !prepared.contains(visible) {
            textView.prepareContent(in: visible)
        }
    }

    private func makeEditor(path: String, text: String) -> (scrollView: NSScrollView, textView: STTextView) {
        let scrollView = NSScrollView()
        let textView = STTextView()
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let textColor = NSColor.labelColor
        let background = NSColor.windowBackgroundColor
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = background
        scrollView.backgroundColor = background
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.selectedLineHighlightColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
        textView.isHorizontallyResizable = true
        if let gutter = textView.gutterView {
            gutter.textColor = NSColor.secondaryLabelColor
            gutter.selectedLineTextColor = textColor
        }
        textView.text = text
        if let plugin = SyntaxHighlighting.plugin(for: path) {
            textView.addPlugin(plugin)
        }
        return (scrollView, textView)
    }

    private func stats(_ samples: [(phase: String, interval: CFTimeInterval)]) -> PhaseStats {
        let intervals = samples.map(\.interval)
        guard !intervals.isEmpty else {
            return PhaseStats(frames: 0, seconds: 0, fps: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0, maxMs: 0, over16ms: 0, over33ms: 0)
        }
        let seconds = intervals.reduce(0, +)
        let fps = seconds > 0 ? Double(intervals.count) / seconds : 0
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double {
            let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[i] * 1000
        }
        return PhaseStats(
            frames: intervals.count,
            seconds: seconds,
            fps: fps,
            p50Ms: pct(0.50),
            p95Ms: pct(0.95),
            p99Ms: pct(0.99),
            maxMs: (sorted.last ?? 0) * 1000,
            over16ms: intervals.filter { $0 > 1.0 / 60.0 }.count,
            over33ms: intervals.filter { $0 > 1.0 / 30.0 }.count
        )
    }

    private func emit(_ report: BenchReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else {
            fputs("file-render-bench: encode failed\n", stderr)
            return
        }
        fputs(json + "\n", stdout)
        if let out = CommandLine.arguments.first(where: { $0.hasPrefix("--bench-out=") }) {
            let path = String(out.dropFirst("--bench-out=".count))
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private struct Scenario {
        let name: String
        let path: String
        let text: String
    }

    private static func scenarios() -> [Scenario] {
        let names = CommandLine.arguments
            .first(where: { $0.hasPrefix("--bench-scenario=") })
            .map { String($0.dropFirst("--bench-scenario=".count)).split(separator: ",").map(String.init) }
        let wanted = Set(names ?? ["md-fence", "md-lists", "swift"])
        var list: [Scenario] = []
        if wanted.contains("md-fence") {
            list.append(Scenario(name: "md-fence", path: "bench.md", text: markdownWithFence()))
        }
        if wanted.contains("md-lists") {
            list.append(Scenario(name: "md-lists", path: "bench.md", text: markdownLists()))
        }
        if wanted.contains("swift") {
            list.append(Scenario(name: "swift", path: "bench.swift", text: swiftSource(functions: 400)))
        }
        return list
    }

    private static func interactiveScenario() -> Scenario {
        if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--file=") }) {
            let path = String(raw.dropFirst("--file=".count))
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return Scenario(name: URL(fileURLWithPath: path).lastPathComponent, path: path, text: text)
        }
        let wanted = CommandLine.arguments
            .first(where: { $0.hasPrefix("--bench-scenario=") })
            .map { String($0.dropFirst("--bench-scenario=".count)) }
            ?? "md-fence"
        return scenarios().first { $0.name == wanted } ?? Scenario(
            name: "md-fence",
            path: "bench.md",
            text: markdownWithFence()
        )
    }

    /// Fence sits near the top so the first paint highlights it.
    private static func markdownWithFence() -> String {
        var text = "# Bench\n\nA short intro with **bold**, `code`, and a [link](https://example.com).\n\n"
        for i in 0..<40 {
            text += "- item \(i) with `code` and **bold**\n"
        }
        text += "\n```swift\n"
        text += swiftSource(functions: 250)
        text += "```\n\n"
        for i in 0..<80 {
            text += "## Section \(i)\n\nParagraph \(i) continues with a [link](https://example.com/\(i)) and more prose.\n\n"
        }
        return text
    }

    private static func markdownLists() -> String {
        var text = "# Lists\n\n"
        for i in 0..<1200 {
            text += "- item \(i) with `code` and **bold**\n"
        }
        return text
    }

    private static func swiftSource(functions: Int) -> String {
        var text = "import Foundation\n\n"
        for i in 0..<functions {
            text += """
            func benchToken\(i)(value: Int) -> Int {
                let doubled = value * 2
                // comment \(i)
                if doubled > \(i) {
                    return doubled + \(i)
                }
                return doubled
            }


            """
        }
        return text
    }
}

private struct BenchReport: Codable {
    var refreshHz: Int
    var window: [String: Int]
    var scenarios: [ScenarioReport]
}

private struct ScenarioReport: Codable {
    var name: String
    var bytes: Int
    var lines: Int
    var open: PhaseStats
    var scroll: PhaseStats
}

private struct PhaseStats: Codable {
    var frames: Int
    var seconds: Double
    var fps: Double
    var p50Ms: Double
    var p95Ms: Double
    var p99Ms: Double
    var maxMs: Double
    var over16ms: Int
    var over33ms: Int
}
