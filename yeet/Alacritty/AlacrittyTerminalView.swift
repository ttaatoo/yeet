//
//  AlacrittyTerminalView.swift
//  kero
//

import AppKit
import Darwin
import IOSurface
import Metal
import QuartzCore

/// Host-side work that must be presented to one terminal frame.
///
/// The render call consumes a copy. If the bridge reports BUSY, that copy is
/// restored before any input queued after the failed attempt, so no scroll or
/// redraw request is lost. A delta after an absolute target is folded into the
/// target so the FFI never receives two competing scroll arguments.
struct AlacrittyFrameIntent: Equatable {
    private(set) var scrollDelta: Int64 = 0
    private(set) var scrollTarget: Int64?
    private(set) var hasTargetIntent = false
    private(set) var needsTerminalDamageCheck = false
    private(set) var forceFull = false
    private(set) var cursorOnly = false

    var isEmpty: Bool {
        scrollDelta == 0
            && !hasTargetIntent
            && !needsTerminalDamageCheck
            && !forceFull
            && !cursorOnly
    }

    var hasAbsoluteTarget: Bool { scrollTarget != nil }

    /// The C bridge currently accepts a signed 32-bit line delta. Keep a
    /// wider accumulator so many input events cannot wrap before a frame.
    var scrollDeltaArgument: Int32 { Int32(clamping: scrollDelta) }

    var scrollTargetArgument: Int64 { scrollTarget ?? -1 }

    mutating func addScroll(lines: Int) {
        let value = Int64(clamping: lines)
        if hasTargetIntent, let target = scrollTarget {
            scrollTarget = Self.saturatedTargetAdd(target, value)
        } else {
            scrollDelta = Self.saturatedAdd(scrollDelta, value)
        }
    }

    mutating func setScrollTarget(_ target: Int64?) {
        // Rust reserves -1 for "no target". Keep every concrete target in the
        // non-negative range, including after callers provide a stale offset.
        scrollTarget = target.map { max(0, $0) }
        hasTargetIntent = true
        // An absolute target supersedes all earlier relative movement. This
        // also makes the FFI arguments unambiguous: Rust ignores delta when
        // target >= 0.
        scrollDelta = 0
    }

    mutating func request(forceFull: Bool = false, cursorOnly: Bool = false) {
        self.forceFull = self.forceFull || forceFull
        self.cursorOnly = self.cursorOnly || cursorOnly
    }

    mutating func requestTerminalDamageCheck() {
        needsTerminalDamageCheck = true
    }

    /// Move all currently pending work out of the queue for one frame.
    mutating func take() -> Self {
        let taken = self
        self = Self()
        return taken
    }

    /// Restore a failed frame before the events collected after it. A newer
    /// absolute target wins; deltas and redraw flags are additive.
    mutating func restore(_ consumed: Self) {
        let newer = self
        self = consumed
        merge(newer)
    }

    mutating func merge(_ newer: Self) {
        if newer.hasTargetIntent {
            scrollTarget = newer.scrollTarget
            hasTargetIntent = true
            scrollDelta = 0
        }
        if newer.scrollDelta != 0 {
            if hasTargetIntent, let target = scrollTarget {
                scrollTarget = Self.saturatedTargetAdd(target, newer.scrollDelta)
            } else {
                scrollDelta = Self.saturatedAdd(scrollDelta, newer.scrollDelta)
            }
        }
        needsTerminalDamageCheck =
            needsTerminalDamageCheck || newer.needsTerminalDamageCheck
        forceFull = forceFull || newer.forceFull
        cursorOnly = cursorOnly || newer.cursorOnly
    }

    /// The bridge already applied the scroll and drained emulator damage, so
    /// a drawable or Metal failure must request a fresh full snapshot without
    /// replaying the consumed host movement.
    mutating func recoverAfterAcceptedFrameFailure() {
        request(forceFull: true)
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0, lhs > Int64.max - rhs { return Int64.max }
        if rhs < 0, lhs < Int64.min - rhs { return Int64.min }
        return lhs + rhs
    }

    private static func saturatedTargetAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        max(0, saturatedAdd(lhs, rhs))
    }
}

/// A bounded terminal grid derived from AppKit layout geometry.
///
/// Auto Layout can transiently provide an invalid or enormous frame while a
/// restored window is being attached.  The terminal emulator allocates one
/// cell per row and column, so do not let an intermediate view size turn into
/// an unbounded allocation.
struct AlacrittyGridSize: Equatable {
    /// Alacritty's parser assumes at least two cells in each axis. Keep the
    /// host and FFI contracts aligned so a transient one-pixel view cannot
    /// create an invalid emulator grid.
    static let minimumColumns = 2
    static let minimumRows = 2
    /// Do not start or reflow restored history until AppKit has assigned a
    /// pane that can actually display a terminal. This excludes zero- and
    /// one-cell frames during window restoration without restricting normal
    /// small panes.
    static let minimumStableColumns = 20
    static let minimumStableRows = 4
    static let maximumColumns = 1_024
    static let maximumRows = 512
    static let maximumCellCount = 262_144

    let columns: Int
    let rows: Int

    var isStableForBackend: Bool {
        columns >= Self.minimumStableColumns && rows >= Self.minimumStableRows
    }

    /// A restored terminal can briefly inherit a nonsensical Auto Layout
    /// frame. A real window can span two displays, but it must not grow far
    /// beyond the largest available display before the emulator reallocates
    /// every retained history row.
    static func isPlausibleViewport(
        _ viewportSize: CGSize,
        within displaySize: CGSize
    ) -> Bool {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              displaySize.width.isFinite,
              displaySize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              displaySize.width > 0,
              displaySize.height > 0
        else {
            return false
        }

        return viewportSize.width <= displaySize.width * 2
            && viewportSize.height <= displaySize.height * 2
    }

    static func from(
        viewportSize: CGSize,
        cellSize: CGSize,
        padding: CGPoint
    ) -> Self {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              cellSize.width.isFinite,
              cellSize.height.isFinite,
              cellSize.width > 0,
              cellSize.height > 0
        else {
            return capped(columns: 0, rows: 0)
        }

        let usableWidth = viewportSize.width - padding.x * 2
        let usableHeight = viewportSize.height - padding.y * 2
        return capped(
            columns: count(for: usableWidth / cellSize.width, limit: maximumColumns),
            rows: count(for: usableHeight / cellSize.height, limit: maximumRows)
        )
    }

    static func capped(columns: Int, rows: Int) -> Self {
        let columns = min(max(columns, minimumColumns), maximumColumns)
        let rows = min(max(rows, minimumRows), maximumRows)
        let maximumRowsForColumns = max(minimumRows, maximumCellCount / columns)
        return Self(columns: columns, rows: min(rows, maximumRowsForColumns))
    }

    private static func count(for value: CGFloat, limit: Int) -> Int {
        guard value.isFinite, value > 1 else { return 0 }
        guard value < CGFloat(limit) else { return limit }
        return Int(value.rounded(.down))
    }
}

enum AlacrittyFrameRetryPolicy {
    static let maxPresentationRecoveryAttempts = 5
    static let presentationRecoveryProbeDelayMilliseconds = 1_000

    private static let presentationRecoveryDelaysMilliseconds = [
        1, 4, 16, 64, 250,
    ]

    static func shouldPauseDisplayLink(renderSucceeded: Bool) -> Bool {
        !renderSucceeded
    }

    static func shouldWakeDisplayLinkForDamage(
        recoveryScheduled: Bool,
        recoveryAttempts: Int
    ) -> Bool {
        !recoveryScheduled && recoveryAttempts == 0
    }

    static func shouldPauseDisplayLinkForSelectionRetry(
        renderSucceeded: Bool,
        retryWaiting: Bool,
        hasOtherPendingWork: Bool
    ) -> Bool {
        renderSucceeded && retryWaiting && !hasOtherPendingWork
    }

    static func shouldSchedulePresentationRecovery(
        framePending: Bool,
        recoveryScheduled: Bool,
        attempts: Int
    ) -> Bool {
        framePending
            && !recoveryScheduled
            && attempts < maxPresentationRecoveryAttempts
    }

    static func shouldSchedulePresentationRecoveryProbe(
        framePending: Bool,
        probeScheduled: Bool,
        attempts: Int
    ) -> Bool {
        framePending
            && !probeScheduled
            && attempts >= maxPresentationRecoveryAttempts
    }

    static func presentationRecoveryDelayMilliseconds(for attempt: Int) -> Int {
        let index = min(
            max(attempt, 0),
            presentationRecoveryDelaysMilliseconds.count - 1
        )
        return presentationRecoveryDelaysMilliseconds[index]
    }

    static func shouldScheduleBusyRetry(
        framePending: Bool,
        retryScheduled: Bool,
        retriesRemaining: Int
    ) -> Bool {
        framePending && !retryScheduled && retriesRemaining > 0
    }
}

enum AlacrittySelectionRetryPolicy {
    static let probeDelayMilliseconds = 1_000

    static func shouldWakeDisplayLink(
        retryWaiting: Bool,
        hasOtherPendingWork: Bool
    ) -> Bool {
        !retryWaiting || hasOtherPendingWork
    }

    static func shouldScheduleProbe(
        actionPending: Bool,
        retryWindowExhausted: Bool,
        probeScheduled: Bool
    ) -> Bool {
        actionPending && retryWindowExhausted && !probeScheduled
    }
}

struct AlacrittySelectionRetryProbeState: Equatable {
    private(set) var scheduledGeneration: UInt64? = nil

    var isScheduled: Bool { scheduledGeneration != nil }

    @discardableResult
    mutating func schedule(generation: UInt64) -> Bool {
        guard scheduledGeneration == nil else { return false }
        scheduledGeneration = generation
        return true
    }

    @discardableResult
    mutating func begin(generation: UInt64) -> Bool {
        guard scheduledGeneration == generation else { return false }
        scheduledGeneration = nil
        return true
    }

    mutating func cancel() {
        scheduledGeneration = nil
    }
}

struct AlacrittySelectionAnchor: Equatable {
    let line: Int
    let column: Int
}

/// Keeps selection input ordered around a non-blocking bridge call.
struct AlacrittySelectionIntent: Equatable {
    private(set) var anchor: AlacrittySelectionAnchor?

    mutating func start(_ anchor: AlacrittySelectionAnchor, accepted: Bool) {
        guard accepted else {
            self.anchor = nil
            return
        }
        self.anchor = anchor
    }

    @discardableResult
    mutating func update(accepted: Bool) -> Bool {
        guard anchor != nil, accepted else { return false }
        return true
    }

    mutating func finish() {
        anchor = nil
    }
}

struct AlacrittySelectionEndpoint: Equatable {
    let line: Int
    let column: Int
    let rightHalf: Bool
}

struct AlacrittySelectionStartIntent: Equatable {
    let line: Int
    let column: Int
    let kind: UInt32
    let rightHalf: Bool
}

/// Coalesces non-blocking selection work until a bridge call is accepted.
/// A drag keeps only its latest endpoint, while copy/find/select-all retain
/// their operation until success, explicit supersession, or detach.
struct AlacrittySelectionRetryIntent: Equatable {
    static let maximumRetryAttempts = 8

    enum Action: Equatable {
        case selectAll
        case copySelection
        case findSelection
        case start(start: AlacrittySelectionStartIntent, endpoint: AlacrittySelectionEndpoint?)
        case update(AlacrittySelectionEndpoint)
    }

    private(set) var action: Action?
    private(set) var followUp: Action?
    private(set) var attempts = 0

    var isEmpty: Bool { action == nil }
    var retryWindowExhausted: Bool {
        !isEmpty && attempts >= Self.maximumRetryAttempts
    }
    var hasPendingStart: Bool {
        if case .start = action { return true }
        return false
    }
    var retryDelayMilliseconds: Int {
        1 << min(max(attempts - 1, 0), 6)
    }

    mutating func enqueue(_ action: Action) {
        let keepsSelection: Bool
        switch self.action {
        case .selectAll, .start, .update: keepsSelection = true
        default: keepsSelection = false
        }
        let isRead: Bool
        switch action {
        case .copySelection, .findSelection: isRead = true
        default: isRead = false
        }
        if keepsSelection, isRead {
            followUp = action
            attempts = 0
            return
        }
        self.action = action
        followUp = nil
        attempts = 0
    }

    mutating func enqueueStart(_ start: AlacrittySelectionStartIntent) {
        enqueue(.start(start: start, endpoint: nil))
    }

    mutating func enqueueUpdate(_ endpoint: AlacrittySelectionEndpoint) {
        switch action {
        case let .start(start, _):
            action = .start(start: start, endpoint: endpoint)
            attempts = 0
        case .update:
            action = .update(endpoint)
            attempts = 0
        default:
            enqueue(.update(endpoint))
        }
    }

    mutating func beginAttempt() -> Bool {
        guard action != nil, attempts < Self.maximumRetryAttempts else {
            return false
        }
        attempts += 1
        return true
    }

    /// Keep the pending action, but open a new finite retry window after an
    /// explicit user operation, presentation opportunity, or low-frequency
    /// probe. Ordinary output wakeups must not reopen the window while the
    /// worker remains busy.
    mutating func resetRetryWindow() {
        guard !isEmpty else { return }
        attempts = 0
    }

    mutating func acceptStart() {
        guard case let .start(_, endpoint) = action else { return }
        guard let endpoint else {
            acceptCurrent()
            return
        }
        action = .update(endpoint)
        attempts = 0
    }

    mutating func acceptCurrent() {
        guard let followUp else {
            complete()
            return
        }
        action = followUp
        self.followUp = nil
        attempts = 0
    }

    @discardableResult
    mutating func acceptUpdate() -> Bool {
        guard case .update = action else { return false }
        acceptCurrent()
        return true
    }

    mutating func complete() {
        action = nil
        followUp = nil
        attempts = 0
    }

    mutating func cancel() {
        complete()
    }

