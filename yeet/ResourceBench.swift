//
//  ResourceBench.swift
//  yeet
//

import AppKit
import Darwin
import SwiftUI

enum ResourceBenchExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
}

enum ResourceBenchBudget {
    static let maximumPhysicalFootprintBytes: UInt64 = 300 * 1_024 * 1_024
    static let startupTimeoutMilliseconds: Double = 5_000
    static let observationMilliseconds: Double = 10_000
    static let sampleIntervalMilliseconds = 100
}

struct ResourceBenchFixture {
    static let expectedProjectCount = 8
    static let expectedTabCount = 10
    static let expectedPaneCount = 15
    static let historyLineCount = 500

    let snapshot: SessionSnapshot
    let histories: [String: String]

    static func make(workingDirectory: String) -> Self {
        let tabCounts = [2, 2, 1, 1, 1, 1, 1, 1]
        var globalTabIndex = 0
        var globalPaneIndex = 0
        var histories: [String: String] = [:]
        let projects = tabCounts.enumerated().map { projectIndex, tabCount in
            let tabs = (0..<tabCount).map { tabIndex in
                let paneCount = globalTabIndex < 5 ? 2 : 1
                defer { globalTabIndex += 1 }
                let tab = makeTab(
                    projectIndex: projectIndex,
                    tabIndex: tabIndex,
                    paneCount: paneCount,
                    workingDirectory: workingDirectory,
                    globalPaneIndex: &globalPaneIndex,
                    histories: &histories
                )
                return tab
            }
            return SessionSnapshot.ProjectSnapshot(
                customName: "Resource project \(projectIndex + 1)",
                customDirectory: workingDirectory,
                tabs: tabs,
                selectedTabIndex: 0
            )
        }

        precondition(projects.count == expectedProjectCount)
        precondition(globalTabIndex == expectedTabCount)
        precondition(globalPaneIndex == expectedPaneCount)
        return Self(
            snapshot: SessionSnapshot(
                projects: projects,
                selectedProjectIndex: 0,
                isLeftSidebarVisible: true,
                isRightPanelVisible: false,
                rightPanelTab: nil
            ),
            histories: histories
        )
    }

    private static func makeTab(
        projectIndex: Int,
        tabIndex: Int,
        paneCount: Int,
        workingDirectory: String,
        globalPaneIndex: inout Int,
        histories: inout [String: String]
    ) -> SessionSnapshot.ProjectSnapshot.TabSnapshot {
        precondition((1...2).contains(paneCount))
        let first = makePane(
            projectIndex: projectIndex,
            tabIndex: tabIndex,
            paneIndex: globalPaneIndex,
            workingDirectory: workingDirectory,
            histories: &histories
        )
        globalPaneIndex += 1

        let layout: SessionSnapshot.ProjectSnapshot.LayoutSnapshot
        if paneCount == 1 {
            layout = first
        } else {
            let second = makePane(
                projectIndex: projectIndex,
                tabIndex: tabIndex,
                paneIndex: globalPaneIndex,
                workingDirectory: workingDirectory,
                histories: &histories
            )
            globalPaneIndex += 1
            layout = .split(
                axis: .horizontal,
                fraction: 0.5,
                first: first,
                second: second
            )
        }
        return SessionSnapshot.ProjectSnapshot.TabSnapshot(
            layout: layout,
            focusedPaneIndex: 0,
            customName: "Resource tab \(projectIndex + 1).\(tabIndex + 1)"
        )
    }

    private static func makePane(
        projectIndex: Int,
        tabIndex: Int,
        paneIndex: Int,
        workingDirectory: String,
        histories: inout [String: String]
    ) -> SessionSnapshot.ProjectSnapshot.LayoutSnapshot {
        let key = "resource-\(projectIndex)-\(tabIndex)-\(paneIndex)"
        histories[key] = history(
            projectIndex: projectIndex,
            tabIndex: tabIndex,
            paneIndex: paneIndex
        )
        return .pane(SessionSnapshot.ProjectSnapshot.PaneSnapshot(
            content: .session(
                workingDirectory: workingDirectory,
                agentKind: nil,
                agentSessionID: nil
            ),
            weight: 1,
            historyKey: key
        ))
    }

