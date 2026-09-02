//
//  DirectoryWatcher.swift
//  kero
//

import Foundation

/// Coalesced FSEvents watch on one directory tree. The stream runs off the
/// main actor; change notifications hop back after a short settle so a burst
/// of writes (npm install, git checkout) becomes one rebuild.
nonisolated final class DirectoryWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var watchedPath = ""
    private var generation: UInt = 0
    private var pending: DispatchWorkItem?
    var onChange: (@MainActor () -> Void)?

    func watch(path: String) {
        let standardized = (path as NSString).standardizingPath
        lock.lock()
        let alreadyWatching = standardized == watchedPath
        lock.unlock()
        guard !alreadyWatching else { return }
        stop()

        lock.lock()
        watchedPath = standardized
        lock.unlock()
        guard !standardized.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [standardized] as CFArray
        // 0.4s latency plus the extra coalesce below — cheap enough that
        // the old 2s poll is no longer the source of truth.
        guard let created = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                    .scheduleNotify()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
            )
        ) else { return }

        lock.lock()
        stream = created
        lock.unlock()
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
    }

    func stop() {
        lock.lock()
        pending?.cancel()
        pending = nil
        generation &+= 1
        let existing = stream
        stream = nil
        watchedPath = ""
        lock.unlock()
        if let existing {
            FSEventStreamStop(existing)
            FSEventStreamInvalidate(existing)
            FSEventStreamRelease(existing)
        }
    }

    deinit {
        stop()
    }

    private func scheduleNotify() {
        lock.lock()
        generation &+= 1
        let token = generation
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.generation == token
            self.lock.unlock()
            guard stillCurrent else { return }
            let handler = self.onChange
            DispatchQueue.main.async {
                handler?()
            }
        }
        pending = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