    /// Terminal input supersedes a selection gesture that has not reached the
    /// bridge yet. Keeping it alive would let a delayed retry recreate an old
    /// highlight after the worker has already cleared it for the new input.
    mutating func supersedeForTerminalInput() {
        cancel()
    }
}

struct AlacrittyCursorPosition: Equatable {
    let line: Int
    let column: Int
    let shape: UInt32
    let color: UInt32
}

struct AlacrittyCursorCache: Equatable {
    private(set) var position: AlacrittyCursorPosition?
    /// The live terminal insertion point can still be useful to the IME when
    /// the renderer hides its cursor (as full-screen TUIs often do). It is
    /// independent from `position`, whose sentinel means "do not draw".
    private(set) var imePosition: AlacrittyCursorPosition?

    mutating func update(
        line: Int,
        column: Int,
        imeLine: Int,
        imeColumn: Int,
        shape: UInt32,
        color: UInt32
    ) {
        position = Self.makePosition(
            line: line, column: column, shape: shape, color: color
        )
        imePosition = Self.makePosition(
            line: imeLine, column: imeColumn, shape: shape, color: color
        )
    }

    private static func makePosition(
        line: Int,
        column: Int,
        shape: UInt32,
        color: UInt32
    ) -> AlacrittyCursorPosition? {
        guard line >= 0, column >= 0 else { return nil }
        return AlacrittyCursorPosition(
            line: line, column: column, shape: shape, color: color
        )
    }
}

/// Controls whether an inactive surface keeps its drawable pool. Production
/// uses the memory-saving freeze path; ScrollBench opts in so presentation
/// timestamps remain observable while the benchmark window is unfocused.
struct AlacrittyPresentationPolicy: Equatable {
    let benchmarkMode: Bool

    func shouldKeepMetalLayerActive(
        surfaceVisible: Bool,
        appActive: Bool,
        windowIsKey: Bool
    ) -> Bool {
        guard surfaceVisible else { return false }
        return benchmarkMode || (appActive && windowIsKey)
    }

    var shouldFreezeOnApplicationResignActive: Bool { !benchmarkMode }
}