    private static func history(
        projectIndex: Int,
        tabIndex: Int,
        paneIndex: Int
    ) -> String {
        let payload = String(repeating: "x", count: 48)
        return (0..<historyLineCount).map { lineIndex in
            String(
                format: "project %02d tab %02d pane %02d line %03d %@",
                projectIndex,
                tabIndex,
                paneIndex,
                lineIndex,
                payload
            )
        }.joined(separator: "\n") + "\n"
    }
}

struct ResourceBenchObservation: Equatable {
    let projectCount: Int
    let tabCount: Int
    let paneCount: Int
    let windowReadyMilliseconds: Double?
    let peakPhysicalFootprintBytes: UInt64?
}

enum ResourceBenchGate {
    static func failures(for observation: ResourceBenchObservation) -> [String] {
        var failures: [String] = []
        if observation.projectCount != ResourceBenchFixture.expectedProjectCount {
            failures.append(
                "expected \(ResourceBenchFixture.expectedProjectCount) projects, got \(observation.projectCount)"
            )
        }
        if observation.tabCount != ResourceBenchFixture.expectedTabCount {
            failures.append(
                "expected \(ResourceBenchFixture.expectedTabCount) tabs, got \(observation.tabCount)"
            )
        }
        if observation.paneCount != ResourceBenchFixture.expectedPaneCount {
            failures.append(
                "expected \(ResourceBenchFixture.expectedPaneCount) panes, got \(observation.paneCount)"
            )
        }
        if let ready = observation.windowReadyMilliseconds {
            if ready > ResourceBenchBudget.startupTimeoutMilliseconds {
                failures.append(
                    "window ready time \(Int(ready)) ms exceeds \(Int(ResourceBenchBudget.startupTimeoutMilliseconds)) ms"
                )
            }
        } else {
            failures.append("window did not become ready")
        }
        if let footprint = observation.peakPhysicalFootprintBytes {
            if footprint > ResourceBenchBudget.maximumPhysicalFootprintBytes {
                failures.append(
                    "physical footprint \(footprint) bytes exceeds \(ResourceBenchBudget.maximumPhysicalFootprintBytes) bytes"
                )
            }
        } else {
            failures.append("physical footprint was unavailable")
        }
        return failures
    }
}

private struct ResourceBenchReport: Codable {
    let status: String
    let failures: [String]
    let projectCount: Int
    let tabCount: Int
    let paneCount: Int
    let historyBytes: Int
    let windowReadyMilliseconds: Double?
    let peakPhysicalFootprintBytes: UInt64?
    let finalPhysicalFootprintBytes: UInt64?
    let maximumPhysicalFootprintBytes: UInt64
    let sampleCount: Int
}

