//
//  ChatPaneView.swift
//  kero
//

import AppKit
import SwiftUI

struct ChatHostView: NSViewRepresentable {
    @ObservedObject var tab: ChatTab
    var isFocused: Bool = true
    var onFocused: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ChatPaneNSView {
        let view = ChatPaneNSView(tab: tab)
        view.onFocused = onFocused
        context.coordinator.wasFocused = isFocused
        return view
    }

    func updateNSView(_ view: ChatPaneNSView, context: Context) {
        view.onFocused = onFocused
        view.reload(tab: tab)
        tab.appear()
        if isFocused, !context.coordinator.wasFocused {
            view.window?.makeFirstResponder(view.preferredFirstResponder)
        }
        context.coordinator.wasFocused = isFocused
    }

    final class Coordinator {
        var wasFocused = false
    }
}

final class ChatPaneNSView: NSView {
    var onFocused: () -> Void = {}
    private(set) var preferredFirstResponder: NSView
    private weak var tab: ChatTab?

    private let scroll = NSScrollView()
    private let document = NSView()
    private let composer = NSTextView()
    private let composerScroll = NSScrollView()
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var rowViews: [NSView] = []
    private var lastItemIDs: [String] = []
    private var lastPhase: ChatTab.Phase?

    override var isFlipped: Bool { true }

    init(tab: ChatTab) {
        self.tab = tab
        self.preferredFirstResponder = composer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.wantsLayer = true
        addSubview(scroll)

        composer.isRichText = false
        composer.font = .systemFont(ofSize: NSFont.systemFontSize)
        composer.textContainerInset = NSSize(width: 6, height: 6)
        composer.backgroundColor = Theme.background
        composer.textColor = Theme.chromePrimaryText
        composer.delegate = contextKeeper
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.documentView = composer
        composer.minSize = NSSize(width: 0, height: 36)
        composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.textContainer?.widthTracksTextView = true
        addSubview(composerScroll)

        sendButton.bezelStyle = .flexiblePush
        sendButton.controlSize = .small
        sendButton.target = self
        sendButton.action = #selector(sendOrStop)
        addSubview(sendButton)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        reload(tab: tab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private lazy var contextKeeper = ChatComposerDelegate(owner: self)

    func reload(tab: ChatTab) {
        self.tab = tab
        let itemIDs = tab.items.map(\.id)
        if itemIDs != lastItemIDs || tab.phase != lastPhase {
            lastItemIDs = itemIDs
            lastPhase = tab.phase
            rebuildDocument(tab: tab)
        }
        if composer.string != tab.draft, composer.window?.firstResponder !== composer {
            composer.string = tab.draft
        }
        switch tab.phase {
        case .running:
            sendButton.title = String(localized: "Stop")
            statusLabel.stringValue = String(localized: "Supervised")
        case .needsLogin:
            sendButton.title = String(localized: "Send")
            statusLabel.stringValue = loginHint(for: tab)
        case .missingBinary:
            sendButton.title = String(localized: "Send")
            statusLabel.stringValue = missingHint(for: tab)
        case .error(let message):
            sendButton.title = String(localized: "Send")
            statusLabel.stringValue = message
        case .idle:
            sendButton.title = String(localized: "Send")
            statusLabel.stringValue = String(localized: "Supervised")
        }
        sendButton.isEnabled = tab.phase != .missingBinary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let composerHeight: CGFloat = 72
        let buttonWidth: CGFloat = 72
        let statusHeight: CGFloat = 18
        let padding: CGFloat = 8
        let bottom = bounds.height - padding
        sendButton.frame = NSRect(
            x: bounds.width - padding - buttonWidth,
            y: bottom - composerHeight,
            width: buttonWidth,
            height: 28
        )
        composerScroll.frame = NSRect(
            x: padding,
            y: bottom - composerHeight,
            width: bounds.width - padding * 3 - buttonWidth,
            height: composerHeight
        )
        statusLabel.frame = NSRect(
            x: padding,
            y: composerScroll.frame.minY - statusHeight - 4,
            width: bounds.width - padding * 2,
            height: statusHeight
        )
        scroll.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(0, statusLabel.frame.minY - 4)
        )
        layoutDocument()
    }

    override func mouseDown(with event: NSEvent) {
        onFocused()
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocused()
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "\r" {
            sendOrStop()
            return
        }
        super.keyDown(with: event)
    }

    @objc func sendFromComposer() {
        sendOrStop()
    }

    @objc private func sendOrStop() {
        guard let tab else { return }
        onFocused()
        if tab.phase == .running {
            tab.interrupt()
            return
        }
        tab.draft = composer.string
        Task { await tab.send(composer.string) }
    }

    @objc private func bindProvider(_ sender: NSButton) {
        guard let tab,
              let raw = sender.identifier?.rawValue,
              let kind = KeroAgentKind(rawValue: raw)
        else { return }
        Task { await tab.bind(kind) }
    }

    private func loginHint(for tab: ChatTab) -> String {
        switch tab.provider {
        case KeroAgentKind.claude.rawValue:
            return String(localized: "Run `claude auth login` in a terminal, then send again.")
        case KeroAgentKind.grok.rawValue:
            return String(localized: "Run `grok login` in a terminal, then send again.")
        default:
            return String(localized: "Run `codex login` in a terminal, then send again.")
        }
    }

    private func missingHint(for tab: ChatTab) -> String {
        if let provider = tab.provider, let kind = KeroAgentKind(rawValue: provider) {
            return ChatProviderProbe.installHint(for: kind)
        }
        return String(localized: "That CLI is not on PATH. Install it, then reopen this pane.")
    }

    private func rebuildDocument(tab: ChatTab) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        if tab.items.isEmpty, tab.provider == nil {
            rowViews.append(contentsOf: emptyStateRows(tab: tab))
        } else {
            for item in tab.items {
                rowViews.append(row(for: item, tab: tab))
            }
        }
        for view in rowViews {
            document.addSubview(view)
        }
        layoutDocument()
    }