/// Kero's Alacritty backend: a `TerminalBackendSurface` rendered with Metal
/// from a CoreText glyph atlas on top of the `alacritty_terminal` crate.
///
/// The crate is emulation only — it has no renderer — so everything visible
/// here is Kero's: cell layout, glyph drawing, the cursor, selection, and the
/// key encodings in `AlacrittyKeyMap`. State lives in Rust behind the handle;
/// this view snapshots the visible grid each time it draws.
final class AlacrittyTerminalView: NSView, TerminalBackendSurface,
    TerminalSelectionAvailabilitySurface, NSUserInterfaceValidations {
    weak var events: (any TerminalBackendEvents)? {
        didSet { flushPendingEvents() }
    }
    var onBecomeFirstResponder: (() -> Void)?
    let splitTarget = SplitMenuTarget()

    /// Matches the window padding Kero's Ghostty panes use, so a pane looks
    /// the same whichever backend drew it.
    private static let padding = CGPoint(x: 10, y: 8)
    private static let scrollbackLines = 10_000

    private var handle: OpaquePointer?
    /// Creation waits for attachment and a plausible pane frame. Restored
    /// scrollback reflows into the initial grid, so starting at the old
    /// synthetic 800x600 frame could multiply history before Auto Layout had
    /// settled the real pane geometry.
    private var pendingLaunch: TerminalLaunch?
    private var backendStartScheduled = false
    /// Retained after detach so diagnostics can await a release that an
    /// earlier ordinary detach already started.
    private var backendReleaseTask: Task<Void, Never>?
    private var isDetached = false
    private let token = AlacrittyRegistry.shared.nextToken()
    private var metrics: AlacrittyMetrics
    private var gridSize = AlacrittyGridSize(columns: 0, rows: 0)
    private var markedText = ""
    private let markedTextField = NSTextField(labelWithString: "")
    private var isSurfaceVisible = false
    private var presentationPolicy = AlacrittyPresentationPolicy(benchmarkMode: false)
    /// Covers Metal while a parked surface is moving back into a real pane.
    /// The cover lives above the drawable so the GPU can acquire and present
    /// the first correctly-sized frame before the terminal becomes visible.
    private let presentationCoverLayer = CALayer()
    private var isAwaitingVisibleFrame = true
    private var presentationGeneration: UInt64 = 0
    private var lastPresentedSize: CGSize?
    private var lastPresentedScale: CGFloat?
    /// The last drawable's storage can be shown by an ordinary CALayer while
    /// Kero is inactive. Retaining one frame is much cheaper than keeping the
    /// CAMetalLayer and its full triple-sized drawable pool alive.
    private var lastPresentedSurface: IOSurface?
    private var pendingEvents: [(kind: UInt32, payload: Data)] = []
    private var trackingArea: NSTrackingArea?
    private var modifierMonitor: Any?
    private var isPointerInside = false
    private var isCommandPressed = false
    /// The pane's base pointer: iBeam until a program asks for another shape
    /// with OSC 22, matching the `.text` default of Kero's Ghostty panes.
    private var mouseShapeCursor: NSCursor = .iBeam
    private var reportingMouseButton = false
    private var lastReportedFocus: Bool?
    private var cursorTimer: Timer?
    private var cursorBlinking = false
    private var cursorVisible = true
    private let progressBar = KeroTerminalProgressBarView(frame: .zero)

    /// Fractional scroll accumulator, so a trackpad's sub-line deltas add up
    /// to a row instead of being discarded.
    private var scrollAccumulator: CGFloat = 0
    private var selectionIntent = AlacrittySelectionIntent()
    private var selectionRetryIntent = AlacrittySelectionRetryIntent()
    private var selectionRetryQueued = false
    private var selectionRetryGeneration: UInt64 = 0
    private var selectionRetryProbeGeneration: UInt64 = 0
    private var selectionRetryProbeState = AlacrittySelectionRetryProbeState()
    private var selectionRetryProbeWorkItem: DispatchWorkItem?
    private var selectionMouseDown = false
    private let findState = AlacrittyFind()
    private var hoveredURL: URLHit?

    private struct URLHit: Equatable {
        let value: String
        let startLine: Int
        let startColumn: Int
        let endLine: Int
        let endColumn: Int
    }

    /// Process metadata is a fallback until a shell reports OSC 7. It keeps
    /// ordinary local shells useful without integration; once OSC arrives it
    /// wins, since only the shell can report an SSH session's remote path.
    private var directoryTimer: Timer?
    private var lastReportedDirectory: String?
    private var usesOSCWorkingDirectory = false
    /// One queued `reportWorkingDirectory()` catch-up, coalesced per run-loop
    /// turn. See `updateDirectoryPolling`.
    private var directoryReportQueued = false

    /// Shared across every pane: one device and one shader library is enough,
    /// and a per-pane device would duplicate the glyph atlas too.
    private static let sharedDevice = MTLCreateSystemDefaultDevice()
    private let metalDevice = AlacrittyTerminalView.sharedDevice
    private var renderScheduled = false
    /// Coalesces PTY wakeups onto the display link instead of drawing from
    /// each run-loop turn. ProMotion stays at 120 Hz only while this range is
    /// requested.
    private(set) var displayLink: CADisplayLink?
    private var displayLinkProxy: AlacrittyDisplayLinkProxy?
    private var framePending = false
    private var frameBusyRetryScheduled = false
    private var frameBusyRetriesRemaining = 0
    /// A drawable or Metal submission can fail after the bridge has consumed
    /// its frame. Pause the display link in that case, then use a small,
    /// bounded backoff so a quiet terminal can recover without spinning at
    /// 120 Hz forever.
    private var presentationRecoveryScheduled = false
    private var presentationRecoveryAttempts = 0
    private var presentationRecoveryGeneration: UInt64 = 0
    private var presentationRecoveryProbeScheduled = false
    private var presentationRecoveryProbeWorkItem: DispatchWorkItem?
    /// Scroll and redraw work accumulated until the next frame. The intent is
    /// consumed only after the bridge accepts the frame; BUSY restores it.
    private var pendingFrameIntent = AlacrittyFrameIntent()
    /// Last geometry reported from a rendered snapshot. Scrollbar drags use
    /// this cached position instead of taking a second full snapshot.
    private var lastScrollPosition: TerminalScrollPosition?
    /// A drag can arrive before the first frame has reported geometry. Keep
    /// that fraction until the first accepted snapshot supplies row counts.
    private var pendingScrollFraction: Double?
    /// Cursor geometry from the last accepted frame. IME placement must not
    /// acquire the terminal lock while asking for this position.
    private var cursorCache = AlacrittyCursorCache()
#if DEBUG
    /// Test-only seam for exercising NSTextInputClient geometry without
    /// starting a PTY or waiting for a render frame.
    func setCursorCacheForTesting(_ cache: AlacrittyCursorCache) {
        cursorCache = cache
    }

    /// Copies IME and render cursor fields the same way an accepted frame does,
    /// then refreshes the underlined preedit overlay from that snapshot.
    func acceptSnapshotForTesting(_ snapshot: KeroSnapshot) {
        acceptCursor(from: snapshot)
        updateMarkedTextOverlay(snapshot: snapshot)
    }

    func cursorCacheForTesting() -> AlacrittyCursorCache { cursorCache }

    func setMarkedTextForTesting(_ text: String) {
        markedText = text
    }

    var markedTextOverlayFrameForTesting: NSRect? {
        markedTextField.isHidden ? nil : markedTextField.frame
    }
#endif
    /// Host-side cursor blink: reuse cached rows and only rebuild the cursor.
    private var needsCursorRedraw = false
    /// Forces the next frame regardless of emulator damage. Set for changes
    /// the emulator knows nothing about — a resize, a new theme or font,
    /// focus — since those move pixels without touching a cell.
    private var needsUnconditionalRedraw = true
    private var metalRenderer: TerminalMetalRenderer?
    private var kittyPlacements: [AlacrittyKittyPlacement] = []
    private var kittyImageData: [AlacrittyKittyImageKey: Data] = [:]

    override init(frame frameRect: NSRect) {
        metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize),
            fontThicken: AppSettings.shared.fontThicken
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
        markedTextField.isHidden = true
        markedTextField.isBezeled = false
        markedTextField.drawsBackground = true
        markedTextField.lineBreakMode = .byClipping
        addSubview(markedTextField)
        addSubview(progressBar)
        AlacrittyRegistry.shared.register(self, for: token)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive(_:)),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(effectiveFocusChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init(launch: TerminalLaunch) {
        self.init(frame: .zero)
        pendingLaunch = launch
    }

    isolated deinit {
        isDetached = true
        stopDisplayLink()
        directoryTimer?.invalidate()
        cursorTimer?.invalidate()
        findState.cancel()
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
        }
        NotificationCenter.default.removeObserver(self)
        AlacrittyRegistry.shared.unregister(token)
        if let handle { _ = AlacrittyHandleRelease.schedule(handle: handle) }
    }

    // MARK: - Lifecycle

    private func start(launch: TerminalLaunch, size: AlacrittyGridSize) {
        gridSize = size
        var theme = AlacrittyTheme.current()

        handle = launch.withCConfig(
            columns: UInt16(size.columns),
            rows: UInt16(size.rows),
            cellWidth: UInt16(metrics.cellWidth.rounded()),
            cellHeight: UInt16(metrics.cellHeight.rounded()),
            scrollbackLines: Self.scrollbackLines,
            cursorShape: AppSettings.shared.cursorShape.alacrittyValue,
            cursorBlinking: AppSettings.shared.cursorBlinking
        ) { config in
            withUnsafePointer(to: &theme) { themePointer in
                kero_alacritty_new(
                    config,
                    themePointer,
                    alacrittyEventCallback,
                    UnsafeMutableRawPointer(bitPattern: UInt(token))
                )
            }
        }

        if handle == nil {
            NSLog("yeet: failed to start the Alacritty backend for \(launch.program)")
            return
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        scheduleBackendStart()
    }

    private func scheduleBackendStart() {
        guard pendingLaunch != nil, !backendStartScheduled, !isDetached else { return }
        backendStartScheduled = true
        afterViewUpdate { [weak self] in
            guard let self else { return }
            self.backendStartScheduled = false
            self.startBackendIfReady()
        }
    }

    private func startBackendIfReady() {
        guard !isDetached,
              handle == nil,
              let launch = pendingLaunch,
              let size = gridSize(for: bounds.size),
              size.isStableForBackend
        else {
            return
        }
        pendingLaunch = nil
        start(launch: launch, size: size)
        // The host can become visible in the layout pass that assigned this
        // first stable frame. If so, it already attempted a frame before the
        // backend existed; retry now that the emulator can produce one.
        if handle != nil, isSurfaceVisible {
            updateBackingLayerActivity(forceFrame: true)
            updateActiveTimers()
            updateFocusReport()
        }
    }

    /// Directory polling and cursor blinking are useful only for the pane the
    /// user can currently interact with. Leaving them running for parked tabs
    /// or while another app is active prevents the terminal heap and Metal
    /// drawable pages from becoming cold enough for macOS to reclaim.
    private func updateActiveTimers() {
        guard !isDetached else { return }
        updateDirectoryPolling()
        updateCursorTimer()
    }

    private var shouldKeepMetalLayerActive: Bool {
        presentationPolicy.shouldKeepMetalLayerActive(
            surfaceVisible: isSurfaceVisible,
            appActive: NSApp.isActive,
            windowIsKey: window?.isKeyWindow == true
        )
    }

    private func updateBackingLayerActivity(forceFrame: Bool = false) {
        guard !isDetached else { return }
        if shouldKeepMetalLayerActive {
            let needsMetalLayer = !(layer is CAMetalLayer)
            guard needsMetalLayer || forceFrame else { return }
            // Re-attaching the drawable, regaining focus, or explicitly
            // refreshing the visible layer is a real presentation opportunity.
            // It may start a fresh bounded recovery sequence after a previous
            // drawable failure exhausted its budget.
            resetPresentationRecovery()
            resetSelectionRetryWindow()
            if needsMetalLayer {
                lastPresentedSurface = nil
                replaceBackingLayer(with: makeBackingLayer())
            }
            isAwaitingVisibleFrame = true
            setPresentationCoverVisible(true)
            needsUnconditionalRedraw = true
            if !renderFrame(waitUntilCompleted: true),
               !presentationRecoveryScheduled {
                scheduleRender(force: true)
            }
        } else {
            freezeVisibleFrame()
        }
    }

    /// Keep the last submitted terminal image visible behind other apps and
    /// Kero windows, but release the CAMetalLayer drawable pool and renderer.
    /// A CAMetal drawable is IOSurface-backed, and CALayer can display that
    /// same surface directly without copying it through the CPU.
    private func freezeVisibleFrame(cursorHasFocus: Bool? = nil) {
        guard isSurfaceVisible, layer is CAMetalLayer else { return }
        let cursorWasVisible = !cursorBlinking || cursorVisible
        // The last active frame may be the hidden half of a cursor blink.
        // Present the steady inactive cursor before retaining that drawable.
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true
        stopDisplayLink()
        needsUnconditionalRedraw = true
        let renderedInactive = renderFrame(
            waitUntilCompleted: true,
            cursorHasFocus: cursorHasFocus
        )
        // A synchronous inactive refresh may have queued a retry while the
        // layer was still Metal. Do not carry that probe into the parked
        // CALayer state; visibility/focus will provide the next opportunity.
        cancelSelectionRetryProbe()
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true

        presentationCoverLayer.removeFromSuperlayer()
        let frozenLayer = CALayer()
        frozenLayer.isOpaque = true
        frozenLayer.backgroundColor = Theme.background.cgColor
        frozenLayer.contents = lastPresentedSurface
        frozenLayer.contentsScale = lastPresentedScale
            ?? window?.backingScaleFactor
            ?? 2
        frozenLayer.contentsGravity = .topLeft
        frozenLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if !renderedInactive, !cursorWasVisible {
            addInactiveCursorOverlay(to: frozenLayer)
        }
        metalRenderer = nil
        replaceBackingLayer(with: frozenLayer)
    }

    /// Re-renders the retained image while Kero or its terminal window is not
    /// focused. A normal scheduled frame cannot update this state because the
    /// inactive terminal is backed by a plain `CALayer`, not a `CAMetalLayer`.
    ///
    /// The Metal layer exists only long enough to produce the new retained
    /// frame, so a background script can remain visibly live without restoring
    /// the idle drawable pool between output events.
    private func refreshFrozenFrame() {
        guard isSurfaceVisible, !(layer is CAMetalLayer) else {
            scheduleRender(force: true)
            return
        }
        replaceBackingLayer(with: makeBackingLayer())
        freezeVisibleFrame(cursorHasFocus: false)
    }

    /// AppKit can revoke CAMetalLayer drawables before focus-loss callbacks
    /// finish. If the retained frame caught the hidden blink phase, draw the
    /// steady cursor as ordinary layers over that frozen IOSurface.
    private func addInactiveCursorOverlay(to frozenLayer: CALayer) {
        guard let cursor = cursorCache.position,
              cursor.line >= 0,
              cursor.column >= 0
        else { return }

        let cell = CGRect(
            x: Self.padding.x + CGFloat(cursor.column) * metrics.cellWidth,
            y: bounds.maxY - Self.padding.y
                - CGFloat(cursor.line + 1) * metrics.cellHeight,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
        let frames: [CGRect] = switch cursor.shape {
        case 1:
            [CGRect(x: 0, y: 0, width: cell.width, height: 2)]
        case 2:
            [CGRect(x: 0, y: 0, width: 2, height: cell.height)]
        default:
            [
                CGRect(x: 0, y: 0, width: cell.width, height: 1),
                CGRect(x: 0, y: cell.height - 1, width: cell.width, height: 1),
                CGRect(x: 0, y: 0, width: 1, height: cell.height),
                CGRect(x: cell.width - 1, y: 0, width: 1, height: cell.height),
            ]
        }

        let overlay = CALayer()
        overlay.frame = cell
        overlay.contentsScale = frozenLayer.contentsScale
        let color = AlacrittyRenderer.color(cursor.color)
        for frame in frames {
            let segment = CALayer()
            segment.frame = frame
            segment.backgroundColor = color
            segment.contentsScale = frozenLayer.contentsScale
            overlay.addSublayer(segment)
        }
        frozenLayer.addSublayer(overlay)
    }

    private func updateDirectoryPolling() {
        let shouldPoll =
            !usesOSCWorkingDirectory
            && isSurfaceVisible && NSApp.isActive && window?.isKeyWindow == true
        guard shouldPoll else {
            directoryTimer?.invalidate()
            directoryTimer = nil
            return
        }
        // A parked or inactive pane may have changed directories since its
        // last poll. Catch it up before waiting for the first timer tick.
        // Deferred: `updateActiveTimers` also runs from `layout()` and
        // `becomeFirstResponder` inside a SwiftUI pass, and a synchronous
        // report would publish `workingDirectory` during that update
        // ("Publishing changes from within view updates").
        scheduleDirectoryReport()
        guard directoryTimer == nil else { return }
        directoryTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportWorkingDirectory() }
        }
    }

    private func scheduleDirectoryReport() {
        guard !directoryReportQueued else { return }
        directoryReportQueued = true
        afterViewUpdate { [weak self] in
            guard let self else { return }
            self.directoryReportQueued = false
            self.reportWorkingDirectory()
        }
    }

    private func reportWorkingDirectory() {
        guard !usesOSCWorkingDirectory, let handle else { return }
        // The foreground job's directory, falling back to the shell's — a
        // long-running command should not blank the label.
        let pid = kero_alacritty_foreground_pid(handle)
        guard let path = processWorkingDirectory(pid: pid)
            ?? processWorkingDirectory(pid: kero_alacritty_child_pid(handle))
        else { return }
        guard path != lastReportedDirectory else { return }
        lastReportedDirectory = path
        events?.terminalDidChangeWorkingDirectory(path)
    }

    func detach() {
        _ = detachBackend()
    }

    /// Used by diagnostics that must validate the complete worker teardown
    /// before releasing the window. Ordinary pane removal uses `detach()` and
    /// lets the join continue on the utility executor.
    func detachAndWaitForBackend() async {
        guard let release = detachBackend() else { return }
        await release.value
    }

    @discardableResult
    private func detachBackend() -> Task<Void, Never>? {
        guard !isDetached else { return backendReleaseTask }
        isDetached = true
        isSurfaceVisible = false
        presentationGeneration &+= 1
        directoryTimer?.invalidate()
        directoryTimer = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        isPointerInside = false
        isCommandPressed = false
        selectionMouseDown = false
        selectionIntent.finish()
        cancelSelectionRetry()
        findState.cancel()
        stopModifierMonitor()
        updateHoveredURL(nil)
        stopDisplayLink()
        metalRenderer = nil
        AlacrittyRegistry.shared.unregister(token)
        guard let handle else { return nil }
        self.handle = nil
        let release = AlacrittyHandleRelease.schedule(handle: handle)
        backendReleaseTask = release
        return release
    }

    func setSurfaceVisible(_ visible: Bool) {
        guard !isDetached else { return }
        // The flag stops wakeups from scheduling frames nothing will
        // composite; parking also drops renderer-owned GPU allocations below.
        let changed = visible != isSurfaceVisible
        guard changed else {
            if visible { updateFocusReport() }
            return
        }
        isSurfaceVisible = visible
        presentationGeneration &+= 1
        if visible {
            updateBackingLayerActivity(forceFrame: true)
            updateActiveTimers()
            updateFocusReport()
        } else {
            isPointerInside = false
            stopModifierMonitor()
            updateHoveredURL(nil)
            stopDisplayLink()
            // Drop the glyph atlas and row/instance buffers while parked,
            // matching Ghostty's occluded-surface GPU memory behavior.
            metalRenderer = nil
            // CAMetalLayer retains its current display drawable even after
            // `device` becomes nil. Replace the layer entirely so Core
            // Animation releases that drawable and its pool. A 1800×1600
            // BGRA drawable is ~11.5 MiB, so one per parked tab dominates
            // multi-tab memory.
            presentationCoverLayer.removeFromSuperlayer()
            let parkedLayer = CALayer()
            parkedLayer.isOpaque = true
            parkedLayer.backgroundColor = Theme.background.cgColor
            parkedLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            replaceBackingLayer(with: parkedLayer)
            lastPresentedSize = nil
            lastPresentedScale = nil
            lastPresentedSurface = nil
            isAwaitingVisibleFrame = true
            cursorTimer?.invalidate()
            cursorTimer = nil
            cursorBlinking = false
            cursorVisible = true
            directoryTimer?.invalidate()
            directoryTimer = nil
        }
    }

    /// Enables the benchmark-only presentation path. The benchmark keeps a
    /// visible CAMetalLayer attached while the app or window is unfocused so
    /// Core Animation can report actual presentation timestamps. Production
    /// callers leave this disabled and retain the inactive-frame freeze path.
    func setBenchmarkPresentationMode(_ enabled: Bool) {
        guard enabled != presentationPolicy.benchmarkMode else { return }
        presentationPolicy = AlacrittyPresentationPolicy(benchmarkMode: enabled)
        updateBackingLayerActivity(forceFrame: enabled)
        updateActiveTimers()
    }

    func applyAppearance() {
        metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize),
            fontThicken: AppSettings.shared.fontThicken
        )
        presentationCoverLayer.backgroundColor = Theme.background.cgColor
        var theme = AlacrittyTheme.current()
        if let handle {
            withUnsafePointer(to: &theme) { kero_alacritty_set_theme(handle, $0) }
            kero_alacritty_set_cursor_style(
                handle,
                AppSettings.shared.cursorShape.alacrittyValue,
                AppSettings.shared.cursorBlinking
            )
        }
        // A new cell size means a different column count.
        synchronizeGridSize()
        refreshFrozenFrame()
    }

    var foregroundPid: pid_t? {
        guard let handle else { return nil }
        let pid = kero_alacritty_foreground_pid(handle)
        return pid > 0 ? pid : nil
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        let height: CGFloat = 2
        progressBar.frame = CGRect(
            x: 0, y: bounds.height - height,
            width: bounds.width, height: height
        )
    }

    private func gridSize(for size: CGSize) -> AlacrittyGridSize? {
        guard let displaySize = maximumDisplaySize(),
              AlacrittyGridSize.isPlausibleViewport(size, within: displaySize)
        else {
            return nil
        }

        return AlacrittyGridSize.from(
            viewportSize: size,
            cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
            padding: Self.padding
        )
    }

    private func maximumDisplaySize() -> CGSize? {
        var screens = NSScreen.screens
        if let windowScreen = window?.screen {
            screens.append(windowScreen)
        }
        let visibleSizes = screens.map(\.visibleFrame.size).filter {
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
        guard let first = visibleSizes.first else { return nil }
        return visibleSizes.dropFirst().reduce(first) { largest, size in
            CGSize(width: max(largest.width, size.width), height: max(largest.height, size.height))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        if changed, isSurfaceVisible, isAwaitingVisibleFrame {
            // Invalidate a startup-sized frame that completed while Auto
            // Layout was still moving this surface out of parking.
            presentationGeneration &+= 1
            setPresentationCoverVisible(true)
        }
        super.setFrameSize(newSize)
        startBackendIfReady()
        synchronizeGridSize()
        // Padding remainder changes even when the number of rows/columns does
        // not, so a sub-cell resize still needs one host-side frame.
        if changed { schedulePresentationOpportunity(force: true) }
    }

    /// Pushes the current geometry down to the emulator, which resizes the
    /// grid and sends SIGWINCH. No-op when nothing changed, so a layout pass
    /// does not disturb a running TUI.
    private func synchronizeGridSize() {
        guard let handle else { return }
        guard let size = gridSize(for: bounds.size), size.isStableForBackend else { return }
        guard size != gridSize else { return }
        gridSize = size
        kero_alacritty_resize(
            handle,
            UInt16(size.columns), UInt16(size.rows),
            UInt16(metrics.cellWidth.rounded()), UInt16(metrics.cellHeight.rounded())
        )
        schedulePresentationOpportunity(force: true)
    }

    override var isFlipped: Bool { false }

    override var isOpaque: Bool { true }

    // MARK: - Drawing

    /// Metal draws into a `CAMetalLayer` rather than the view's context, so
    /// this view has no `draw(_:)`. `needsDisplay` still drives redraws —
    /// AppKit coalesces it per run-loop turn, which is exactly the batching a
    /// burst of PTY output wants.
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = metalDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Two drawables stall `nextDrawable()` when the GPU is still showing
        // the previous frame. A third pane-sized IOSurface (~15 MiB on a
        // large Retina window) absorbs that wait so 120 Hz stays possible.
        layer.maximumDrawableCount = 3
        // Core Animation's default `.resize` gravity can stretch a startup-
        // sized drawable across the real pane for a few frames on first
        // attachment, making restored text flash at a much larger size. Keep
        // any previous drawable pixel-accurate while the correct frame arrives.
        layer.contentsGravity = .topLeft
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.needsDisplayOnBoundsChange = true
        presentationCoverLayer.backgroundColor = Theme.background.cgColor
        presentationCoverLayer.frame = layer.bounds
        presentationCoverLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        presentationCoverLayer.isHidden = false
        layer.addSublayer(presentationCoverLayer)
        return layer
    }

    private func replaceBackingLayer(with newLayer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newLayer.frame = bounds
        layer = newLayer
        CATransaction.commit()
    }

    /// Coalesces a burst of PTY wakeups onto the next display-link tick.
    /// Frozen (non-Metal) surfaces still use one run-loop turn, matching the
    /// old CoreText `needsDisplay` batching.
    private func scheduleRender(force: Bool = false) {
        guard !isDetached else { return }
        if force { needsUnconditionalRedraw = true }
        guard isSurfaceVisible else { return }
        if !(layer is CAMetalLayer) {
            guard !renderScheduled else { return }
            renderScheduled = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                let terminalView = self
                assumeMainActor {
                    guard let terminalView else { return }
                    terminalView.renderScheduled = false
                    terminalView.refreshFrozenFrame()
                }
            }
            return
        }
        framePending = true
        if let handle { kero_alacritty_request_frame(handle) }
        let selectionRetryWaiting =
            !selectionRetryIntent.isEmpty
            && (selectionRetryQueued || selectionRetryIntent.retryWindowExhausted)
        let hasOtherPendingWork =
            !pendingFrameIntent.isEmpty
            || needsUnconditionalRedraw
            || needsCursorRedraw
        guard AlacrittySelectionRetryPolicy.shouldWakeDisplayLink(
            retryWaiting: selectionRetryWaiting,
            hasOtherPendingWork: hasOtherPendingWork
        ) else {
            framePending = false
            if let handle { kero_alacritty_cancel_frame_request(handle) }
            return
        }
        // PTY, cursor, selection, and scroll damage only merge into the
        // pending intent. A failed drawable owns the wakeup budget until its
        // timer fires or a real presentation opportunity resets it.
        guard AlacrittyFrameRetryPolicy.shouldWakeDisplayLinkForDamage(
            recoveryScheduled: presentationRecoveryScheduled,
            recoveryAttempts: presentationRecoveryAttempts
        ) else { return }
        startDisplayLinkIfNeeded()
        guard displayLink != nil else {
            framePending = false
            if let handle { kero_alacritty_cancel_frame_request(handle) }
            return
        }
        displayLink?.isPaused = false
    }

    /// Resets the bounded failure budget for a real presentation opportunity,
    /// such as visibility, backing, geometry, or focus becoming valid again.
    /// Ordinary PTY damage uses `scheduleRender` and must not call this path.
    private func schedulePresentationOpportunity(force: Bool = false) {
        guard !isDetached else { return }
        resetPresentationRecovery()
        resetSelectionRetryWindow()
        scheduleRender(force: force)
    }

    private func startDisplayLinkIfNeeded() {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard displayLink == nil, let screen else { return }
        let proxy = AlacrittyDisplayLinkProxy(view: self)
        let link = screen.displayLink(
            target: proxy,
            selector: #selector(AlacrittyDisplayLinkProxy.tick(_:))
        )
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80, maximum: 120, preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
    }

    private func stopDisplayLink() {
        resetPresentationRecovery()
        cancelSelectionRetryProbe()
        if let handle { kero_alacritty_cancel_frame_request(handle) }
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        framePending = false
    }

    fileprivate func displayLinkDidFire() {
        guard isSurfaceVisible, layer is CAMetalLayer else {
            stopDisplayLink()
            return
        }
        guard framePending || needsUnconditionalRedraw || needsCursorRedraw else {
            if let handle { kero_alacritty_cancel_frame_request(handle) }
            displayLink?.isPaused = true
            return
        }
        if !frameBusyRetryScheduled {
            frameBusyRetriesRemaining = 2
        }
        framePending = false
        let rendered = renderFrame(retryBusyImmediately: true)
        let selectionRetryWaiting =
            !selectionRetryIntent.isEmpty
            && (selectionRetryQueued || selectionRetryIntent.retryWindowExhausted)
        let hasOtherPendingWork =
            !pendingFrameIntent.isEmpty
            || needsUnconditionalRedraw
            || needsCursorRedraw
        if AlacrittyFrameRetryPolicy.shouldPauseDisplayLink(
            renderSucceeded: rendered
        ) || AlacrittyFrameRetryPolicy.shouldPauseDisplayLinkForSelectionRetry(
            renderSucceeded: rendered,
            retryWaiting: selectionRetryWaiting,
            hasOtherPendingWork: hasOtherPendingWork
        ) {
            displayLink?.isPaused = true
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A move between displays changes the backing scale, which invalidates
        // every rasterized glyph.
        guard let scale = window?.backingScaleFactor else { return }
        (self.layer as? CAMetalLayer)?.contentsScale = scale
        schedulePresentationOpportunity(force: true)
    }

    @discardableResult
    private func renderFrame(
        waitUntilCompleted: Bool = false,
        cursorHasFocus: Bool? = nil,
        retryBusyImmediately: Bool = false
    ) -> Bool {
        guard !isDetached else { return false }
        guard let handle else { return false }
        guard let metalLayer = layer as? CAMetalLayer else {
            kero_alacritty_cancel_frame_request(handle)
            return false
        }
        // Full-screen TUIs use DEC mode 2026 to replace a frame atomically.
        // A host cursor tick must not expose the cleared intermediate grid.
        if !waitUntilCompleted, kero_alacritty_synchronized_update(handle) {
            kero_alacritty_cancel_frame_request(handle)
            framePending = true
            displayLink?.isPaused = false
            return true
        }
        revalidateURLHoverForRender()
        if metalRenderer == nil, let metalDevice {
            metalRenderer = TerminalMetalRenderer(device: metalDevice)
        }
        guard let renderer = metalRenderer else {
            kero_alacritty_cancel_frame_request(handle)
            NSLog("yeet: no Metal device; the Alacritty backend cannot draw")
            return false
        }

        // The bridge applies this request, damage, the grid snapshot, and the
        // Kitty placements in one locked region. The scroll path only
        // accumulates deltas; it does not acquire the terminal mutex once per
        // input event. A wakeup also only means bytes arrived: a heartbeat or
        // cursor query can report SKIP.
        let renderStart = CFAbsoluteTimeGetCurrent()
        defer {
            AlacrittyRenderStats.shared.frame(
                seconds: CFAbsoluteTimeGetCurrent() - renderStart
            )
        }
        let selectionChanged = retrySelectionWork()
        if selectionChanged {
            pendingFrameIntent.request(forceFull: true)
        }
        let selectionRetryWaiting =
            !selectionRetryIntent.isEmpty
            && (selectionRetryQueued || selectionRetryIntent.retryWindowExhausted)
        let hasOtherPendingWork =
            !pendingFrameIntent.isEmpty
            || needsUnconditionalRedraw
            || needsCursorRedraw
        if !waitUntilCompleted, selectionRetryWaiting, !hasOtherPendingWork {
            // A selection-only BUSY result is parked until its bounded timer
            // or a real wake. Do not call begin_frame on every display tick.
            kero_alacritty_cancel_frame_request(handle)
            return true
        }
        if !waitUntilCompleted,
           selectionRetryIntent.isEmpty,
           !hasOtherPendingWork {
            kero_alacritty_cancel_frame_request(handle)
            completePresentationRecovery()
            return true
        }
        var frameIntent = pendingFrameIntent.take()
        frameIntent.request(
            forceFull: needsUnconditionalRedraw,
            cursorOnly: needsCursorRedraw
        )
        var frame = KeroFrame()
        kero_alacritty_begin_frame(
            handle,
            frameIntent.scrollDeltaArgument,
            frameIntent.scrollTargetArgument,
            frameIntent.forceFull,
            frameIntent.cursorOnly,
            &frame
        )
        AlacrittyRenderStats.shared.recordBridgeFrame(
            busy: frame.kind == KERO_FRAME_BUSY,
            busyCount: frame.busy_count,
            lockWaitNs: frame.lock_wait_ns,
            snapshotNs: frame.snapshot_ns,
            buildNs: frame.build_ns,
            packedRows: UInt64(frame.packed_rows)
        )
        // Restore the full request on BUSY before an immediate or display-link
        // retry merges any newer input.
        if frame.kind == KERO_FRAME_BUSY {
            pendingFrameIntent.restore(frameIntent)
            framePending = true
            if displayLink == nil {
                scheduleRender()
            } else {
                displayLink?.isPaused = false
            }
            if retryBusyImmediately {
                scheduleBusyFrameRetry()
            }
            return true
        }
        // nil means "rebuild every row": a full-damage frame, or a host-side
        // change — resize, theme, selection, focus — that the emulator never
        // saw and so never reported as damage.
        var dirtyRows: [Int]?
        switch frame.kind {
        case KERO_FRAME_FULL:
            dirtyRows = nil
        case KERO_FRAME_DIRTY:
            dirtyRows = (0..<frame.dirty_rows_len).map { Int(frame.dirty_rows[$0]) }
        case KERO_FRAME_CURSOR:
            // Empty means reuse every cached row and only rebuild the cursor.
            dirtyRows = []
        default:
            needsUnconditionalRedraw = false
            needsCursorRedraw = false
            AlacrittyRenderStats.shared.skipped()
            completePresentationRecovery()
            return true
        }
        acceptCursor(from: frame.snapshot)
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.device = metalDevice
        metalLayer.contentsScale = scale
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            recoverAfterAcceptedFrameFailure()
            return false
        }
        metalLayer.drawableSize = CGSize(
            width: size.width * scale, height: size.height * scale
        )
        guard let drawable = metalLayer.nextDrawable() else {
            recoverAfterAcceptedFrameFailure()
            return false
        }
        // Keep the IOSurface before render schedules this drawable for
        // presentation. Accessing drawable.texture afterward is invalid.
        let drawableSurface = drawable.texture.iosurface

        var snapshot = frame.snapshot
        applyHoveredURLUnderline(to: &snapshot)
        updateKittyGraphics(snapshot: frame.kitty)
        updateMarkedTextOverlay(snapshot: snapshot)
        updateCursorBlinking(snapshot.cursor_blinking)
        if cursorBlinking, !cursorVisible {
            snapshot.cursor_line = -1
            snapshot.cursor_column = -1
        } else if !(cursorHasFocus ?? hasEffectiveTerminalFocus),
            snapshot.cursor_shape == 0
        {
            snapshot.cursor_shape = 3
        }
        let generation = presentationGeneration
        let presentationToken = token
        let tracksPresentedGeometry =
            !waitUntilCompleted
            && (isAwaitingVisibleFrame
                || lastPresentedSize != size
                || lastPresentedScale != scale)
        let onPresented: (@Sendable () -> Void)?
        if tracksPresentedGeometry {
            onPresented = {
                DispatchQueue.main.async {
                    AlacrittyRegistry.shared.view(for: presentationToken)?.didPresentFrame(
                        generation: generation,
                        size: size,
                        scale: scale
                    )
                }
            }
        } else {
            onPresented = nil
        }
        let submitted = renderer.render(
            snapshot: snapshot,
            kittyPlacements: kittyPlacements,
            metrics: metrics,
            padding: Self.padding,
            scale: scale,
            dirtyRows: dirtyRows,
            in: drawable,
            viewportSize: size,
            onPresented: onPresented,
            waitUntilCompleted: waitUntilCompleted
        )
        if submitted {
            needsUnconditionalRedraw = false
            needsCursorRedraw = false
            lastPresentedSurface = drawableSurface
            completePresentationRecovery()
        } else {
            recoverAfterAcceptedFrameFailure()
        }
        if submitted, waitUntilCompleted {
            lastPresentedSize = size
            lastPresentedScale = scale
            isAwaitingVisibleFrame = false
            setPresentationCoverVisible(false)
        }
        if submitted {
            reportScroll(
                totalLines: snapshot.total_lines,
                screenLines: snapshot.screen_lines,
                displayOffset: snapshot.display_offset
            )
        }
        return submitted
    }

    private func recoverAfterAcceptedFrameFailure() {
        pendingFrameIntent.recoverAfterAcceptedFrameFailure()
        framePending = true
        schedulePresentationRecovery()
    }

    private func resetPresentationRecovery() {
        presentationRecoveryGeneration &+= 1
        presentationRecoveryScheduled = false
        presentationRecoveryAttempts = 0
        presentationRecoveryProbeWorkItem?.cancel()
        presentationRecoveryProbeWorkItem = nil
        presentationRecoveryProbeScheduled = false
    }

    private func completePresentationRecovery() {
        resetPresentationRecovery()
    }

    /// Wakes a paused display link a finite number of times after a drawable
    /// or Metal submission failure. The bridge frame was accepted already, so
    /// the retained full-redraw intent is safe to retry; the backoff keeps a
    /// quiet pane from polling the display link at 120 Hz indefinitely.
    private func schedulePresentationRecovery() {
        guard !isDetached,
              isSurfaceVisible,
              layer is CAMetalLayer,
              framePending
        else { return }

        guard AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecovery(
            framePending: framePending,
            recoveryScheduled: presentationRecoveryScheduled,
            attempts: presentationRecoveryAttempts
        ) else {
            schedulePresentationRecoveryProbe()
            return
        }

        let attempt = presentationRecoveryAttempts
        presentationRecoveryAttempts += 1
        presentationRecoveryScheduled = true
        let generation = presentationRecoveryGeneration
        let delay = AlacrittyFrameRetryPolicy
            .presentationRecoveryDelayMilliseconds(for: attempt)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(delay)
        ) { [weak self] in
            guard let self,
                  self.presentationRecoveryGeneration == generation,
                  self.presentationRecoveryScheduled
            else { return }
            self.presentationRecoveryScheduled = false
            guard !self.isDetached,
                  self.isSurfaceVisible,
                  self.layer is CAMetalLayer,
                  self.framePending
            else { return }
            if let handle = self.handle {
                kero_alacritty_request_frame(handle)
            }
            self.startDisplayLinkIfNeeded()
            self.displayLink?.isPaused = false
        }
    }

    /// Once the fast recovery budget is exhausted, keep a quiet terminal
    /// live with one cancellable probe per second. Ordinary damage still only
    /// merges intent; it cannot turn this probe into a 120 Hz display loop.
    private func schedulePresentationRecoveryProbe() {
        guard AlacrittyFrameRetryPolicy.shouldSchedulePresentationRecoveryProbe(
            framePending: framePending,
            probeScheduled: presentationRecoveryProbeScheduled,
            attempts: presentationRecoveryAttempts
        ) else { return }

        presentationRecoveryProbeScheduled = true
        let generation = presentationRecoveryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.presentationRecoveryGeneration == generation,
                  self.presentationRecoveryProbeScheduled
            else { return }
            self.presentationRecoveryProbeScheduled = false
            self.presentationRecoveryProbeWorkItem = nil
            guard !self.isDetached,
                  self.isSurfaceVisible,
                  self.layer is CAMetalLayer,
                  self.framePending
            else { return }
            if let handle = self.handle {
                kero_alacritty_request_frame(handle)
            }
            self.startDisplayLinkIfNeeded()
            guard self.displayLink != nil else {
                self.schedulePresentationRecoveryProbe()
                return
            }
            self.displayLink?.isPaused = false
        }
        presentationRecoveryProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + .milliseconds(AlacrittyFrameRetryPolicy
                    .presentationRecoveryProbeDelayMilliseconds),
            execute: workItem
        )
    }

    /// Retries a failed non-blocking bridge lock at most twice before the next
    /// display tick. Sustained contention then falls back to display-link
    /// pacing instead of spinning on the main thread.
    private func scheduleBusyFrameRetry() {
        guard AlacrittyFrameRetryPolicy.shouldScheduleBusyRetry(
            framePending: framePending,
            retryScheduled: frameBusyRetryScheduled,
            retriesRemaining: frameBusyRetriesRemaining
        ) else { return }
        frameBusyRetriesRemaining -= 1
        frameBusyRetryScheduled = true
        // Let the PTY finish the critical section that made the first
        // non-blocking attempt busy, while staying well inside one 120 Hz
        // display interval.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .microseconds(500)
        ) { [weak self] in
            guard let self else { return }
            frameBusyRetryScheduled = false
            guard displayLink != nil,
                  isSurfaceVisible,
                  layer is CAMetalLayer,
                  framePending
            else { return }
            framePending = false
            let rendered = renderFrame(retryBusyImmediately: true)
            let selectionRetryWaiting =
                !selectionRetryIntent.isEmpty
                && (selectionRetryQueued || selectionRetryIntent.retryWindowExhausted)
            let hasOtherPendingWork =
                !pendingFrameIntent.isEmpty
                || needsUnconditionalRedraw
                || needsCursorRedraw
            if AlacrittyFrameRetryPolicy.shouldPauseDisplayLink(
                renderSucceeded: rendered
            ) || AlacrittyFrameRetryPolicy.shouldPauseDisplayLinkForSelectionRetry(
                renderSucceeded: rendered,
                retryWaiting: selectionRetryWaiting,
                hasOtherPendingWork: hasOtherPendingWork
            ) {
                displayLink?.isPaused = true
            }
        }
    }

    /// Hover underline is OR'd onto snapshot cells. Partial row refills
    /// restore emulator flags, so a hover that is still active is applied
    /// again; clearing hover force-redraws so those rows refill without it.
    private func applyHoveredURLUnderline(to snapshot: inout KeroSnapshot) {
        guard let hoveredURL,
              snapshot.columns > 0,
              snapshot.rows > 0,
              let cells = snapshot.cells
        else { return }

        let mutableCells = UnsafeMutablePointer(mutating: cells)
        let firstRow = max(hoveredURL.startLine, 0)
        let lastRow = min(hoveredURL.endLine, snapshot.rows - 1)
        guard firstRow <= lastRow else { return }

        for row in firstRow...lastRow {
            let firstColumn = row == hoveredURL.startLine ? hoveredURL.startColumn : 0
            let lastColumn = row == hoveredURL.endLine
                ? hoveredURL.endColumn : snapshot.columns - 1
            let clampedFirst = max(firstColumn, 0)
            let clampedLast = min(lastColumn, snapshot.columns - 1)
            guard clampedFirst <= clampedLast else { continue }

            for column in clampedFirst...clampedLast {
                mutableCells[row * snapshot.columns + column].flags |= UInt16(
                    KERO_CELL_UNDERLINE
                )
            }
        }
    }

    private func updateKittyGraphics(snapshot: KeroKittySnapshot) {
        guard snapshot.placements_len > 0, let placements = snapshot.placements else {
            kittyPlacements = []
            kittyImageData = [:]
            return
        }

        let buffer = UnsafeBufferPointer(
            start: placements,
            count: Int(snapshot.placements_len)
        )
        var activeImageKeys = Set<AlacrittyKittyImageKey>()
        kittyPlacements = buffer.compactMap { placement in
            let key = AlacrittyKittyImageKey(
                imageID: placement.image_id,
                generation: placement.image_generation
            )
            activeImageKeys.insert(key)
            let pixels: Data
            if let cached = kittyImageData[key] {
                pixels = cached
            } else if placement.pixels_len > 0, let bytes = placement.pixels {
                pixels = Data(bytes: bytes, count: Int(placement.pixels_len))
                kittyImageData[key] = pixels
            } else {
                return nil
            }
            return AlacrittyKittyPlacement(placement, pixels: pixels)
        }
        kittyImageData = kittyImageData.filter { activeImageKeys.contains($0.key) }
    }

    private func didPresentFrame(
        generation: UInt64,
        size: CGSize,
        scale: CGFloat
    ) {
        guard generation == presentationGeneration else { return }
        lastPresentedSize = size
        lastPresentedScale = scale
        guard isAwaitingVisibleFrame else { return }
        let currentScale = window?.backingScaleFactor ?? 2
        guard isSurfaceVisible,
              bounds.size == size,
              currentScale == scale
        else {
            // Geometry changed after this command buffer was submitted. Its
            // drawable stays behind the cover; render another at the new size.
            if isSurfaceVisible {
                schedulePresentationOpportunity(force: true)
            }
            return
        }
        isAwaitingVisibleFrame = false
        setPresentationCoverVisible(false)
    }

    private func setPresentationCoverVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presentationCoverLayer.isHidden = !visible
        CATransaction.commit()
    }

    /// Copies render and IME anchors from an accepted snapshot. The render
    /// sentinel can be -1 while the IME anchor is still in the live viewport.
    private func acceptCursor(from snapshot: KeroSnapshot) {
        cursorCache.update(
            line: snapshot.cursor_line,
            column: snapshot.cursor_column,
            imeLine: snapshot.ime_cursor_line,
            imeColumn: snapshot.ime_cursor_column,
            shape: snapshot.cursor_shape,
            color: snapshot.cursor_color
        )
    }

    private func updateMarkedTextOverlay(snapshot: KeroSnapshot) {
        // Use the IME anchor, not the render cursor: TUIs often hide the
        // drawn cursor while the insertion point is still in the viewport.
        guard !markedText.isEmpty,
              snapshot.ime_cursor_line >= 0,
              snapshot.ime_cursor_column >= 0
        else {
            markedTextField.isHidden = true
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.regular,
            .foregroundColor: Theme.terminal(
                dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ).foregroundNSColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let attributed = NSAttributedString(string: markedText, attributes: attributes)
        markedTextField.attributedStringValue = attributed
        markedTextField.backgroundColor = Theme.terminal(
            dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ).backgroundNSColor
        let width = max(
            attributed.size().width.rounded(.up) + 2,
            metrics.cellWidth
        )
        markedTextField.frame = NSRect(
            x: Self.padding.x + CGFloat(snapshot.ime_cursor_column) * metrics.cellWidth,
            y: bounds.height - Self.padding.y
                - CGFloat(snapshot.ime_cursor_line + 1) * metrics.cellHeight,
            width: width,
            height: metrics.cellHeight
        )
        markedTextField.isHidden = false
    }

    private func updateCursorBlinking(_ blinking: Bool) {
        if blinking != cursorBlinking {
            cursorBlinking = blinking
            cursorVisible = true
        }
        updateCursorTimer()
    }

    private func updateCursorTimer() {
        let shouldBlink =
            cursorBlinking && isSurfaceVisible && hasEffectiveTerminalFocus
        guard shouldBlink else {
            cursorTimer?.invalidate()
            cursorTimer = nil
            cursorVisible = true
            return
        }
        guard cursorTimer == nil else { return }
        cursorTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cursorBlinking else { return }
                self.cursorVisible.toggle()
                self.needsCursorRedraw = true
                self.scheduleRender()
            }
        }
    }

    private func resetCursorBlink() {
        guard cursorBlinking else { return }
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true
        needsCursorRedraw = true
        updateCursorTimer()
        scheduleRender()
    }

    /// Feeds Kero's overlay scrollbar from the frame already snapshotted
    /// for drawing. A second full-grid copy on every PTY wakeup was the
    /// cheapest way to miss 120 Hz while a coding agent streamed.
    private func reportScroll(
        totalLines: Int,
        screenLines: Int,
        displayOffset: Int
    ) {
        let total = UInt64(totalLines)
        let viewport = UInt64(screenLines)
        // `display_offset` counts up as the viewport moves back through the
        // scrollback; Kero's scrollbar measures down from the oldest row.
        let scrolledBack = UInt64(displayOffset)
        let top = total > viewport
            ? (total - viewport) - min(scrolledBack, total - viewport) : 0
        let position = TerminalScrollPosition(
            totalRows: total, viewportRows: viewport, topRow: top
        )
        lastScrollPosition = position
        if let fraction = pendingScrollFraction {
            pendingScrollFraction = nil
            let topRow = position.row(atDragFraction: fraction)
            let history = total > viewport ? total - viewport : 0
            let displayOffset = history - min(topRow, history)
            pendingFrameIntent.setScrollTarget(Int64(clamping: displayOffset))
            scheduleRender()
        }
        events?.terminalDidScroll(position)
    }

    // MARK: - Events from the PTY thread

    /// Always called on the main thread; `alacrittyEventCallback` bounces.
    func handleEvent(kind: UInt32, payload: Data) {
        guard !isDetached else { return }
        if events == nil,
           kind == KERO_EVENT_TITLE
            || kind == KERO_EVENT_BELL
            || kind == KERO_EVENT_EXIT
            || kind == KERO_EVENT_CLIPBOARD_LOAD
            || kind == KERO_EVENT_WORKING_DIRECTORY
            || kind == KERO_EVENT_NOTIFICATION
            || kind == KERO_EVENT_SHELL_PROMPT_START
            || kind == KERO_EVENT_SHELL_COMMAND_START
            || kind == KERO_EVENT_SHELL_COMMAND_EXECUTING
            || kind == KERO_EVENT_SHELL_COMMAND_FINISHED {
            if pendingEvents.count < 64 {
                pendingEvents.append((kind, payload))
            }
            return
        }

        switch kind {
        case KERO_EVENT_WAKEUP:
            findState.observeWakeup()
            updateFocusReport()
            if isPointerInside, isCommandPressed {
                refreshURLHover(modifierFlags: NSEvent.modifierFlags)
            }
            // Output must not restart the host cursor timer. Animated TUIs can
            // wake the PTY many times per second even while the user is idle.
            if isSurfaceVisible {
                pendingFrameIntent.requestTerminalDamageCheck()
                scheduleRender()
            }
        case KERO_EVENT_TITLE:
            let title = String(decoding: payload, as: UTF8.self)
            if !title.isEmpty { events?.terminalDidChangeTitle(title) }
        case KERO_EVENT_BELL:
            events?.terminalDidRingBell()
        case KERO_EVENT_EXIT:
            if let handle { kero_alacritty_mark_exited(handle) }
            events?.terminalDidClose(processAlive: false)
        case KERO_EVENT_CLIPBOARD_STORE:
            // OSC 52 copy. AppSettings.clipboardWrite decides whether this
            // replaces the clipboard, asks first, or is ignored.
            let text = String(decoding: payload, as: UTF8.self)
            guard !text.isEmpty else { return }
            events?.terminalDidRequestClipboardWrite(
                TerminalClipboardRequest(contents: text) { approved in
                    guard approved else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            )
        case KERO_EVENT_CLIPBOARD_LOAD:
            guard payload.count == MemoryLayout<UInt64>.size else { return }
            var requestID: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &requestID) { bytes in
                payload.copyBytes(to: bytes)
            }
            requestID = UInt64(littleEndian: requestID)
            let contents = Self.pasteboardString(from: .general) ?? ""
            events?.terminalDidRequestClipboardConfirmation(
                TerminalClipboardRequest(contents: contents) {
                    [weak self] approved in
                    self?.resolveClipboard(
                        requestID: requestID,
                        contents: contents,
                        approved: approved
                    )
                }
            )
        case KERO_EVENT_WORKING_DIRECTORY:
            let path = String(decoding: payload, as: UTF8.self)
            guard !path.isEmpty else { return }
            usesOSCWorkingDirectory = true
            directoryTimer?.invalidate()
            directoryTimer = nil
            guard path != lastReportedDirectory else { return }
            lastReportedDirectory = path
            events?.terminalDidChangeWorkingDirectory(path)
        case KERO_EVENT_PROGRESS:
            guard payload.count == 3,
                  let state = Self.progressState(rawValue: payload[0])
            else { return }
            let percent = payload[2] == 0 ? nil : Int(payload[1])
            progressBar.applyReport(state: state, percent: percent)
        case KERO_EVENT_NOTIFICATION:
            let message = String(decoding: payload, as: UTF8.self)
            guard !message.isEmpty else { return }
            events?.terminalDidRequestDesktopNotification(title: "", body: message)
        case KERO_EVENT_SHELL_PROMPT_START:
            events?.terminalDidReportShellIntegration(.promptStart)
        case KERO_EVENT_SHELL_COMMAND_START:
            events?.terminalDidReportShellIntegration(.commandStart)
        case KERO_EVENT_SHELL_COMMAND_EXECUTING:
            events?.terminalDidReportShellIntegration(.commandExecuting)
        case KERO_EVENT_SHELL_COMMAND_FINISHED:
            guard payload.count == MemoryLayout<Int32>.size else { return }
            var rawExitCode: Int32 = -1
            _ = withUnsafeMutableBytes(of: &rawExitCode) { bytes in
                payload.copyBytes(to: bytes)
            }
            let exitCode = Int32(littleEndian: rawExitCode)
            events?.terminalDidReportShellIntegration(
                .commandFinished(
                    exitCode: exitCode < 0 ? nil : Int(exitCode),
                    durationNanos: nil
                )
            )
        case KERO_EVENT_MOUSE_SHAPE:
            let name = String(decoding: payload, as: UTF8.self)
            guard let cursor = Self.cursor(mouseShape: name), cursor !== mouseShapeCursor
            else { return }
            mouseShapeCursor = cursor
            // The pointer is usually already over the pane when a program
            // changes shape, so apply it now rather than on the next move —
            // unless a cmd-hovered link is showing the pointing hand.
            if isPointerInside, hoveredURL == nil {
                cursor.set()
            }
        default:
            break
        }
    }

    private static func progressState(rawValue: UInt8) -> TerminalProgressState? {
        switch rawValue {
        case 0: .remove
        case 1: .set
        case 2: .error
        case 3: .indeterminate
        case 4: .pause
        default: nil
        }
    }

    /// Closest AppKit cursor for an OSC 22 pointer-shape name — the same CSS
    /// cursor keywords and fallbacks as Kero's Ghostty panes, where macOS has
    /// no public cursor for a handful of shapes (help, progress/wait, the
    /// diagonal resizes). Unknown names are nil so they leave the pointer
    /// alone instead of quietly becoming an arrow.
    private static func cursor(mouseShape name: String) -> NSCursor? {
        switch name {
        case "text": .iBeam
        case "vertical-text": .iBeamCursorForVerticalLayout
        case "pointer": .pointingHand
        case "context-menu": .contextualMenu
        case "cell", "crosshair": .crosshair
        case "alias": .dragLink
        case "copy": .dragCopy
        case "no-drop", "not-allowed": .operationNotAllowed
        case "grab", "all-scroll": .openHand
        case "grabbing", "move": .closedHand
        case "col-resize", "e-resize", "w-resize", "ew-resize": .resizeLeftRight
        case "row-resize", "n-resize", "s-resize", "ns-resize": .resizeUpDown
        case "default", "help", "progress", "wait",
             "ne-resize", "nw-resize", "se-resize", "sw-resize",
             "nesw-resize", "nwse-resize", "zoom-in", "zoom-out": .arrow
        default: nil
        }
    }

    private func flushPendingEvents() {
        guard events != nil, !pendingEvents.isEmpty else { return }
        let queued = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        for event in queued {
            handleEvent(kind: event.kind, payload: event.payload)
        }
    }

    private func resolveClipboard(
        requestID: UInt64, contents: String, approved: Bool
    ) {
        guard let handle else { return }
        let bytes = Array(contents.utf8)
        bytes.withUnsafeBufferPointer { pointer in
            kero_alacritty_resolve_clipboard(
                handle, requestID, pointer.baseAddress, pointer.count, approved
            )
        }
    }

    // MARK: - TerminalBackendSurface

    func sendText(_ text: String) {
        write(Array(text.utf8))
    }

    func sendApplicationScroll(lines: Int) -> Bool {
        guard lines != 0 else { return false }
        let mode = terminalMode
        if mode.contains(.mouseReporting) {
            let code = lines > 0 ? 64 : 65
            let column = max(gridSize.columns / 2, 0)
            let row = max(gridSize.rows / 2, 0)
            for _ in 0..<min(abs(lines), 50) {
                sendMouse(
                    code: code,
                    column: column,
                    row: row,
                    modifiers: 0,
                    released: false
                )
            }
            return true
        }
        if mode.contains(.alternateScreen), mode.contains(.alternateScroll) {
            let sequence = AlacrittyKeyMap.cursor(up: lines > 0, mode: mode)
            for _ in 0..<min(abs(lines), 50) { writeControl(sequence) }
            return true
        }
        return false
    }

    func clearScreen() {
        guard let handle else { return }
        kero_alacritty_clear(handle)
        // Ask the foreground shell to repaint its prompt at the top.
        write([0x0c])
        scheduleRender(force: true)
    }

    func scroll(toFraction fraction: Double) {
        guard handle != nil else { return }
        guard fraction.isFinite else { return }
        let clampedFraction = min(max(fraction, 0), 1)
        guard let position = lastScrollPosition else {
            pendingScrollFraction = clampedFraction
            scheduleRender()
            return
        }
        let topRow = position.row(atDragFraction: clampedFraction)
        let history = position.totalRows > position.viewportRows
            ? position.totalRows - position.viewportRows : 0
        // The scrollbar runs oldest-to-newest; display offset runs the other way.
        let displayOffset = history - min(topRow, history)
        pendingFrameIntent.setScrollTarget(Int64(clamping: displayOffset))
        scheduleRender()
    }

    var selectionAvailability: TerminalSelectionAvailability {
        guard let handle else { return .empty }
        switch kero_alacritty_selection_state(handle) {
        case KERO_SELECTION_BUSY: return .busy
        case KERO_SELECTION_PRESENT: return .selected
        default: return .empty
        }
    }

    var hasSelection: Bool {
        selectionAvailability == .selected
    }

    var hasEffectiveTerminalFocus: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }

    // MARK: - Find

    func beginFind(_ needle: String) {
        findState.begin(needle: needle, handle: handle, events: events)
        scheduleRender(force: true)
    }

    func endFind() {
        findState.end(handle: handle)
        scheduleRender(force: true)
    }

    func stepFind(forward: Bool) {
        findState.step(forward: forward, handle: handle, events: events)
        scheduleRender(force: true)
    }

    func findSelection() {
        guard handle != nil else { return }
        selectionRetryIntent.enqueue(.findSelection)
        _ = retrySelectionWork()
        scheduleSelectionRetry()
    }

    func exportScreenFile() -> String? {
        exportFile(scrollbackOnly: false)
    }

    func exportScrollbackFile() -> String? {
        exportFile(scrollbackOnly: true)
    }

    /// Reads the already-materialized viewport snapshot. Bounded by rows ×
    /// columns so status observation and CLI reads never walk the 10,000-line
    /// scrollback. Returns the last `maxLines` non-empty rows so a fresh
    /// prompt at the top of a tall grid is not dropped.
    func readVisibleText(maxLines: Int, maxColumns: Int) -> String? {
        guard let handle else { return nil }
        var snapshot = KeroSnapshot()
        guard kero_alacritty_try_snapshot(handle, &snapshot) else { return nil }
        guard snapshot.columns > 0, snapshot.rows > 0,
              let cells = snapshot.cells
        else { return "" }

        let boundedRows = min(snapshot.rows, max(maxLines, 1))
        let boundedColumns = min(snapshot.columns, max(maxColumns, 1))
        var lines: [String] = []
        lines.reserveCapacity(snapshot.rows)
        for row in 0..<snapshot.rows {
            var line = ""
            line.reserveCapacity(boundedColumns)
            for column in 0..<boundedColumns {
                let cell = cells[row * snapshot.columns + column]
                if cell.flags & UInt16(KERO_CELL_WIDE_SPACER) != 0 { continue }
                if cell.flags & UInt16(KERO_CELL_HIDDEN) != 0 {
                    line.append(" ")
                    continue
                }
                if cell.text_len > 0, let text = snapshot.text {
                    let offset = Int(cell.text_offset)
                    let length = Int(cell.text_len)
                    guard offset >= 0, length >= 0,
                          offset + length <= snapshot.text_len
                    else { continue }
                    line += String(
                        decoding: UnsafeBufferPointer(
                            start: text.advanced(by: offset), count: length
                        ),
                        as: UTF8.self
                    )
                } else if let scalar = UnicodeScalar(cell.ch) {
                    line.unicodeScalars.append(scalar)
                }
            }
            while line.last == " " || line.last == "\t" { line.removeLast() }
            lines.append(line)
        }
        // A fresh prompt sits at the top of a tall grid. Taking the bottom N
        // rows would return blanks. Drop trailing empty rows, then keep the
        // last maxLines of what remains.
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count > boundedRows {
            lines.removeFirst(lines.count - boundedRows)
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the bridge's styled VT stream to its own directory under the
    /// temporary directory, which is the contract `TerminalHistorySerializer`
    /// validates before it reads.
    private func exportFile(scrollbackOnly: Bool) -> String? {
        guard let handle else { return nil }
        let needed = kero_alacritty_buffer_text(handle, scrollbackOnly, nil, 0)
        guard needed > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            kero_alacritty_buffer_text(handle, scrollbackOnly, pointer.baseAddress, needed)
        }
        guard written > 0 else { return nil }

        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("kero-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let file = directory.appendingPathComponent("screen.vt")
            try Data(buffer[..<written]).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            try? manager.removeItem(at: directory)
            return nil
        }
    }

    // MARK: - Input

    private func write(_ bytes: [UInt8]) {
        guard let handle, !bytes.isEmpty else { return }
        cancelSelectionRetryForTerminalInput()
        bytes.withUnsafeBufferPointer { pointer in
            kero_alacritty_write(handle, pointer.baseAddress, pointer.count)
        }
        resetCursorBlink()
    }

    private func cancelSelectionRetryProbe() {
        selectionRetryProbeGeneration &+= 1
        selectionRetryProbeWorkItem?.cancel()
        selectionRetryProbeWorkItem = nil
        selectionRetryProbeState.cancel()
    }

    private func resetSelectionRetryWindow() {
        cancelSelectionRetryProbe()
        selectionRetryIntent.resetRetryWindow()
    }

    private func cancelSelectionRetry() {
        selectionRetryIntent.cancel()
        selectionRetryQueued = false
        selectionRetryGeneration &+= 1
        cancelSelectionRetryProbe()
    }

    private func cancelSelectionRetryForTerminalInput() {
        selectionRetryIntent.supersedeForTerminalInput()
        selectionRetryQueued = false
        selectionRetryGeneration &+= 1
        cancelSelectionRetryProbe()
    }

    private func scheduleSelectionRetryProbe() {
        guard isSurfaceVisible,
              layer is CAMetalLayer,
              handle != nil,
              AlacrittySelectionRetryPolicy.shouldScheduleProbe(
                  actionPending: !selectionRetryIntent.isEmpty,
                  retryWindowExhausted: selectionRetryIntent.retryWindowExhausted,
                  probeScheduled: selectionRetryProbeState.isScheduled
              )
        else { return }

        let generation = selectionRetryProbeGeneration
        guard selectionRetryProbeState.schedule(generation: generation) else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.selectionRetryProbeGeneration == generation,
                  self.selectionRetryProbeState.begin(generation: generation)
            else { return }
            self.selectionRetryProbeWorkItem = nil
            guard !self.isDetached,
                  self.isSurfaceVisible,
                  self.layer is CAMetalLayer,
                  self.handle != nil,
                  !self.selectionRetryIntent.isEmpty,
                  self.selectionRetryIntent.retryWindowExhausted
            else { return }
            // A probe opens one new finite window. It never starts or keeps
            // the 120 Hz display link alive by itself; the normal retry timer
            // performs one paced scheduleRender after this reset.
            self.selectionRetryIntent.resetRetryWindow()
            self.scheduleSelectionRetry()
        }
        selectionRetryProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + .milliseconds(AlacrittySelectionRetryPolicy
                    .probeDelayMilliseconds),
            execute: workItem
        )
    }

    private func scheduleSelectionRetry() {
        guard !selectionRetryIntent.isEmpty, isSurfaceVisible else { return }
        guard !selectionRetryIntent.retryWindowExhausted else {
            scheduleSelectionRetryProbe()
            return
        }
        // A new finite retry window supersedes any stale low-frequency probe.
        cancelSelectionRetryProbe()
        guard !selectionRetryQueued else { return }
        selectionRetryQueued = true
        let generation = selectionRetryGeneration
        let delay = selectionRetryIntent.retryDelayMilliseconds
        // Back off under sustained PTY contention. The intent remains pending,
        // but a busy selection cannot keep the display link active at 120 Hz.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(delay)
        ) { [weak self] in
            guard let self else { return }
            guard self.selectionRetryGeneration == generation else { return }
            self.selectionRetryQueued = false
            guard !self.selectionRetryIntent.isEmpty,
                  self.isSurfaceVisible,
                  self.handle != nil
            else { return }
            self.scheduleRender()
        }
    }

    @discardableResult
    private func retrySelectionWork() -> Bool {
        guard !selectionRetryQueued else { return false }
        guard let handle else {
            cancelSelectionRetry()
            return false
        }
        guard selectionRetryIntent.beginAttempt(),
              let action = selectionRetryIntent.action
        else {
            if selectionRetryIntent.retryWindowExhausted {
                scheduleSelectionRetryProbe()
            }
            return false
        }
        defer {
            if selectionRetryIntent.isEmpty {
                cancelSelectionRetryProbe()
            }
        }

        switch action {
        case .selectAll:
            guard kero_alacritty_select_all(handle) else {
                scheduleSelectionRetry()
                return false
            }
            selectionRetryIntent.acceptCurrent()
            if !selectionRetryIntent.isEmpty {
                scheduleSelectionRetry()
            }
            return true

        case .copySelection:
            switch readSelectionText(handle) {
            case .busy:
                scheduleSelectionRetry()
                return false
            case .empty:
                selectionRetryIntent.complete()
                return false
            case let .text(text):
                selectionRetryIntent.complete()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return false
            }

        case .findSelection:
            switch readSelectionText(handle) {
            case .busy:
                scheduleSelectionRetry()
                return false
            case .empty:
                selectionRetryIntent.complete()
                return false
            case let .text(text):
                selectionRetryIntent.complete()
                events?.terminalDidBeginFind(needle: text)
                beginFind(text)
                return false
            }

        case let .start(start, _):
            guard kero_alacritty_selection_start(
                handle, Int32(start.line), start.column,
                start.kind, start.rightHalf
            ) else {
                scheduleSelectionRetry()
                return false
            }
            if selectionMouseDown {
                selectionIntent.start(
                    AlacrittySelectionAnchor(line: start.line, column: start.column),
                    accepted: true
                )
            }
            selectionRetryIntent.acceptStart()
            if !selectionRetryIntent.isEmpty {
                scheduleSelectionRetry()
            }
            return true

        case let .update(endpoint):
            guard kero_alacritty_selection_update(
                handle, Int32(endpoint.line), endpoint.column, endpoint.rightHalf
            ) else {
                scheduleSelectionRetry()
                return false
            }
            selectionRetryIntent.acceptUpdate()
            if !selectionRetryIntent.isEmpty {
                scheduleSelectionRetry()
            }
            return true
        }
    }

    private enum SelectionTextRead {
        case busy
        case empty
        case text(String)
    }

    private func readSelectionText(_ handle: OpaquePointer) -> SelectionTextRead {
        switch kero_alacritty_selection_state(handle) {
        case KERO_SELECTION_BUSY: return .busy
        case KERO_SELECTION_EMPTY: return .empty
        default: break
        }
        let needed = kero_alacritty_selection_text(handle, nil, 0)
        guard needed > 0 else {
            return kero_alacritty_selection_state(handle) == KERO_SELECTION_BUSY
                ? .busy : .empty
        }
        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            kero_alacritty_selection_text(handle, pointer.baseAddress, needed)
        }
        guard written > 0, written <= buffer.count else {
            return kero_alacritty_selection_state(handle) == KERO_SELECTION_BUSY
                ? .busy : .empty
        }
        return .text(String(decoding: buffer[..<written], as: UTF8.self))
    }

    private func clearSelectionIfNeeded() {
        guard let handle else { return }
        kero_alacritty_clear_selection_async(handle)
    }

    private func writeControl(_ bytes: [UInt8]) {
        guard let handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { pointer in
            kero_alacritty_write_control(handle, pointer.baseAddress, pointer.count)
        }
    }

    private var terminalMode: AlacrittyTerminalMode {
        guard let handle else { return [] }
        // The bridge reads the worker-published mode value. Input paths must
        // not take the emulator mutex to classify a scroll or key event.
        return AlacrittyTerminalMode(rawValue: kero_alacritty_mode(handle))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
            updateActiveTimers()
            schedulePresentationOpportunity(force: true)
            updateFocusReport()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateActiveTimers()
                self.updateFocusReport()
                if self.isSurfaceVisible {
                    self.schedulePresentationOpportunity(force: true)
                }
            }
        }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
        DispatchQueue.main.async { [weak self] in
            self?.updateBackingLayerActivity()
            self?.updateActiveTimers()
            self?.updateFocusReport()
        }
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        isCommandPressed = false
        updateHoveredURL(nil)
        // In normal mode, once the app is inactive, release the drawable pool
        // after capturing a steady cursor. Benchmark mode intentionally keeps
        // the CAMetalLayer attached so presentation timestamps remain visible.
        if presentationPolicy.shouldFreezeOnApplicationResignActive {
            freezeVisibleFrame(cursorHasFocus: false)
        }
    }

    @objc private func effectiveFocusChanged(_ notification: Notification) {
        // App/window notifications can arrive before AppKit's active and key
        // flags have settled. Render from the final focus state next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateActiveTimers()
            self.updateFocusReport()
            self.updateBackingLayerActivity()
            self.refreshURLHover(modifierFlags: NSEvent.modifierFlags)
            if self.shouldKeepMetalLayerActive {
                self.schedulePresentationOpportunity(force: true)
            }
        }
    }

    private func updateFocusReport() {
        let mode = terminalMode
        guard mode.contains(.focusReporting) else {
            lastReportedFocus = nil
            return
        }
        let focused = hasEffectiveTerminalFocus
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        writeControl(Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8))
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), handle != nil {
            switch Int(event.keyCode) {
            case 115: // Command-Home
                pendingFrameIntent.setScrollTarget(nil)
                pendingFrameIntent.addScroll(lines: Int.max)
                scheduleRender()
                return
            case 119: // Command-End
                pendingFrameIntent.setScrollTarget(0)
                scheduleRender()
                return
            case 116, 121: // Command-Page Up / Page Down
                let delta = Int(max(gridSize.rows, 1)) * (event.keyCode == 116 ? 1 : -1)
                pendingFrameIntent.addScroll(lines: delta)
                scheduleRender()
                return
            default:
                break
            }
        }

        // While an IME is composing, every key belongs to the input context —
        // including arrows, Enter, and Escape that select or cancel.
        if hasMarkedText() {
            _ = inputContext?.handleEvent(event)
            return
        }

        // Ctrl / enabled Option-as-Alt / special keys encode as terminal
        // sequences. Text returns nil from the key map so macOS input sources
        // can compose before committed Unicode reaches `insertText`.
        if let bytes = AlacrittyKeyMap.bytes(
            for: event,
            mode: terminalMode,
            optionAsAlt: AppSettings.shared.macosOptionAsAlt
        ) {
            write(bytes)
            return
        }

        // First key of a composition, committed Unicode from an input source,
        // or a shortcut Kero's menus own.
        if inputContext?.handleEvent(event) == true {
            return
        }
        interpretKeyEvents([event])
    }

    override func mouseDown(with event: NSEvent) {
        focusForInteraction()
        guard let handle else { return }
        if event.modifierFlags.contains(.command),
           let hit = url(at: gridPoint(for: event)) {
            events?.terminalDidRequestOpenURL(hit.value)
            return
        }
        if shouldReportMouse(event) {
            // Deliver the click to the TUI, but drop a leftover Select All
            // first. Mouse reporting would otherwise keep the highlight.
            selectionMouseDown = false
            selectionIntent.finish()
            cancelSelectionRetry()
            clearSelectionIfNeeded()
            reportingMouseButton = true
            sendMouse(code: 0, event: event, released: false)
            return
        }
        cancelSelectionRetry()
        selectionMouseDown = true
        let point = gridPoint(for: event)
        let kind: UInt32 = switch event.clickCount {
        case 2: 1 // word
        case 3: 2 // line
        default: 0
        }
        let start = AlacrittySelectionStartIntent(
            line: point.line,
            column: point.column,
            kind: kind,
            rightHalf: point.rightHalf
        )
        let accepted = kero_alacritty_selection_start(
            handle, Int32(point.line), point.column, kind, point.rightHalf
        )
        selectionIntent.start(
            AlacrittySelectionAnchor(line: point.line, column: point.column),
            accepted: accepted
        )
        guard accepted else {
            selectionRetryIntent.enqueueStart(start)
            scheduleSelectionRetry()
            return
        }
        scheduleRender()
    }

    override func mouseDragged(with event: NSEvent) {
        if reportingMouseButton {
            if terminalMode.contains(.mouseDrag) || terminalMode.contains(.mouseMotion) {
                sendMouse(code: 32, event: event, released: false)
            }
            return
        }
        guard let handle else { return }
        let point = gridPoint(for: event)
        let endpoint = AlacrittySelectionEndpoint(
            line: point.line, column: point.column, rightHalf: point.rightHalf
        )
        guard selectionIntent.anchor != nil else {
            guard selectionRetryIntent.hasPendingStart else { return }
            selectionRetryIntent.enqueueUpdate(endpoint)
            scheduleSelectionRetry()
            return
        }
        let accepted = kero_alacritty_selection_update(
            handle, Int32(point.line), point.column, point.rightHalf
        )
        guard selectionIntent.update(accepted: accepted) else {
            selectionRetryIntent.enqueueUpdate(endpoint)
            scheduleSelectionRetry()
            return
        }
        _ = selectionRetryIntent.acceptUpdate()
        if !selectionRetryIntent.isEmpty {
            scheduleSelectionRetry()
        }
        scheduleRender()
    }

    override func mouseUp(with event: NSEvent) {
        if reportingMouseButton {
            reportingMouseButton = false
            sendMouse(code: 0, event: event, released: true)
        }
        selectionMouseDown = false
        selectionIntent.finish()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        startModifierMonitor()
        updateURLHover(
            at: convert(event.locationInWindow, from: nil),
            modifierFlags: event.modifierFlags
        )
    }

    override func mouseMoved(with event: NSEvent) {
        isPointerInside = true
        startModifierMonitor()
        updateURLHover(
            at: convert(event.locationInWindow, from: nil),
            modifierFlags: event.modifierFlags
        )
        if terminalMode.contains(.mouseMotion), shouldReportMouse(event) {
            sendMouse(code: 35, event: event, released: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        isCommandPressed = false
        stopModifierMonitor()
        updateHoveredURL(nil)
        // SwiftUI chrome does not necessarily install a cursor rect, so clear
        // the terminal's explicitly-set text cursor when leaving the surface.
        NSCursor.arrow.set()
    }

    private func startModifierMonitor() {
        guard modifierMonitor == nil else { return }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.refreshURLHover(modifierFlags: event.modifierFlags)
            }
            return event
        }
    }

    private func stopModifierMonitor() {
        guard let modifierMonitor else { return }
        NSEvent.removeMonitor(modifierMonitor)
        self.modifierMonitor = nil
    }

    private func refreshURLHover(modifierFlags: NSEvent.ModifierFlags) {
        guard let window, window.isKeyWindow, isSurfaceVisible else {
            isCommandPressed = false
            updateHoveredURL(nil)
            return
        }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isPointerInside = bounds.contains(local)
        guard isPointerInside else {
            isCommandPressed = false
            stopModifierMonitor()
            updateHoveredURL(nil)
            return
        }
        startModifierMonitor()
        updateURLHover(at: local, modifierFlags: modifierFlags)
    }

    private func updateURLHover(
        at localPoint: NSPoint,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        isCommandPressed = modifierFlags.contains(.command)
        guard isCommandPressed else {
            updateHoveredURL(nil)
            mouseShapeCursor.set()
            return
        }

        let hit = url(at: gridPoint(at: localPoint))
        updateHoveredURL(hit)
        (hit == nil ? mouseShapeCursor : NSCursor.pointingHand).set()
    }

    private func updateHoveredURL(_ hit: URLHit?) {
        guard hit != hoveredURL else { return }
        hoveredURL = hit
        scheduleRender(force: true)
    }

    /// Output, scrollback, and resizes can move text without moving the
    /// pointer. Revalidate before a frame so a cached underline never remains
    /// attached to cells that are no longer the hovered URL.
    private func revalidateURLHoverForRender() {
        guard isPointerInside,
              isCommandPressed,
              NSApp.isActive,
              let window,
              window.isKeyWindow
        else {
            if hoveredURL != nil {
                hoveredURL = nil
                needsUnconditionalRedraw = true
            }
            return
        }

        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else {
            isPointerInside = false
            isCommandPressed = false
            if hoveredURL != nil {
                hoveredURL = nil
                needsUnconditionalRedraw = true
            }
            return
        }

        let hit = url(at: gridPoint(at: local))
        if hit != hoveredURL {
            hoveredURL = hit
            needsUnconditionalRedraw = true
        }
        (hit == nil ? mouseShapeCursor : NSCursor.pointingHand).set()
    }

    override func scrollWheel(with event: NSEvent) {
        guard handle != nil else { return }
        // Line-mode events already count rows; pixel-mode ones need the cell
        // height applied before they mean anything.
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / metrics.cellHeight
            : event.scrollingDeltaY
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator)
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)

        let mode = terminalMode
        if mode.contains(.mouseReporting) {
            let code = lines > 0 ? 64 : 65
            for _ in 0..<min(abs(lines), 50) {
                sendMouse(code: code, event: event, released: false)
            }
            return
        }
        if mode.contains(.alternateScreen), mode.contains(.alternateScroll) {
            let sequence = AlacrittyKeyMap.cursor(up: lines > 0, mode: mode)
            for _ in 0..<min(abs(lines), 50) {
                writeControl(sequence)
            }
            return
        }

        // Accumulate and apply inside the frame's locked region. The mode is
        // read from the bridge's published value; this path does not take the
        // terminal mutex for each trackpad event.
        pendingFrameIntent.addScroll(lines: lines)
        scheduleRender()
    }

    private func gridPoint(for event: NSEvent) -> (line: Int, column: Int, rightHalf: Bool) {
        gridPoint(at: convert(event.locationInWindow, from: nil))
    }

    private func gridPoint(at local: NSPoint) -> (line: Int, column: Int, rightHalf: Bool) {
        let x = local.x - Self.padding.x
        // The view is unflipped, so row 0 is at the top of the content box.
        let y = bounds.maxY - Self.padding.y - local.y
        let exactColumn = x / metrics.cellWidth
        let column = min(max(Int(exactColumn.rounded(.down)), 0), max(gridSize.columns - 1, 0))
        let line = min(max(Int((y / metrics.cellHeight).rounded(.down)), 0), max(gridSize.rows - 1, 0))
        return (line, column, exactColumn - CGFloat(column) > 0.5)
    }

    private func focusForInteraction() {
        if window?.firstResponder === self {
            onBecomeFirstResponder?()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    private func shouldReportMouse(_ event: NSEvent) -> Bool {
        terminalMode.contains(.mouseReporting)
            && !event.modifierFlags.contains(.shift)
    }

    private func sendMouse(code: Int, event: NSEvent, released: Bool) {
        let mode = terminalMode
        guard mode.contains(.mouseReporting) else { return }
        let point = gridPoint(for: event)
        let modifiers =
            (event.modifierFlags.contains(.shift) ? 4 : 0)
            + (event.modifierFlags.contains(.option) ? 8 : 0)
            + (event.modifierFlags.contains(.control) ? 16 : 0)
        sendMouse(
            code: code,
            column: point.column,
            row: point.line,
            modifiers: modifiers,
            released: released
        )
    }

    private func sendMouse(
        code: Int,
        column: Int,
        row: Int,
        modifiers: Int,
        released: Bool
    ) {
        let mode = terminalMode
        guard mode.contains(.mouseReporting) else { return }
        let x = column + 1
        let y = row + 1

        if mode.contains(.sgrMouse) {
            let suffix = released ? "m" : "M"
            writeControl(Array("\u{1b}[<\(code + modifiers);\(x);\(y)\(suffix)".utf8))
            return
        }

        let legacyCode = (released ? 3 : code) + modifiers + 32
        let legacyX = x + 32
        let legacyY = y + 32
        guard legacyCode <= 255, legacyX <= 255, legacyY <= 255 else { return }
        writeControl([0x1b, UInt8(ascii: "["), UInt8(ascii: "M"),
                      UInt8(legacyCode), UInt8(legacyX), UInt8(legacyY)])
    }

    private func url(
        at point: (line: Int, column: Int, rightHalf: Bool)
    ) -> URLHit? {
        guard let handle else { return nil }
        let needed = kero_alacritty_url_at(
            handle, Int32(point.line), point.column, nil, nil, 0
        )
        guard needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: needed)
        var range = KeroURLRange()
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            kero_alacritty_url_at(
                handle, Int32(point.line), point.column,
                &range, pointer.baseAddress, pointer.count
            )
        }
        guard written > 0, written <= buffer.count else { return nil }
        return URLHit(
            value: String(decoding: buffer[..<written], as: UTF8.self),
            startLine: Int(range.start_line),
            startColumn: Int(range.start_column),
            endLine: Int(range.end_line),
            endColumn: Int(range.end_column)
        )
    }

    // MARK: - Editing commands

    @objc func copy(_ sender: Any?) {
        guard handle != nil else { return }
        selectionRetryIntent.enqueue(.copySelection)
        _ = retrySelectionWork()
        scheduleSelectionRetry()
    }

    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let text = Self.pasteboardString(from: pasteboard) else {
            // Image-aware TUIs read the native pasteboard after Ctrl-V. The
            // renderer may not display their image protocol, but the paste
            // itself must still reach the app.
            if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
                write([0x16])
            }
            return
        }
        write(AlacrittyKeyMap.paste(text, mode: terminalMode))
    }

    override func selectAll(_ sender: Any?) {
        guard handle != nil else { return }
        selectionRetryIntent.enqueue(.selectAll)
        guard retrySelectionWork() else {
            scheduleSelectionRetry()
            return
        }
        scheduleRender(force: true)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selectionAvailability.allowsSelectionCommand
        case #selector(paste(_:)):
            Self.pasteboardString(from: .general) != nil
                || NSPasteboard.general.canReadObject(
                    forClasses: [NSImage.self], options: nil
                )
        default: true
        }
    }

    // MARK: - Context menu

    /// Kero reserves right-click for its terminal/pane menu, matching the
    /// Ghostty backend rather than AppKit's default text menu.
    override func rightMouseDown(with event: NSEvent) {
        focusForInteraction()
        NSMenu.popUpContextMenu(
            contextMenu(linkTarget: linkTarget(for: event)),
            with: event,
            for: self
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        focusForInteraction()
        return contextMenu(linkTarget: linkTarget(for: event))
    }

    private func linkTarget(for event: NSEvent) -> TerminalLinkTarget? {
        guard event.modifierFlags.contains(.command) else { return nil }
        guard let value = url(at: gridPoint(for: event))?.value else { return nil }
        return events?.terminalLinkTarget(for: value)
    }

    private func contextMenu(linkTarget: TerminalLinkTarget?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(contextItem(String(localized: "Copy"), #selector(copy(_:))))
        menu.addItem(contextItem(String(localized: "Paste"), #selector(paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem(String(localized: "Select All"), #selector(selectAll(_:))))
        if let linkTarget {
            menu.addItem(.separator())
            switch linkTarget {
            case .url(let url):
                for item in splitTarget.browserMenuItems(initialURL: url.absoluteString) {
                    menu.addItem(item)
                }
            case .file(let url):
                for item in splitTarget.fileMenuItems(path: url.path) {
                    menu.addItem(item)
                }
            }
        }
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
        return menu
    }

    private func contextItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - File drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender), !urls.isEmpty else { return false }
        focusForInteraction()
        let text = urls.map { AlacrittyTerminalView.shellToken(for: $0.path) }
            .joined(separator: " ")
        // A drop is semantically a paste, not simulated typing. Image-aware
        // TUIs such as Grok only inspect dropped paths when bracketed paste
        // identifies the complete payload as one event.
        write(AlacrittyKeyMap.paste(text + " ", mode: terminalMode))
        return true
    }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private static func shellToken(for path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func pasteboardString(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map { shellToken(for: $0.path) }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }

    override func isAccessibilityElement() -> Bool { isSurfaceVisible }

    override func isAccessibilityEnabled() -> Bool { isSurfaceVisible }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityRoleDescription() -> String? {
        NSAccessibility.Role.description(for: self)
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Terminal")
    }

    override func accessibilityHelp() -> String? {
        String(localized: "Type to enter terminal text.")
    }

    override func accessibilityValue() -> Any? { "" }

    override func setAccessibilityValue(_ value: Any?) {
        insertAccessibilityText(value)
    }

    override func accessibilityNumberOfCharacters() -> Int { 0 }

    override func accessibilitySelectedText() -> String? { "" }

    override func setAccessibilitySelectedText(_ text: String?) {
        insertAccessibilityText(text)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    override func isAccessibilityFocused() -> Bool {
        hasEffectiveTerminalFocus
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if !focused, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        } else if focused, isSurfaceVisible {
            window?.makeFirstResponder(self)
        }
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:))
            || selector == #selector(setAccessibilitySelectedText(_:)) {
            // Keep the setter discoverable while Kero is inactive, but never
            // advertise a parked or otherwise unfocused terminal as writable.
            return isSurfaceVisible && window?.firstResponder === self
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    /// A terminal is append-at-cursor rather than a document whose value can
    /// be replaced. Both editable AX insertion routes therefore feed the PTY,
    /// but only while this exact surface is the live text destination.
    private func insertAccessibilityText(_ value: Any?) {
        guard isSurfaceVisible, hasEffectiveTerminalFocus else { return }
        let text = (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        sendText(text)
    }
}

// MARK: - Text input

/// Enough of `NSTextInputClient` for IME: composition is shown inline at the
/// cursor and only committed text reaches the PTY.
extension AlacrittyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        write(Array(text.utf8))
        scheduleRender(force: true)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        scheduleRender(force: true)
    }

    func unmarkText() {
        markedText = ""
        scheduleRender(force: true)
    }

    func selectedRange() -> NSRange {
        // Insertion point with no selection. `NSNotFound` makes some IMEs
        // refuse to begin composition against this client.
        NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Places the IME candidate window under the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let cursor = cursorCache.imePosition else { return .zero }
        let column = CGFloat(cursor.column)
        let line = CGFloat(cursor.line)
        let local = NSRect(
            x: Self.padding.x + column * metrics.cellWidth,
            y: bounds.maxY - Self.padding.y - (line + 1) * metrics.cellHeight,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    override func doCommand(by selector: Selector) {
        // Key encoding is handled in `keyDown`; anything reaching here would
        // otherwise beep.
    }
}

// MARK: - Callback plumbing

/// Delivers PTY-thread callbacks to the right view without ever dereferencing
/// a view pointer off the main thread.
///
/// The context handed to Rust is an integer token, not a pointer, so a surface
/// released while the PTY thread still holds a reference resolves to nothing
/// instead of a dangling object.
final class AlacrittyRegistry: @unchecked Sendable {
    static let shared = AlacrittyRegistry()

    private let lock = NSLock()
    private var next: UInt64 = 1
    private var views: [UInt64: WeakView] = [:]

    private struct WeakView {
        weak var view: AlacrittyTerminalView?
    }

    func nextToken() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let token = next
        next += 1
        return token
    }

    func register(_ view: AlacrittyTerminalView, for token: UInt64) {
        lock.lock()
        views[token] = WeakView(view: view)
        lock.unlock()
    }

    func unregister(_ token: UInt64) {
        lock.lock()
        views.removeValue(forKey: token)
        lock.unlock()
        AlacrittyWakeupGate.shared.release(token: token)
    }

    fileprivate func view(for token: UInt64) -> AlacrittyTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return views[token]?.view
    }

    fileprivate func deliver(token: UInt64, kind: UInt32, payload: Data) {
        view(for: token)?.handleEvent(kind: kind, payload: payload)
    }

}

/// Coalesces PTY wakeups before they reach the main queue. This state is
/// deliberately nonisolated: Rust invokes the callback from its worker, and
/// the lock is the synchronization boundary for both callback and teardown.
private nonisolated final class AlacrittyWakeupGate: @unchecked Sendable {
    static let shared = AlacrittyWakeupGate()

    private let lock = NSLock()
    private var queuedTokens: Set<UInt64> = []

    func claim(token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return queuedTokens.insert(token).inserted
    }

    func release(token: UInt64) {
        lock.lock()
        queuedTokens.remove(token)
        lock.unlock()
    }
}

/// Owns the blocking part of backend teardown. The Rust free function joins
/// its PTY worker, so doing that from MainActor can stall pane removal while a
/// shell is unwinding. The opaque pointer crosses the task boundary as an
/// integer; the view clears its handle before scheduling this exactly once.
enum AlacrittyHandleRelease {
    @discardableResult
    nonisolated static func schedule(
        rawValue: UInt,
        free: @escaping @Sendable (UInt) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            free(rawValue)
        }
    }

    @discardableResult
    nonisolated static func schedule(
        handle: OpaquePointer
    ) -> Task<Void, Never> {
        schedule(rawValue: UInt(bitPattern: handle)) { rawValue in
            guard let handle = OpaquePointer(bitPattern: rawValue) else { return }
            kero_alacritty_free(handle)
        }
    }
}

