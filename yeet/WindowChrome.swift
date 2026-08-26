//
//  WindowChrome.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Keeps the traffic-light buttons aligned with the app's 38pt header bar:
/// 20pt leading, vertically centered on the header's center line. AppKit
/// re-lays the buttons out on various events, so we re-apply after each.
struct WindowChromeAccessor: NSViewRepresentable {
    static let buttonCenterY: CGFloat = 21
    static let buttonLeading: CGFloat = 16
    static let buttonSpacing: CGFloat = 20

    private let onAttach: (NSWindow) -> Void

    init(onAttach: @escaping (NSWindow) -> Void = { _ in }) {
        self.onAttach = onAttach
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttach: onAttach)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window {
            context.coordinator.attachIfNeeded(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var themeObservation: AnyCancellable?
        private let onAttach: (NSWindow) -> Void
        private var attachQueued = false

        init(onAttach: @escaping (NSWindow) -> Void) {
            self.onAttach = onAttach
        }

        /// `updateNSView` runs inside a SwiftUI pass. Queue the first attach
        /// so `TerminalManager.attach` cannot publish during that pass.
        func attachIfNeeded(_ window: NSWindow) {
            guard self.window !== window, !attachQueued else { return }
            attachQueued = true
            afterViewUpdate { [weak self] in
                guard let self else { return }
                self.attachQueued = false
                self.attach(window)
            }
        }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            onAttach(window)
            // Interactive controls occupy the title-bar region. Disable the
            // server-side title-bar drag entirely; WindowDragArea is the only
            // surface that opts into moving the window.
            window.isMovable = false
            fillWindowCorners(window)
            themeObservation = Theme.observeChanges { [weak self] in
                guard let self, let window = self.window else { return }
                self.fillWindowCorners(window)
            }
            reposition()
            // The initial system layout can land after us; catch up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reposition() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reposition() }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reposition()
                    }
                })
            }
        }

        /// Tahoe draws an accent rim around hidden-titlebar windows. A
        /// transparent fill lets chromeProgress (mint) leak at the rounded
        /// corners where that rim does not cover the square content bounds.
        private func fillWindowCorners(_ window: NSWindow) {
            window.backgroundColor = Theme.sidebar
            window.isOpaque = true
        }

        private func reposition() {
            guard let window else { return }
            window.isMovable = false
            fillWindowCorners(window)
            guard !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview
                else { continue }
                let centerInWindow = NSPoint(
                    x: WindowChromeAccessor.buttonLeading + CGFloat(index) * WindowChromeAccessor.buttonSpacing + button.frame.width / 2,
                    y: window.frame.height - WindowChromeAccessor.buttonCenterY
                )
                let center = superview.convert(centerInWindow, from: nil)
                let origin = NSPoint(
                    x: center.x - button.frame.width / 2,
                    y: center.y - button.frame.height / 2
                )
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// A deliberate window-moving surface. Interactive header controls are kept
/// outside this view so their own drag gestures receive the full mouse stream.
///
/// Double-clicking runs the standard title-bar action (zoom / minimize per
/// System Settings) — behavior our non-movable, hidden title bar would
/// otherwise lose. The tap is simultaneous with the drag: a stationary
/// double-click never registers a move, so the two don't conflict.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                NSApp.keyWindow?.performTitlebarDoubleClickAction()
            })
            .allowsWindowActivationEvents()
    }
}

extension NSWindow {
    /// Mirrors what a standard title bar does on double-click, honoring the
    /// "Double-click a window's title bar to" setting in System Settings.
    /// The global default is absent when set to Zoom, which is the default.
    func performTitlebarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default: // "Maximize" or unset
            performZoom(nil)
        }
    }
}

/// Intercepts the traffic-light close (and `performClose:`) so unsaved file
/// buffers can cancel the close. SwiftUI's WindowGroup already has a
/// delegate; we sit in front and forward everything else.
@MainActor
final class WorkspaceWindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var manager: TerminalManager?
    private weak var forwarding: NSWindowDelegate?
    private var isConfirming = false

    func install(on window: NSWindow, manager: TerminalManager) {
        self.manager = manager
        if window.delegate === self { return }
        if let existing = window.delegate, existing !== self {
            forwarding = existing
        }
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if manager?.consumeApprovedWindowClose() == true {
            return forwarding?.windowShouldClose?(sender) ?? true
        }
        guard manager?.hasDirtyBuffers == true else {
            return forwarding?.windowShouldClose?(sender) ?? true
        }
        if isConfirming { return false }
        isConfirming = true
        Task { @MainActor [weak self] in
            defer { self?.isConfirming = false }
            await self?.manager?.handleWindowCloseRequest()
        }
        return false
    }

    override func responds(to aSelector: Selector) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwarding?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector) -> Any? {
        forwarding
    }
}
