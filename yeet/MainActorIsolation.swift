//
//  MainActorIsolation.swift
//  kero
//

import Combine
import Foundation

/// Runs `body` as main-actor work without asking the concurrency runtime to
/// confirm the isolation first.
///
/// Only for callbacks whose main thread is structural: AppKit invoking an
/// `NSEvent` local monitor or a view method, a `NotificationCenter` observer
/// registered on `.main`, a `Timer` on the main run loop. Where the thread is
/// merely expected, keep `MainActor.assumeIsolated` — there its trap is the
/// point.
///
/// `MainActor.assumeIsolated` re-derives a guarantee the caller already has, by
/// dereferencing Swift concurrency's per-thread executor record. That is wrong
/// twice over on an input path. It costs a heap-allocated closure box, an
/// escape check and several runtime calls for every key press and pointer move.
/// And if the record is ever left stale — an Objective-C exception unwinding
/// out of a main-actor job does it, and AppKit swallows those at the top of its
/// event loop — the dereference segfaults inside `swift_getObjectType` instead
/// of trapping cleanly.
///
/// This is `MainActor.assumeIsolated`'s body with its executor check replaced by
/// a debug-only thread check: same `unsafeBitCast` of the isolated closure to an
/// unisolated one, which is representation-preserving because isolation carries
/// no runtime component in a function value. A call site that stops being
/// main-thread still trips in Debug; release builds pay nothing.
@inline(__always)
nonisolated func assumeMainActor<T>(_ body: @MainActor () -> T) -> T {
    assert(Thread.isMainThread, "assumeMainActor off the main thread")
    return withoutActuallyEscaping(body) { body in
        unsafeBitCast(body, to: (() -> T).self)()
    }
}

/// Runs `work` on the next main run-loop turn. SwiftUI forbids
/// `@Published` / `@State` writes during a view update; hopping here
/// keeps inspector sync and dialog resets out of that window.
func afterViewUpdate(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        assumeMainActor(work)
    }
}

/// `objectWillChange` that always fires after the current SwiftUI pass.
///
/// Child `@Published` willSet sinks run while SwiftUI is still evaluating a
/// parent `body`. A synchronous `send()` there logs "Publishing changes from
/// within view updates" and can drop the nested invalidation. Coalesce a burst
/// of child publishes into one send on the next run-loop turn.
@MainActor
final class CoalescedObjectWillChange {
    private var queued = false
    private let publisher: ObservableObjectPublisher

    init(_ publisher: ObservableObjectPublisher) {
        self.publisher = publisher
    }

    func send() {
        guard !queued else { return }
        queued = true
        afterViewUpdate { [weak self] in
            guard let self else { return }
            self.queued = false
            self.publisher.send()
        }
    }
}

/// Batches stored-property mutations into one `objectWillChange`.
///
/// `@Published` sends on every assignment. The first send can start a nested
/// SwiftUI pass; later assignments in the same function then log "Publishing
/// changes from within view updates". Use this on `ObservableObject` types
/// whose UI state is not `@Published`, and call `perform` around each
/// transaction.
@MainActor
final class ObjectChangeBatch {
    private var queued = false
    private let publisher: ObservableObjectPublisher

    init(_ publisher: ObservableObjectPublisher) {
        self.publisher = publisher
    }

    func perform(_ body: () -> Void) {
        body()
        guard !queued else { return }
        queued = true
        afterViewUpdate { [weak self] in
            guard let self else { return }
            self.queued = false
            self.publisher.send()
        }
    }
}