/// Called on the PTY thread by the Rust bridge.
private nonisolated func alacrittyEventCallback(
    context: UnsafeMutableRawPointer?,
    kind: UInt32,
    data: UnsafePointer<UInt8>?,
    length: Int
) {
    let token = UInt64(UInt(bitPattern: context))
    guard token != 0 else { return }
    if kind == KERO_EVENT_WAKEUP {
        guard AlacrittyWakeupGate.shared.claim(token: token) else { return }
        DispatchQueue.main.async {
            AlacrittyWakeupGate.shared.release(token: token)
            AlacrittyRegistry.shared.deliver(token: token, kind: kind, payload: Data())
        }
        return
    }
    // Copied here: the buffer belongs to Rust and does not outlive this call.
    let payload = (data != nil && length > 0) ? Data(bytes: data!, count: length) : Data()
    DispatchQueue.main.async {
        AlacrittyRegistry.shared.deliver(token: token, kind: kind, payload: payload)
    }
}

/// CADisplayLink retains its target. The proxy keeps that reference off the
/// view so `stopDisplayLink()` can break the cycle.
private final class AlacrittyDisplayLinkProxy: NSObject {
    private weak var view: AlacrittyTerminalView?

    init(view: AlacrittyTerminalView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        assumeMainActor { view?.displayLinkDidFire() }
    }
}

