//
//  AlacrittyRenderStats.swift
//  kero
//

import Foundation
import Synchronization

nonisolated struct AlacrittyPresentedFrame: Equatable, Sendable {
    let sequence: UInt64
    let displayOffset: Int
    let timestamp: CFTimeInterval
}

nonisolated struct AlacrittyRenderStatsSnapshot: Equatable, Sendable {
    let submittedFrames: Int
    let rejectedFrames: Int
    let completedFrames: Int
    let failedCompletions: Int
    let presentedFrames: Int
    let invalidPresentedTimes: Int
    let bridgeAttempts: UInt64
    let bridgeBusyAttempts: UInt64
    let bridgeBusyCount: UInt64
    let bridgeLockWaitNs: UInt64
    let bridgeSnapshotNs: UInt64
    let bridgeBuildNs: UInt64
    let bridgePackedRows: UInt64
    let rebuiltRows: Int
    let packedInstances: Int
    let uploadedInstances: Int
    let skippedFrames: Int
    let lastPresented: AlacrittyPresentedFrame?
}

/// Frame timing for the Alacritty backend, reported when `YEET_RENDER_STATS`
/// is set in the environment.
///
/// This exists because "the GPU is faster" is a claim worth checking rather
/// than assuming: it records frame time, actual CPU row work, command-buffer
/// completion, and drawable presentation.
nonisolated final class AlacrittyRenderStats: @unchecked Sendable {
    static let shared = AlacrittyRenderStats()

    /// UserDefaults OR the env var: Xcode-launched runs cannot inherit shell
    /// environment, so `defaults write sh.yeet.dev YEET_RENDER_STATS -bool YES`
    /// turns the stats on for those too.
    private let enabled: Bool

    private let lock = NSLock()
    private var frames = 0
    private var skippedFrames = 0
    private var totalSkippedFrames = 0
    private var totalSeconds: Double = 0
    private var worstSeconds: Double = 0
    private var lastReport = Date()
    private var submittedFrames = 0
    private var windowSubmittedFrames = 0
    private var rejectedFrames = 0
    private var windowRejectedFrames = 0
    private var completedFrames = 0
    private var windowCompletedFrames = 0
    private var failedCompletions = 0
    private var windowFailedCompletions = 0
    private var presentedFrames = 0
    private var windowPresentedFrames = 0
    private var invalidPresentedTimes = 0
    private var windowInvalidPresentedTimes = 0
    private var presentationHistory: [AlacrittyPresentedFrame] = []
    private var rebuiltRows = 0
    private var packedInstances = 0
    private var windowPackedInstances = 0
    private var uploadedInstances = 0
    private var windowUploadedInstances = 0
    private var windowRebuiltRows = 0
    private var lastPresented: AlacrittyPresentedFrame?
    private let presentationObservationEnabled = Atomic<Bool>(false)
    private var bridgeAttempts: UInt64 = 0
    private var bridgeBusyAttempts: UInt64 = 0
    private var bridgeBusyCount: UInt64 = 0
    private var bridgeLockWaitNs: UInt64 = 0
    private var bridgeSnapshotNs: UInt64 = 0
    private var bridgeBuildNs: UInt64 = 0
    private var bridgePackedRows: UInt64 = 0

    init(enabled: Bool? = nil) {
        self.enabled = enabled ?? (
            ProcessInfo.processInfo.environment["YEET_RENDER_STATS"] != nil
                || UserDefaults.standard.bool(forKey: "YEET_RENDER_STATS")
        )
    }

    /// Enables the small presentation record used by ScrollBench. It is off
    /// by default, so normal rendering does not retain a per-frame record.
    func startPresentationObservation() {
        lock.lock()
        presentationObservationEnabled.store(true, ordering: .releasing)
        presentedFrames = 0
        windowPresentedFrames = 0
        invalidPresentedTimes = 0
        windowInvalidPresentedTimes = 0
        presentationHistory.removeAll(keepingCapacity: true)
        lastPresented = nil
        lock.unlock()
    }

    func stopPresentationObservation() {
        lock.lock()
        presentationObservationEnabled.store(false, ordering: .releasing)
        lock.unlock()
    }

    /// The renderer checks this before installing a Metal presentation handler.
    /// The acquire load pairs with the release store used when observation
    /// starts or stops, so Metal callbacks read the state safely.
    var shouldObservePresentation: Bool {
        enabled || presentationObservationEnabled.load(ordering: .acquiring)
    }

    func frame(seconds: Double) {
        guard enabled else { return }
        lock.lock()
        frames += 1
        totalSeconds += seconds
        worstSeconds = max(worstSeconds, seconds)
        let due = Date().timeIntervalSince(lastReport) >= 1
        lock.unlock()
        if due { report() }
    }

    func recordFrame(
        rebuiltRows: Int,
        packedInstances: Int,
        uploadedInstances: Int = 0,
        submitted: Bool
    ) {
        guard enabled || presentationObservationEnabled.load(ordering: .acquiring) else { return }
        lock.lock()
        if submitted {
            submittedFrames += 1
            windowSubmittedFrames += 1
        } else {
            rejectedFrames += 1
            windowRejectedFrames += 1
        }
        self.rebuiltRows += max(rebuiltRows, 0)
        windowRebuiltRows += max(rebuiltRows, 0)
        self.packedInstances += max(packedInstances, 0)
        windowPackedInstances += max(packedInstances, 0)
        self.uploadedInstances += max(uploadedInstances, 0)
        windowUploadedInstances += max(uploadedInstances, 0)
        lock.unlock()
    }

    func recordCompleted(success: Bool) {
        guard enabled || presentationObservationEnabled.load(ordering: .acquiring) else { return }
        lock.lock()
        if success {
            completedFrames += 1
            windowCompletedFrames += 1
        } else {
            failedCompletions += 1
            windowFailedCompletions += 1
        }
        lock.unlock()
    }

    func recordPresented(displayOffset: Int, at timestamp: CFTimeInterval) {
        lock.lock()
        guard enabled || presentationObservationEnabled.load(ordering: .acquiring) else {
            lock.unlock()
            return
        }
        guard timestamp.isFinite, timestamp > 0 else {
            invalidPresentedTimes += 1
            windowInvalidPresentedTimes += 1
            lock.unlock()
            return
        }
        presentedFrames += 1
        windowPresentedFrames += 1
        let sequence = UInt64(presentedFrames)
        let frame = AlacrittyPresentedFrame(
            sequence: sequence,
            displayOffset: displayOffset,
            timestamp: timestamp
        )
        lastPresented = frame
        if presentationObservationEnabled.load(ordering: .acquiring) {
            presentationHistory.append(frame)
            if presentationHistory.count > 4096 {
                presentationHistory.removeFirst(presentationHistory.count - 4096)
            }
        }
        lock.unlock()
    }

    func recordBridgeFrame(
        busy: Bool,
        busyCount: UInt64,
        lockWaitNs: UInt64,
        snapshotNs: UInt64,
        buildNs: UInt64,
        packedRows: UInt64
    ) {
        lock.lock()
        guard enabled || presentationObservationEnabled.load(ordering: .acquiring) else {
            lock.unlock()
            return
        }
        bridgeAttempts &+= 1
        if busy { bridgeBusyAttempts &+= 1 }
        bridgeBusyCount = max(bridgeBusyCount, busyCount)
        bridgeLockWaitNs &+= lockWaitNs
        bridgeSnapshotNs &+= snapshotNs
        bridgeBuildNs &+= buildNs
        bridgePackedRows &+= packedRows
        lock.unlock()
    }

    /// Returns presented frames after `sequence`, in presentation order. The
    /// bounded history keeps a long-running session from retaining frames
    /// forever while allowing a benchmark to consume each real timestamp.
    func presentedFrames(since sequence: UInt64 = 0) -> [AlacrittyPresentedFrame] {
        lock.lock()
        let frames = presentationHistory.filter { $0.sequence > sequence }
        lock.unlock()
        return frames
    }

    func snapshot() -> AlacrittyRenderStatsSnapshot {
        lock.lock()
        let snapshot = AlacrittyRenderStatsSnapshot(
            submittedFrames: submittedFrames,
            rejectedFrames: rejectedFrames,
            completedFrames: completedFrames,
            failedCompletions: failedCompletions,
            presentedFrames: presentedFrames,
            invalidPresentedTimes: invalidPresentedTimes,
            bridgeAttempts: bridgeAttempts,
            bridgeBusyAttempts: bridgeBusyAttempts,
            bridgeBusyCount: bridgeBusyCount,
            bridgeLockWaitNs: bridgeLockWaitNs,
            bridgeSnapshotNs: bridgeSnapshotNs,
            bridgeBuildNs: bridgeBuildNs,
            bridgePackedRows: bridgePackedRows,
            rebuiltRows: rebuiltRows,
            packedInstances: packedInstances,
            uploadedInstances: uploadedInstances,
            skippedFrames: totalSkippedFrames,
            lastPresented: lastPresented
        )
        lock.unlock()
        return snapshot
    }

    func skipped() {
        guard enabled else { return }
        lock.lock()
        skippedFrames += 1
        totalSkippedFrames += 1
        lock.unlock()
    }

#if DEBUG
    func flushForTesting() {
        report()
    }
#endif

    private func report() {
        lock.lock()
        let attempted = frames
        let skipped = skippedFrames
        let submitted = windowSubmittedFrames
        let rejected = windowRejectedFrames
        let completed = windowCompletedFrames
        let failed = windowFailedCompletions
        let presented = windowPresentedFrames
        let invalidPresented = windowInvalidPresentedTimes
        let rows = windowRebuiltRows
        let instances = windowPackedInstances
        let uploaded = windowUploadedInstances
        let mean = attempted > 0 ? totalSeconds / Double(attempted) * 1000 : 0
        let worst = worstSeconds * 1000
        frames = 0
        skippedFrames = 0
        totalSeconds = 0
        worstSeconds = 0
        windowSubmittedFrames = 0
        windowRejectedFrames = 0
        windowCompletedFrames = 0
        windowFailedCompletions = 0
        windowPresentedFrames = 0
        windowInvalidPresentedTimes = 0
        windowRebuiltRows = 0
        windowPackedInstances = 0
        windowUploadedInstances = 0
        lastReport = Date()
        lock.unlock()

        NSLog(String(
            format: "yeet-render window attempted=%d skipped=%d submitted=%d rejected=%d completed=%d failed=%d presented=%d invalidPresented=%d rows=%d instances=%d uploaded=%d mean=%.3fms worst=%.3fms",
            attempted, skipped, submitted, rejected, completed, failed, presented,
            invalidPresented, rows, instances, uploaded, mean, worst
        ))
    }
}