    private func emptyStateRows(tab: ChatTab) -> [NSView] {
        var views: [NSView] = []
        let title = NSTextField(labelWithString: String(localized: "Chat"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = Theme.chromePrimaryText
        views.append(title)
        let body = NSTextField(wrappingLabelWithString: String(
            localized: "Chat talks to a CLI already on this Mac. Yeet does not hold an API key."
        ))
        body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        body.textColor = .secondaryLabelColor
        views.append(body)
        for provider in tab.providers where provider.isSupported {
            if provider.resolvedPath == nil {
                let missing = NSTextField(wrappingLabelWithString: "\(provider.displayName): \(provider.installHint)")
                missing.textColor = .secondaryLabelColor
                views.append(missing)
            } else {
                let button = NSButton(
                    title: provider.displayName,
                    target: self,
                    action: #selector(bindProvider(_:))
                )
                button.bezelStyle = .flexiblePush
                button.identifier = NSUserInterfaceItemIdentifier(provider.kind.rawValue)
                views.append(button)
            }
        }
        for provider in tab.providers where !provider.isSupported {
            let grey = NSTextField(labelWithString: String(
                localized: "\(provider.displayName) (later)"
            ))
            grey.textColor = .tertiaryLabelColor
            views.append(grey)
        }
        return views
    }

    private func row(for item: ChatTimelineItem, tab: ChatTab) -> NSView {
        switch item {
        case .user(_, let text):
            return bubble(text, role: String(localized: "You"))
        case .assistant(_, let text):
            return bubble(text, role: tab.title)
        case .reasoning(_, let summary, _):
            return bubble(summary, role: String(localized: "Thinking"))
        case .tool(_, let path, let added, let removed, _):
            let button = NSButton(
                title: "Edit \(path) +\(added) −\(removed)",
                target: self,
                action: #selector(openPath(_:))
            )
            button.bezelStyle = .inline
            button.identifier = NSUserInterfaceItemIdentifier(path)
            return button
        case .command(_, let command, let exitCode, let durationMs, let outputPreview, let expanded):
            let exit = exitCode.map(String.init) ?? "…"
            let duration = durationMs.map { "\($0)ms" } ?? ""
            let text = expanded
                ? "\(command)  exit \(exit) \(duration)\n\(outputPreview)"
                : "\(command)  exit \(exit) \(duration)"
            return bubble(text, role: String(localized: "Command"))
        case .turnFiles(_, let files):
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            for file in files {
                let button = NSButton(
                    title: "\(file.path) +\(file.added) −\(file.removed)",
                    target: self,
                    action: #selector(openPath(_:))
                )
                button.bezelStyle = .inline
                button.identifier = NSUserInterfaceItemIdentifier(file.path)
                stack.addArrangedSubview(button)
            }
            return stack
        case .approval(let id, _, _, let title, let detail):
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.addArrangedSubview(bubble("\(title)\n\(detail)", role: String(localized: "Approval")))
            let allow = NSButton(title: String(localized: "Allow"), target: self, action: #selector(allowApproval(_:)))
            let deny = NSButton(title: String(localized: "Deny"), target: self, action: #selector(denyApproval(_:)))
            allow.identifier = NSUserInterfaceItemIdentifier(id)
            deny.identifier = NSUserInterfaceItemIdentifier(id)
            allow.bezelStyle = .flexiblePush
            deny.bezelStyle = .flexiblePush
            let row = NSStackView(views: [allow, deny])
            row.orientation = .horizontal
            stack.addArrangedSubview(row)
            return stack
        case .error(_, let message):
            return bubble(message, role: String(localized: "Error"))
        case .turnFinished:
            return NSView()
        }
    }

    private func bubble(_ text: String, role: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let roleLabel = NSTextField(labelWithString: role)
        roleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        roleLabel.textColor = Theme.accent
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: NSFont.systemFontSize)
        body.textColor = Theme.chromePrimaryText
        stack.addArrangedSubview(roleLabel)
        stack.addArrangedSubview(body)
        return stack
    }

    private func layoutDocument() {
        var y: CGFloat = 12
        let width = max(scroll.contentSize.width - 24, 120)
        for view in rowViews {
            let height = view.fittingSize.height
            view.frame = NSRect(x: 12, y: y, width: width, height: max(height, 24))
            y += view.frame.height + 10
        }
        document.frame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, 1), height: max(y, scroll.contentSize.height))
    }

    @objc private func openPath(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !path.isEmpty else { return }
        NotificationCenter.default.post(
            name: .yeetChatRevealPath,
            object: tab,
            userInfo: ["path": path]
        )
    }

    @objc private func allowApproval(_ sender: NSButton) {
        respond(sender, decision: .accept)
    }

    @objc private func denyApproval(_ sender: NSButton) {
        respond(sender, decision: .decline)
    }

    private func respond(_ sender: NSButton, decision: ChatApprovalDecision) {
        guard let tab, let id = sender.identifier?.rawValue,
              let item = tab.items.first(where: { $0.id == id })
        else { return }
        tab.respond(to: item, decision: decision)
        reload(tab: tab)
    }
}

extension Notification.Name {
    static let yeetChatRevealPath = Notification.Name("yeetChatRevealPath")
}

private final class ChatComposerDelegate: NSObject, NSTextViewDelegate {
    weak var owner: ChatPaneNSView?

    init(owner: ChatPaneNSView) {
        self.owner = owner
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        // Draft is read back on send; keep the model in sync for snapshots later.
        _ = view.string
    }

    func textView(
        _ textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            owner?.sendFromComposer()
            return true
        }
        return false
    }
}
