//
//  MarkdownPreview.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// A read-only rendered markdown file. Source editing stays on `FileTab`;
/// this object only holds the path, the last render, and heading anchors
/// for in-document `#fragment` jumps.
@MainActor
final class MarkdownPreviewTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    @Published private(set) var path: String
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var reloadRevision: UInt = 0
    /// Raw markdown, when the file was readable. Tab-switcher thumbnails
    /// sample this; rendering always goes through `rendered`.
    @Published private(set) var sourceText = ""
    @Published private(set) var rendered = NSAttributedString()
    @Published private(set) var headingAnchors: [MarkdownHeadingAnchor] = []
    @Published private(set) var pendingHeading: String?

    /// The mounted AppKit surface, for drag thumbnails. Weak — owned by
    /// the representable, nils when the pane unmounts.
    weak var surfaceView: MarkdownPreviewPaneView?

    var onOpenSource: (() -> Void)?
    var onOpenLink: ((String) -> Void)?

    private var lastStyledDark: Bool?
    private var reloadGeneration: UInt = 0
    private var reloadTask: Task<Void, Never>?

    private nonisolated static let maxBytes = 5 << 20

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    init(path: String) {
        self.path = MarkdownPreviewRouting.standardizedPath(path)
        Task { [weak self] in
            await self?.reloadFromDisk()
        }
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var fileURL: URL {
        URL(fileURLWithPath: path)
    }

    func updatePath(_ newPath: String) {
        let standardized = MarkdownPreviewRouting.standardizedPath(newPath)
        guard standardized != path else { return }
        path = standardized
    }

    func revealHeading(_ raw: String) {
        let slug = MarkdownPreviewRouting.normalizeHeading(raw)
        guard !slug.isEmpty else { return }
        pendingHeading = slug
    }

    func consumePendingHeading() -> String? {
        let heading = pendingHeading
        pendingHeading = nil
        return heading
    }

    func openSource() {
        onOpenSource?()
    }

    func openLink(_ href: String) {
        onOpenLink?(href)
    }

    func ensureStyled(dark: Bool) {
        guard lastStyledDark != dark, case .ready = loadState else {
            lastStyledDark = dark
            return
        }
        lastStyledDark = dark
        applyRender(MarkdownPreviewRenderer.render(
            source: sourceText,
            fileURL: fileURL,
            dark: dark
        ))
        reloadRevision &+= 1
    }

    /// Re-read from disk. Used on first open and when the pane returns to
    /// the screen; live-watching the file is not required.
    func reloadFromDisk() async {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let expectedPath = path
        let dark = lastStyledDark ?? true

        let loaded = await Task.detached(priority: .userInitiated) {
            Self.read(path: expectedPath)
        }.value
        guard !Task.isCancelled, reloadGeneration == generation, path == expectedPath
        else { return }

        switch loaded {
        case .failed(let message):
            sourceText = ""
            rendered = NSAttributedString()
            headingAnchors = []
            loadState = .failed(message)
            reloadRevision &+= 1
        case .contents(let source):
            sourceText = source
            lastStyledDark = dark
            applyRender(MarkdownPreviewRenderer.render(
                source: source,
                fileURL: URL(fileURLWithPath: expectedPath),
                dark: dark
            ))
            loadState = .ready
            reloadRevision &+= 1
        }
    }

    private func applyRender(_ result: MarkdownPreviewRenderer.Result) {
        rendered = result.attributed
        headingAnchors = result.headings
    }

    private nonisolated enum DiskLoad: Sendable {
        case contents(String)
        case failed(String)
    }

    private nonisolated static func read(path: String) -> DiskLoad {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else {
            return .failed(String(localized: "Could not read file"))
        }
        if isDirectory.boolValue {
            return .failed(String(localized: "Could not read file"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failed(String(localized: "Could not read file"))
        }
        guard data.count <= maxBytes else {
            return .failed(String(localized: "File is too large to open"))
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return .failed(String(localized: "Binary file"))
        }
        return .contents(string)
    }
}

nonisolated struct MarkdownHeadingAnchor: Equatable {
    let slug: String
    let range: NSRange
}

/// Foundation markdown → themed `NSAttributedString`. Not WKWebView: the
/// preview has to stay an AppKit document the rest of the pane chrome can
/// snapshot and focus.
nonisolated enum MarkdownPreviewRenderer {
    struct Result {
        var attributed: NSAttributedString
        var headings: [MarkdownHeadingAnchor]
    }

    nonisolated static func render(
        source: String,
        fileURL: URL,
        dark: Bool
    ) -> Result {
        let theme = Theme.terminal(dark: dark)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        options.allowsExtendedAttributes = true

        let parsed: AttributedString
        do {
            parsed = try AttributedString(
                markdown: source,
                options: options,
                baseURL: fileURL
            )
        } catch {
            parsed = AttributedString(source)
        }

        let headings = collectHeadings(from: parsed)
        let styled = style(parsed, theme: theme)
        return Result(attributed: styled, headings: headings)
    }

    private nonisolated static func collectHeadings(
        from attributed: AttributedString
    ) -> [MarkdownHeadingAnchor] {
        var headings: [MarkdownHeadingAnchor] = []
        var seenIdentities = Set<Int>()
        var slugCounts: [String: Int] = [:]

        for run in attributed.runs {
            guard let intent = run.presentationIntent else { continue }
            var headerIdentity: Int?
            for component in intent.components {
                if case .header = component.kind {
                    headerIdentity = component.identity
                    break
                }
            }
            guard let identity = headerIdentity, seenIdentities.insert(identity).inserted
            else { continue }

            let nsRange = NSRange(run.range, in: attributed)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
            let text = String(attributed[run.range].characters)
            let base = MarkdownPreviewRouting.headingSlug(text)
            guard !base.isEmpty else { continue }
            let count = slugCounts[base, default: 0]
            slugCounts[base] = count + 1
            let slug = count == 0 ? base : "\(base)-\(count)"
            headings.append(MarkdownHeadingAnchor(slug: slug, range: nsRange))
        }
        return headings
    }

    private nonisolated static func style(
        _ attributed: AttributedString,
        theme: TerminalThemeDefinition
    ) -> NSAttributedString {
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: ns.length)
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let foreground = theme.foregroundNSColor
        let inlineCodeFill = theme.surfaceNSColor(elevation: 0.10)
        let blockFill = theme.surfaceNSColor(elevation: 0.14)
        let quoteColor = foreground.withAlphaComponent(0.72)
        let linkColor = theme.palette[4].map(hexColor) ?? theme.accentNSColor

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 3
        bodyStyle.paragraphSpacing = 8

        if full.length > 0 {
            ns.addAttribute(.foregroundColor, value: foreground, range: full)
            ns.addAttribute(.font, value: bodyFont, range: full)
            ns.addAttribute(.paragraphStyle, value: bodyStyle, range: full)
        }

        for run in attributed.runs {
            let range = NSRange(run.range, in: attributed)
            guard range.location != NSNotFound, range.length > 0,
                  range.location + range.length <= ns.length
            else { continue }

            if run.link != nil {
                ns.addAttribute(.foregroundColor, value: linkColor, range: range)
                ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }

            if let inline = run.inlinePresentationIntent {
                var font = bodyFont
                if inline.contains(.code) {
                    font = mono
                    ns.addAttribute(.backgroundColor, value: inlineCodeFill, range: range)
                    ns.addAttribute(.foregroundColor, value: foreground, range: range)
                }
                var traits = font.fontDescriptor.symbolicTraits
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                ns.addAttribute(.font, value: font, range: range)
            }

            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let size: CGFloat = switch level {
                        case 1: 24
                        case 2: 20
                        case 3: 17
                        default: 15
                        }
                        ns.addAttribute(
                            .font,
                            value: NSFont.systemFont(ofSize: size, weight: .semibold),
                            range: range
                        )
                    case .codeBlock:
                        ns.addAttribute(.font, value: mono, range: range)
                        ns.addAttribute(.backgroundColor, value: blockFill, range: range)
                    case .blockQuote:
                        ns.addAttribute(.foregroundColor, value: quoteColor, range: range)
                    default:
                        break
                    }
                }
            }
        }

        return ns
    }

    private nonisolated static func hexColor(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return .magenta
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }
}