// MARK: - Configuration bridging

extension TerminalLaunch {
    /// Builds a `KeroConfig` whose C strings stay alive for the call. Cargo's
    /// side copies everything it needs before returning.
    func withCConfig<T>(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt16,
        cellHeight: UInt16,
        scrollbackLines: Int,
        cursorShape: UInt8,
        cursorBlinking: Bool,
        _ body: (UnsafePointer<KeroConfig>) -> T
    ) -> T {
        let programCopy = strdup(program)
        let directoryCopy = strdup(workingDirectory)
        let argumentCopies = arguments.map { strdup($0) }
        let environmentCopies = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            free(programCopy)
            free(directoryCopy)
            argumentCopies.forEach { free($0) }
            environmentCopies.forEach { free($0) }
        }

        var argumentPointers = argumentCopies.map { UnsafePointer($0) }
        var environmentPointers = environmentCopies.map { UnsafePointer($0) }

        return argumentPointers.withUnsafeMutableBufferPointer { argv in
            environmentPointers.withUnsafeMutableBufferPointer { envp in
                var config = KeroConfig(
                    shell: programCopy,
                    args: argv.baseAddress,
                    args_len: argv.count,
                    working_directory: directoryCopy,
                    env: envp.baseAddress,
                    env_len: envp.count,
                    columns: columns,
                    rows: rows,
                    cell_width: cellWidth,
                    cell_height: cellHeight,
                    scrollback_lines: scrollbackLines,
                    cursor_shape: cursorShape,
                    cursor_blinking: cursorBlinking
                )
                return withUnsafePointer(to: &config) { body($0) }
            }
        }
    }
}