private actor ResourceBenchMemorySampler {
    struct Snapshot: Sendable {
        let peakPhysicalFootprintBytes: UInt64?
        let finalPhysicalFootprintBytes: UInt64?
        let sampleCount: Int
    }

    private var isRunning = true
    private var peakPhysicalFootprintBytes: UInt64?
    private var finalPhysicalFootprintBytes: UInt64?
    private var sampleCount = 0

    func run() async {
        while isRunning {
            sample()
            try? await Task.sleep(
                for: .milliseconds(ResourceBenchBudget.sampleIntervalMilliseconds)
            )
        }
    }

    func stop() {
        isRunning = false
    }

    func snapshot() -> Snapshot {
        Snapshot(
            peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
            finalPhysicalFootprintBytes: finalPhysicalFootprintBytes,
            sampleCount: sampleCount
        )
    }

    func sample() {
        guard let footprint = Self.physicalFootprintBytes() else { return }
        finalPhysicalFootprintBytes = footprint
        peakPhysicalFootprintBytes = max(peakPhysicalFootprintBytes ?? 0, footprint)
        sampleCount += 1
    }

    nonisolated private static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

private struct ResourceBenchArguments {
    let outputURL: URL?

    init(arguments: [String]) {
        outputURL = arguments.first { $0.hasPrefix("--bench-out=") }.map {
            URL(fileURLWithPath: String($0.dropFirst("--bench-out=".count)))
        }
    }
}

enum ResourceBench {
    static var shouldRun: Bool {
        CommandLine.arguments.contains("--resource-bench")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ResourceBenchAppDelegate()
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor
private final class ResourceBenchAppDelegate: NSObject, NSApplicationDelegate {
    private var runner: ResourceBenchRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runner = ResourceBenchRunner(
            arguments: ResourceBenchArguments(arguments: CommandLine.arguments)
        )
        self.runner = runner
        Task { @MainActor in
            exit(await runner.run())
        }
    }
}

@MainActor
private final class ResourceBenchRunner {
    private let arguments: ResourceBenchArguments

    init(arguments: ResourceBenchArguments) {
        self.arguments = arguments
    }

    func run() async -> Int32 {
        let start = ProcessInfo.processInfo.systemUptime
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yeet-resource-bench-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("resource-bench: create fixture directory failed: \(error)\n", stderr)
            return ResourceBenchExitCode.failure
        }
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let fixture = ResourceBenchFixture.make(workingDirectory: fixtureDirectory.path)
        TerminalManager.prepareResourceBenchRestore(
            snapshot: fixture.snapshot,
            histories: fixture.histories
        )
        let memorySampler = ResourceBenchMemorySampler()
        await memorySampler.sample()
        let memorySamplerTask = Task.detached(priority: .high) {
            await memorySampler.run()
        }
        await Task.yield()
        let manager = TerminalManager()
        let hostingView = NSHostingView(rootView: ContentView(manager: manager))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        let projectCount = manager.projects.count
        let tabCount = manager.projects.reduce(0) { $0 + $1.tabs.count }
        let paneCount = manager.projects.reduce(0) { total, project in
            total + project.tabs.reduce(0) { $0 + $1.allPanes.count }
        }
        let historyBytes = fixture.histories.values.reduce(0) {
            $0 + $1.lengthOfBytes(using: .utf8)
        }
        var windowReadyMilliseconds: Double?

        while elapsedMilliseconds(since: start) < ResourceBenchBudget.observationMilliseconds {
            window.contentView?.layoutSubtreeIfNeeded()
            if windowReadyMilliseconds == nil,
               let session = manager.selectedSession,
               session.surface.window === window,
               session.surface.foregroundPid != nil {
                windowReadyMilliseconds = elapsedMilliseconds(since: start)
            }

            let memory = await memorySampler.snapshot()
            if let footprint = memory.peakPhysicalFootprintBytes,
               footprint > ResourceBenchBudget.maximumPhysicalFootprintBytes {
                break
            }
            if windowReadyMilliseconds == nil,
               elapsedMilliseconds(since: start) > ResourceBenchBudget.startupTimeoutMilliseconds {
                break
            }
            try? await Task.sleep(
                for: .milliseconds(ResourceBenchBudget.sampleIntervalMilliseconds)
            )
        }

        await memorySampler.stop()
        await memorySamplerTask.value
        let memory = await memorySampler.snapshot()
        let observation = ResourceBenchObservation(
            projectCount: projectCount,
            tabCount: tabCount,
            paneCount: paneCount,
            windowReadyMilliseconds: windowReadyMilliseconds,
            peakPhysicalFootprintBytes: memory.peakPhysicalFootprintBytes
        )
        let failures = ResourceBenchGate.failures(for: observation)
        let report = ResourceBenchReport(
            status: failures.isEmpty ? "passed" : "failed",
            failures: failures,
            projectCount: projectCount,
            tabCount: tabCount,
            paneCount: paneCount,
            historyBytes: historyBytes,
            windowReadyMilliseconds: windowReadyMilliseconds,
            peakPhysicalFootprintBytes: memory.peakPhysicalFootprintBytes,
            finalPhysicalFootprintBytes: memory.finalPhysicalFootprintBytes,
            maximumPhysicalFootprintBytes: ResourceBenchBudget.maximumPhysicalFootprintBytes,
            sampleCount: memory.sampleCount
        )
        let wroteReport = write(report)

        manager.projects.forEach { $0.terminateAll() }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? await Task.sleep(for: .milliseconds(250))
        return failures.isEmpty && wroteReport
            ? ResourceBenchExitCode.success
            : ResourceBenchExitCode.failure
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private func write(_ report: ResourceBenchReport) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else {
            fputs("resource-bench: encode report failed\n", stderr)
            return false
        }
        if let outputURL = arguments.outputURL {
            do {
                try data.write(to: outputURL, options: .atomic)
                return true
            } catch {
                fputs("resource-bench: write report failed: \(error)\n", stderr)
                return false
            }
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return true
    }

}