/// AppKit preview surface: a one-line Open Source bar and a read-only
/// `NSTextView`. Hosted from SwiftUI through `MarkdownPreviewHostView`
/// the same way the terminal surface is hosted — the document itself is
/// not a SwiftUI layout.
final class MarkdownPreviewPaneView: NSView, NSTextViewDelegate {
    var onOpenSource: (() -> Void)?
    var onOpenLink: ((String) -> Void)?
    var onFocused: (() -> Void)?

    private let toolbar = NSView()
    private let openSourceButton = NSButton(title: "", target: nil, action: nil)
    private let divider = NSView()
    private let scrollView = NSScrollView()
    private let textView = MarkdownPreviewTextView()
    private let errorLabel = NSTextField(labelWithString: "")

    private var appliedRevision: UInt = .max
    private var appliedHeading: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = Theme.background.cgColor

        openSourceButton.translatesAutoresizingMaskIntoConstraints = false
        openSourceButton.title = String(localized: "Open Source")
        openSourceButton.bezelStyle = .flexiblePush
        openSourceButton.controlSize = .small
        openSourceButton.target = self
        openSourceButton.action = #selector(openSourceClicked)
        openSourceButton.setAccessibilityLabel(String(localized: "Open Source"))

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor

        textView.isEditable = false
        textView.isRichText = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.textColor = Theme.terminal(dark: true).foregroundNSColor
        textView.textContainerInset = NSSize(width: 28, height: 22)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.usesFindBar = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel(String(localized: "Markdown Preview"))
        textView.delegate = self
        textView.onBecomeFirstResponder = { [weak self] in
            self?.onFocused?()
        }
        textView.openSourceHandler = { [weak self] in
            self?.onOpenSource?()
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.documentView = textView

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = NSColor.secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true

        addSubview(toolbar)
        toolbar.addSubview(openSourceButton)
        addSubview(divider)
        addSubview(scrollView)
        addSubview(errorLabel)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),

            openSourceButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            openSourceButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    override func layout() {
        super.layout()
        let width = scrollView.contentSize.width
        textView.minSize = NSSize(width: width, height: 0)
        textView.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, width),
            height: .greatestFiniteMagnitude
        )
        textView.frame.size.width = width
    }

    func apply(_ preview: MarkdownPreviewTab) {
        applyChrome()
        guard appliedRevision != preview.reloadRevision else {
            if let heading = preview.pendingHeading {
                reveal(heading, in: preview)
            }
            return
        }
        appliedRevision = preview.reloadRevision
        appliedHeading = nil
        switch preview.loadState {
        case .loading:
            showError(String(localized: "Opening…"))
        case .failed(let message):
            showError(message)
        case .ready:
            showDocument(preview.rendered)
            if let heading = preview.pendingHeading {
                reveal(heading, in: preview)
            }
        }
    }

    private func applyChrome() {
        let background = Theme.background
        layer?.backgroundColor = background.cgColor
        toolbar.layer?.backgroundColor = background.cgColor
        divider.layer?.backgroundColor = Theme.divider.cgColor
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.linkTextAttributes = [
            .foregroundColor: Theme.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        textView.string = ""
        scrollView.isHidden = false
    }

    private func showDocument(_ attributed: NSAttributedString) {
        errorLabel.isHidden = true
        textView.textStorage?.setAttributedString(attributed)
    }

    private func reveal(_ heading: String, in preview: MarkdownPreviewTab) {
        guard appliedHeading != heading else { return }
        let slug = MarkdownPreviewRouting.normalizeHeading(heading)
        guard let anchor = preview.headingAnchors.first(where: { $0.slug == slug })
        else { return }
        appliedHeading = heading
        _ = preview.consumePendingHeading()
        DispatchQueue.main.async { [weak self] in
            self?.textView.scrollRangeToVisible(anchor.range)
        }
    }

    @objc private func openSourceClicked() {
        onOpenSource?()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let href: String
        if let url = link as? URL {
            href = url.absoluteString
        } else if let string = link as? String {
            href = string
        } else {
            return false
        }
        onOpenLink?(href)
        return true
    }
}

private final class MarkdownPreviewTextView: NSTextView {
    var onBecomeFirstResponder: (() -> Void)?
    var openSourceHandler: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let openSource = NSMenuItem(
            title: String(localized: "Open Source"),
            action: #selector(openSourceFromMenu),
            keyEquivalent: ""
        )
        openSource.target = self
        menu.addItem(openSource)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func openSourceFromMenu() {
        openSourceHandler?()
    }
}

struct MarkdownPreviewHostView: NSViewRepresentable {
    @ObservedObject var preview: MarkdownPreviewTab
    var isFocused: Bool = true
    var onFocused: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkdownPreviewPaneView {
        let view = MarkdownPreviewPaneView()
        preview.surfaceView = view
        bind(view)
        context.coordinator.isFocused = isFocused
        return view
    }

    func updateNSView(_ view: MarkdownPreviewPaneView, context: Context) {
        preview.surfaceView = view
        bind(view)
        preview.ensureStyled(dark: colorScheme == .dark)
        view.apply(preview)
        if isFocused, !context.coordinator.isFocused {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
        context.coordinator.isFocused = isFocused
    }

    static func dismantleNSView(_ view: MarkdownPreviewPaneView, coordinator: Coordinator) {
        view.onOpenSource = nil
        view.onOpenLink = nil
        view.onFocused = nil
    }

    private func bind(_ view: MarkdownPreviewPaneView) {
        view.onOpenSource = { [weak preview] in preview?.openSource() }
        view.onOpenLink = { [weak preview] href in preview?.openLink(href) }
        view.onFocused = onFocused
    }

    final class Coordinator {
        var isFocused = false
    }
}