// MARK: - Theme bridging

enum AlacrittyTheme {
    /// Kero's active terminal theme in the flat form the bridge resolves
    /// colors against, so Alacritty panes match Ghostty panes exactly.
    static func current() -> KeroTheme {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let definition = Theme.terminal(dark: isDark)

        var theme = KeroTheme()
        withUnsafeMutableBytes(of: &theme.palette) { raw in
            let palette = raw.bindMemory(to: UInt32.self)
            for index in 0..<256 {
                palette[index] = definition.palette[index].flatMap(packed(hex:))
                    ?? defaultPalette(index)
            }
        }
        theme.foreground = packed(color: definition.foregroundNSColor)
        theme.background = packed(color: definition.backgroundNSColor)
        theme.cursor = packed(color: definition.cursorNSColor)
        return theme
    }

    /// The xterm 256-color palette: 16 ANSI colors, a 6×6×6 cube, then a
    /// 24-step ramp. Only used where a theme leaves an index undefined.
    private nonisolated static func defaultPalette(_ index: Int) -> UInt32 {
        switch index {
        case 0..<16:
            let base: [UInt32] = [
                0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
                0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
            ]
            return base[index]
        case 16..<232:
            let value = index - 16
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            let red = steps[(value / 36) % 6]
            let green = steps[(value / 6) % 6]
            let blue = steps[value % 6]
            return (red << 16) | (green << 8) | blue
        default:
            let level = UInt32(8 + (index - 232) * 10)
            return (level << 16) | (level << 8) | level
        }
    }

    private nonisolated static func packed(hex: String) -> UInt32? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return value
    }

    private static func packed(color: NSColor) -> UInt32 {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let red = UInt32((srgb.redComponent * 255).rounded())
        let green = UInt32((srgb.greenComponent * 255).rounded())
        let blue = UInt32((srgb.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }
}
