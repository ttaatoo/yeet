//
//  WorkspaceInspectorHost.swift
//  kero
//

import AppKit
import SwiftUI

/// AppKit container for the Files / Git / Info inspector. The panels themselves
/// remain SwiftUI (hosted) so this pass does not rewrite the git form; the
/// chrome around them is an NSView so hide/show and width are not a SwiftUI
/// layout pass on the whole window.
final class WorkspaceInspectorView: NSView {
    private let hostingView: NSView

    init(hostingView: NSView) {
        self.hostingView = hostingView
        super.init(frame: .zero)
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

struct WorkspaceInspectorHost<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> WorkspaceInspectorView {
        let host = NSHostingView(rootView: content())
        host.safeAreaRegions = []
        return WorkspaceInspectorView(hostingView: host)
    }

    func updateNSView(_ nsView: WorkspaceInspectorView, context: Context) {
        guard let host = nsView.subviews.first as? NSHostingView<Content> else { return }
        host.rootView = content()
        nsView.layer?.backgroundColor = Theme.sidebar.cgColor
    }
}
