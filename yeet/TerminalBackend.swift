//
//  TerminalBackend.swift
//  kero
//

import AppKit

/// The program, arguments, directory, and environment for one terminal PTY.
/// TerminalSession resolves the login shell and replay script before launch.
struct TerminalLaunch {
    /// Program to exec and the arguments after argv[0].
    let program: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
}

/// What Alacritty reports to the session that owns it. The session applies
/// app policy for notifications, links, clipboard access, and process exit.
///
/// Delivery rule: invoke these only from a main-queue dispatch point (an event
/// bounce, a timer, a Task) — never synchronously out of an `NSView` lifecycle
/// callback such as `layout()` or `viewDidMoveToWindow()`. `TerminalSession`
/// publishes most of this state, and a send from inside a SwiftUI view update
/// logs "Publishing changes from within view updates" and can drop the
/// invalidation.
@MainActor
protocol TerminalBackendEvents: AnyObject {
    func terminalDidChangeTitle(_ title: String)
    func terminalDidChangeWorkingDirectory(_ path: String)
    func terminalDidChangeCellSize(_ size: CGSize)
    func terminalDidRingBell()
    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent)

    /// The child process is gone, or is about to be. `processAlive` is false
    /// when the backend has already reaped it.
    func terminalDidClose(processAlive: Bool)

    func terminalDidRequestDesktopNotification(title: String, body: String)
    func terminalDidRequestOpenURL(_ url: String)
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget?
    func terminalDidScroll(_ position: TerminalScrollPosition)
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest)
    /// OSC 52 copy. The session applies `clipboard-write` (ask / allow / deny).
    func terminalDidRequestClipboardWrite(_ request: TerminalClipboardRequest)

    /// The backend started a find of its own accord — Kero's ⌘E path resolves
    /// the needle from the grid selection, so the bar learns it from here.
    func terminalDidBeginFind(needle: String)
    func terminalDidEndFind()
    func terminalDidUpdateFindTotal(_ total: Int?)
    func terminalDidUpdateFindSelected(_ selected: Int?)
    /// The terminal changed while an incremental scan was in flight. The
    /// session keeps the last completed count visible until the replacement
    /// scan reports, but must not navigate its stale coordinates.
    func terminalDidInvalidateFindResults(lastReportedTotal: Int?)
}

/// A Command-clickable terminal value after the owning session has resolved
/// it against the pane's live local working directory.
enum TerminalLinkTarget {
    case url(URL)
    case file(URL)
}

/// Backend-neutral OSC 133 command lifecycle reports. Alacritty extracts all
/// four semantic markers at the PTY boundary.
enum TerminalShellIntegrationEvent: Equatable, Sendable {
    case promptStart
    case commandStart
    case commandExecuting
    case commandFinished(exitCode: Int?, durationNanos: UInt64?)
}

/// Semantic state retained per terminal session for command navigation,
/// completion notifications, duration display, and other future features.
struct TerminalCommandLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case prompt
        case input
        case executing
    }

    var phase: Phase = .idle
    var lastExitCode: Int?
    var lastDurationNanos: UInt64?
    /// Monotonic signal for consumers that need to react to every completed
    /// command, including consecutive commands with identical result metadata.
    var completionSequence: UInt64 = 0
}

/// Where the viewport sits within a surface's total content. Kept as raw row
/// counts rather than a fraction so the overlay scrollbar can both draw itself
/// and map a drag back onto a row.
struct TerminalScrollPosition: Equatable, Sendable {
    /// Rows of content, viewport plus scrollback.
    let totalRows: UInt64
    /// Rows visible in the viewport.
    let viewportRows: UInt64
    /// The content row currently at the top of the viewport.
    let topRow: UInt64

    /// False when everything fits, so there is nothing to scroll.
    var isScrollable: Bool {
        totalRows > viewportRows && viewportRows > 0
    }

    /// Visible fraction of the content, 0…1 — the scrollbar knob's length.
    var proportion: Double {
        totalRows > 0 ? Double(viewportRows) / Double(totalRows) : 1
    }

    /// The knob's travel, 0 at the top of the scrollback and 1 at the live
    /// prompt. Pinned to the bottom when there is nothing to scroll.
    var position: Double {
        guard isScrollable else { return 1 }
        return Double(topRow) / Double(totalRows - viewportRows)
    }

    /// The top row a scrollbar drag to `fraction` of its travel lands on.
    func row(atDragFraction fraction: Double) -> UInt64 {
        let available = totalRows > viewportRows ? totalRows - viewportRows : 0
        return UInt64((Double(available) * fraction).rounded())
    }
}

/// A backend asking Kero to apply clipboard-read or clipboard-write policy
/// to an OSC 52 request. Exactly one of ``approve()`` and ``deny()`` must
/// be called. The session may resolve this without a sheet when the policy
/// is allow or deny.
@MainActor
final class TerminalClipboardRequest {
    /// The text the program would receive.
    let contents: String

    private let resolve: @MainActor (Bool) -> Void

    init(contents: String, resolve: @escaping @MainActor (Bool) -> Void) {
        self.contents = contents
        self.resolve = resolve
    }

    func approve() { resolve(true) }
    func deny() { resolve(false) }
}
