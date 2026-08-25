//
//  AlacrittyFind.swift
//  kero
//

import Foundation

/// Main-queue state for one pending worker result. Replacing a request keeps
/// the existing timer, so its callback always reads the newest generation.
/// Cancellation advances the token and invalidates callbacks that are already
/// queued but have not started.
struct AlacrittyFindPollState {
    private(set) var pendingGeneration: UInt64? = nil
    private(set) var pollScheduled = false
    private var token: UInt64 = 0

    mutating func replacePending(generation: UInt64) {
        pendingGeneration = generation
    }

    mutating func armPoll() -> UInt64? {
        guard pendingGeneration != nil, !pollScheduled else { return nil }
        pollScheduled = true
        token &+= 1
        if token == 0 { token = 1 }
        return token
    }

    mutating func beginPoll(token: UInt64) -> UInt64? {
        guard token == self.token else { return nil }
        pollScheduled = false
        return pendingGeneration
    }

    /// Cancels a queued timer before a worker wake polls the result slot. The
    /// pending generation is retained so a missing result can be re-armed once
    /// instead of allowing the old callback and the wakeup to race.
    mutating func cancelScheduledPoll() -> UInt64? {
        token &+= 1
        if token == 0 { token = 1 }
        pollScheduled = false
        return pendingGeneration
    }

    mutating func completePoll() {
        pendingGeneration = nil
    }

    mutating func cancel() {
        token &+= 1
        if token == 0 { token = 1 }
        pendingGeneration = nil
        pollScheduled = false
    }
}

/// Debounced refresh state for a query that the worker invalidated while its
/// terminal was changing. A generation can own at most one delayed refresh.
struct AlacrittyFindRefreshState: Equatable {
    private(set) var activeGeneration: UInt64? = nil
    private(set) var scheduledGeneration: UInt64? = nil

    mutating func activate(generation: UInt64) {
        activeGeneration = generation
        scheduledGeneration = nil
    }

    @discardableResult
    mutating func schedule(generation: UInt64) -> Bool {
        guard activeGeneration == generation,
              scheduledGeneration == nil
        else { return false }
        scheduledGeneration = generation
        return true
    }

    @discardableResult
    mutating func begin(generation: UInt64) -> Bool {
        guard activeGeneration == generation,
              scheduledGeneration == generation
        else { return false }
        scheduledGeneration = nil
        return true
    }

    mutating func cancel() {
        activeGeneration = nil
        scheduledGeneration = nil
    }
}

/// A Find action that the nonblocking bridge has not accepted yet. Retaining
/// the intent lets a transient worker wake failure recover without throwing
/// away the query and its visible count.
enum AlacrittyFindRequest: Equatable {
    case begin(needle: String)
    case step(forward: Bool)
}

/// One bounded, main-queue retry timer for a rejected Find action. Each retry
/// receives a fresh token so cancelling, replacing, or successfully delivering
/// an action makes already queued callbacks harmless.
struct AlacrittyFindRetryState {
    private static let initialDelayMilliseconds = 10
    private static let maximumDelayMilliseconds = 250

    private(set) var request: AlacrittyFindRequest?
    private(set) var nextDelayMilliseconds = Self.initialDelayMilliseconds
    private var token: UInt64 = 0

    mutating func schedule(_ request: AlacrittyFindRequest) -> (
        token: UInt64,
        delayMilliseconds: Int
    ) {
        self.request = request
        advanceToken()
        let delayMilliseconds = nextDelayMilliseconds
        nextDelayMilliseconds = min(
            nextDelayMilliseconds * 2,
            Self.maximumDelayMilliseconds
        )
        return (token, delayMilliseconds)
    }

    mutating func beginRetry(token: UInt64) -> AlacrittyFindRequest? {
        guard token == self.token else { return nil }
        defer { request = nil }
        return request
    }

    mutating func accepted() {
        request = nil
        nextDelayMilliseconds = Self.initialDelayMilliseconds
        advanceToken()
    }

    mutating func cancel() {
        request = nil
        nextDelayMilliseconds = Self.initialDelayMilliseconds
        advanceToken()
    }

    private mutating func advanceToken() {
        token &+= 1
        if token == 0 { token = 1 }
    }
}

/// Drives find-in-terminal for the Alacritty backend.
///
/// The bridge collects matches and moves the selection on the PTY owner. This
/// object only queues actions and polls a lock-free result slot, so the main
/// thread never waits for the terminal or scans scrollback.
final class AlacrittyFind {
    private static let invalidationRefreshDelayMilliseconds = 75

    private var total = 0
    private var hasReportedTotal = false
    private var nextGeneration: UInt64 = 0
    private var activeNeedle: String?
    private var activeHandle: OpaquePointer?
    private var activeEvents: (any TerminalBackendEvents)?
    private var activeGeneration: UInt64 = 0
    private var resultsInvalidated = false
    private var polling = AlacrittyFindPollState()
    private var pollWorkItem: DispatchWorkItem?
    private var refreshWorkItem: DispatchWorkItem?
    private var refreshState = AlacrittyFindRefreshState()
    private var retryWorkItem: DispatchWorkItem?
    private var retryState = AlacrittyFindRetryState()

    private func makeGeneration() -> UInt64 {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        return nextGeneration
    }

    private func schedulePoll() {
        guard let token = polling.armPoll() else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pollWorkItem = nil
            guard let generation = self.polling.beginPoll(token: token) else {
                return
            }
            self.poll(generation: generation)
        }
        pollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: workItem)
    }

    private func poll(
        generation: UInt64,
        rescheduleWhenMissing: Bool = true
    ) {
        guard let handle = activeHandle else { return }

        var result = KeroFindResult(
            generation: 0,
            kind: 0,
            total: 0,
            selected: -1
        )
        guard kero_alacritty_find_poll(handle, &result) else {
            if rescheduleWhenMissing, polling.pendingGeneration != nil {
                schedulePoll()
            }
            return
        }
        // A result from an older query may still be in the slot. Keep polling
        // until this request has reached the worker. A newer result means a
        // rapid action superseded this closure; consume that newest result.
        guard result.generation == activeGeneration,
              result.generation == generation
        else {
            if rescheduleWhenMissing, polling.pendingGeneration != nil {
                schedulePoll()
            }
            return
        }
        let events = activeEvents
        polling.completePoll()

        switch result.kind {
        case KERO_FIND_RESULT_BEGIN:
            total = Int(result.total)
            hasReportedTotal = true
            resultsInvalidated = false
            events?.terminalDidUpdateFindTotal(total)
            events?.terminalDidUpdateFindSelected(nil)
        case KERO_FIND_RESULT_STEP:
            events?.terminalDidUpdateFindSelected(
                result.selected >= 0 ? Int(result.selected) : nil
            )
        case KERO_FIND_RESULT_END:
            total = 0
            hasReportedTotal = false
            resultsInvalidated = false
        case KERO_FIND_RESULT_INVALIDATED:
            resultsInvalidated = true
            events?.terminalDidInvalidateFindResults(
                lastReportedTotal: hasReportedTotal ? total : nil
            )
            // A retrying step targets coordinates the terminal has just
            // invalidated. Refreshing the query is the only valid recovery.
            cancelRetry()
            scheduleInvalidationRefresh(generation: result.generation)
        default:
            break
        }
    }

    private func scheduleInvalidationRefresh(generation: UInt64) {
        guard let needle = activeNeedle,
              let handle = activeHandle,
              refreshState.schedule(generation: generation)
        else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.refreshState.begin(generation: generation),
                  self.activeGeneration == generation,
                  self.activeNeedle == needle,
                  self.activeHandle == handle
            else { return }
            self.refreshWorkItem = nil
            self.startBegin(
                needle: needle,
                handle: handle,
                events: self.activeEvents,
                preservingReportedTotal: true
            )
        }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + .milliseconds(Self.invalidationRefreshDelayMilliseconds),
            execute: workItem
        )
    }

    private func cancelPendingPoll() {
        pollWorkItem?.cancel()
        pollWorkItem = nil
        polling.cancel()
    }

    private func cancelRefresh() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        refreshState.cancel()
    }

    private func completeRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryState.accepted()
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryState.cancel()
    }

    private func scheduleRetry(_ request: AlacrittyFindRequest) {
        retryWorkItem?.cancel()
        let retry = retryState.schedule(request)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let request = self.retryState.beginRetry(token: retry.token)
            else { return }
            self.retryWorkItem = nil
            self.submit(request)
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(retry.delayMilliseconds),
            execute: workItem
        )
    }

    /// Makes one FFI submission. A false return may occur after the bridge
    /// accepted the message but could not wake the worker, so every attempted
    /// submission owns a fresh generation. The active generation changes only
    /// after acceptance: a rejected Step must still receive invalidations for
    /// the last confirmed search while it waits to retry.
    private func submit(_ request: AlacrittyFindRequest) {
        guard let handle = activeHandle else {
            cancel()
            return
        }

        let generation = makeGeneration()
        let accepted: Bool
        switch request {
        case .begin(let needle):
            accepted = needle.withCString {
                kero_alacritty_find_begin_async(handle, $0, generation)
            }
        case .step(let forward):
            accepted = kero_alacritty_find_step_async(handle, forward, generation)
        }

        guard accepted else {
            scheduleRetry(request)
            return
        }

        activeGeneration = generation
        refreshState.activate(generation: generation)
        completeRetry()
        polling.replacePending(generation: generation)
        schedulePoll()
    }

    private func startBegin(
        needle: String,
        handle: OpaquePointer,
        events: (any TerminalBackendEvents)?,
        preservingReportedTotal: Bool
    ) {
        cancelPendingPoll()
        cancelRefresh()
        cancelRetry()
        if !preservingReportedTotal {
            total = 0
            hasReportedTotal = false
            resultsInvalidated = false
        }
        activeNeedle = needle
        activeHandle = handle
        activeEvents = events
        // Results for a replaced needle must never repaint the new query
        // while its first nonblocking submission is waiting to retry.
        activeGeneration = 0
        submit(.begin(needle: needle))
    }

    /// A PTY wake is a cheap chance to consume an invalidation result without
    /// waiting for the next timer. It cancels the queued poll token first, so
    /// the wake and timer cannot both consume the slot.
    func observeWakeup() {
        guard activeHandle != nil else { return }
        let pendingGeneration = polling.pendingGeneration
        let generation = polling.cancelScheduledPoll() ?? activeGeneration
        pollWorkItem?.cancel()
        pollWorkItem = nil
        poll(
            generation: generation,
            rescheduleWhenMissing: pendingGeneration != nil
        )
    }

    /// Invalidates delayed polls before the caller releases its terminal
    /// handle. The delayed closure captures only `self` weakly and must pass
    /// this token check before it can read the handle or call the bridge.
    func cancel() {
        total = 0
        hasReportedTotal = false
        cancelPendingPoll()
        cancelRefresh()
        cancelRetry()
        activeNeedle = nil
        activeHandle = nil
        activeEvents = nil
        activeGeneration = 0
        resultsInvalidated = false
    }

    deinit {
        cancel()
    }

    func begin(
        needle: String,
        handle: OpaquePointer?,
        events: (any TerminalBackendEvents)?
    ) {
        guard let handle else {
            cancel()
            return
        }
        guard !needle.isEmpty else {
            end(handle: handle)
            events?.terminalDidUpdateFindTotal(nil)
            events?.terminalDidUpdateFindSelected(nil)
            return
        }

        startBegin(
            needle: needle,
            handle: handle,
            events: events,
            preservingReportedTotal: false
        )
    }

    func step(
        forward: Bool,
        handle: OpaquePointer?,
        events: (any TerminalBackendEvents)?
    ) {
        guard let handle else {
            cancel()
            return
        }
        guard total > 0, !resultsInvalidated else { return }
        cancelPendingPoll()
        cancelRefresh()
        cancelRetry()
        activeHandle = handle
        activeEvents = events
        submit(.step(forward: forward))
    }

    func end(handle: OpaquePointer?) {
        total = 0
        guard let handle else {
            cancel()
            return
        }
        let generation = makeGeneration()
        _ = kero_alacritty_find_end_async(handle, generation)
        cancel()
    }
}
