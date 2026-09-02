//
//  AppKitInspectorChrome.swift
//  yeet
//

import AppKit
import SwiftUI

enum InspectorMetrics {
    static let defaultWidth: Double = 240
    static let widthRange: ClosedRange<Double> = 180...500
    static let chromeHeight: CGFloat = 38
    static let dividerWidth: CGFloat = 1
    static let handleWidth: CGFloat = 7
}

/// Tab pills along the inspector chrome. Display rules live here so tests
/// can assert selection without mounting the Files/Git panels.
struct InspectorTabDisplayState: Equatable {
    let panel: RightPanel
    let title: String
    let help: String
    let systemImage: String
    let isSelected: Bool

    var accessibilityValue: String {
        isSelected ? String(localized: "Selected") : String(localized: "Not selected")
    }

    static func all(selected: RightPanel) -> [InspectorTabDisplayState] {
        RightPanel.allCases.map { panel in
            InspectorTabDisplayState(
                panel: panel,
                title: panel.title,
                help: panel.help,
                systemImage: panel.systemImage,
                isSelected: panel == selected
            )
        }
    }
}

extension RightPanel: CaseIterable {
    static var allCases: [RightPanel] { [.info, .files, .git] }

    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .files: String(localized: "Files")
        case .git: String(localized: "Git")
        }
    }

    var help: String {
        switch self {
        case .info: String(localized: "Info (⇧⌘I)")
        case .files: String(localized: "Files (⇧⌘E)")
        case .git: String(localized: "Git (⇧⌘G)")
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .files: "folder"
        case .git: "arrow.triangle.branch"
        }
    }
}

extension GitStatusModel.FileDecoration {
    var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflict: "!"
        case .ignored: "I"
        }
    }

    var accessibilityName: String {
        switch self {
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .untracked: String(localized: "Untracked")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .conflict: String(localized: "Conflict")
        case .ignored: String(localized: "Ignored")
        }
    }

    var indicatorColor: NSColor {
        gitStatusIndicatorColor(for: self)
    }
}

func gitStatusName(for status: Character) -> String {
    switch status {
    case "M": String(localized: "Modified")
    case "A": String(localized: "Added")
    case "?": String(localized: "Untracked")
    case "D": String(localized: "Deleted")
    case "R": String(localized: "Renamed")
    case "C": String(localized: "Copied")
    case "U": String(localized: "Conflict")
    default: String(localized: "Changed")
    }
}

func gitStatusIndicatorColor(for decoration: GitStatusModel.FileDecoration) -> NSColor {
    switch decoration {
    case .modified: NSColor(red: 0.82, green: 0.60, blue: 0.13, alpha: 1)
    case .added, .untracked: NSColor(red: 0.25, green: 0.73, blue: 0.31, alpha: 1)
    case .deleted: NSColor(red: 1.0, green: 0.48, blue: 0.45, alpha: 1)
    case .renamed, .copied: NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1)
    case .conflict: NSColor(red: 0.74, green: 0.55, blue: 1.0, alpha: 1)
    case .ignored: NSColor.secondaryLabelColor.withAlphaComponent(0.55)
    }
}

func gitStatusIndicatorColor(for status: Character) -> NSColor {
    switch status {
    case "M": NSColor(red: 0.82, green: 0.60, blue: 0.13, alpha: 1)
    case "A", "?": NSColor(red: 0.25, green: 0.73, blue: 0.31, alpha: 1)
    case "D": NSColor(red: 1.0, green: 0.48, blue: 0.45, alpha: 1)
    case "R", "C": NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1)
    case "U": NSColor(red: 0.74, green: 0.55, blue: 1.0, alpha: 1)
    default: .secondaryLabelColor
    }
}

func inspectorLabel(_ string: String = "") -> NSTextField {
    let label = NSTextField(labelWithString: string)
    label.isBordered = false
    label.drawsBackground = false
    label.isEditable = false
    label.isSelectable = false
    label.lineBreakMode = .byTruncatingTail
    label.backgroundColor = .clear
    return label
}

func inspectorSymbolImage(
    _ name: String,
    size: CGFloat,
    weight: NSFont.Weight = .medium,
    accessibilityDescription: String? = nil
) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
        .withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        )
}

final class AppKitChromeIconButton: NSButton {
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false
    var onAction: (() -> Void)?

    override var isFlipped: Bool { true }

    convenience init(systemImage: String, help: String, iconSize: CGFloat = 12) {
        self.init(frame: .zero)
        configure(systemImage: systemImage, help: help, iconSize: iconSize)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .texturedRounded
        imagePosition = .imageOnly
        focusRingType = .default
        target = self
        action = #selector(handleAction)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }

    func configure(systemImage: String, help: String, iconSize: CGFloat = 12) {
        image = inspectorSymbolImage(
            systemImage,
            size: iconSize,
            accessibilityDescription: help
        )
        toolTip = help
        setAccessibilityLabel(help)
        contentTintColor = isHovering ? Theme.chromePrimaryText : Theme.chromeMutedText
        refreshHoverFill()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        contentTintColor = Theme.chromePrimaryText
        refreshHoverFill()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        contentTintColor = Theme.chromeMutedText
        refreshHoverFill()
    }

    @objc private func handleAction() {
        onAction?()
    }

    private func refreshHoverFill() {
        layer?.backgroundColor = (
            isHovering ? NSColor.labelColor.withAlphaComponent(0.08) : .clear
        ).cgColor
    }
}

/// Invisible drag strip on a sidebar's inner edge. Dragging resizes within
/// `range`; double-click snaps back to `defaultWidth`. Cursor registration
/// uses AppKit cursor rects so neighbouring I-beam rects cannot steal it.
final class AppKitSidebarResizeHandle: NSView {
    var edge: HorizontalEdge = .leading
    var range: ClosedRange<Double> = InspectorMetrics.widthRange
    var defaultWidth: Double = InspectorMetrics.defaultWidth
    var width: Double = InspectorMetrics.defaultWidth
    var onWidthChange: ((Double) -> Void)?

    private var dragStartX: CGFloat?
    private var dragStartWidth: Double?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "Resize Inspector"))
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStartX = nil
            dragStartWidth = nil
            width = defaultWidth
            onWidthChange?(width)
            return
        }
        dragStartX = event.locationInWindow.x
        dragStartWidth = width
        NSCursor.columnResize.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX, let dragStartWidth else { return }
        let delta = Double(event.locationInWindow.x - dragStartX)
        let signed = edge == .trailing ? delta : -delta
        width = min(max(dragStartWidth + signed, range.lowerBound), range.upperBound)
        onWidthChange?(width)
        NSCursor.columnResize.set()
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        dragStartWidth = nil
    }

    /// Test hook: apply a signed drag in the handle's resize direction.
    func debugApplyDrag(delta: Double) {
        width = min(max(width + delta, range.lowerBound), range.upperBound)
        onWidthChange?(width)
    }
}

final class AppKitWindowDragView: NSView {
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performTitlebarDoubleClickAction()
        } else {
            window?.performDrag(with: event)
        }
    }
}

final class AppKitInspectorTabButton: NSView {
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = inspectorLabel()
    private var trackingAreaReference: NSTrackingArea?
    private(set) var state = InspectorTabDisplayState(
        panel: .files,
        title: "",
        help: "",
        systemImage: "folder",
        isSelected: false
    )
    var onSelect: (() -> Void)?
    var fontSize: CGFloat = 11

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 3) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .default
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill()
    }

    func configure(state: InspectorTabDisplayState, fontSize: CGFloat) {
        self.state = state
        self.fontSize = fontSize
        titleLabel.stringValue = state.title
        titleLabel.font = .systemFont(ofSize: 11 * fontSize / AppSettings.defaultSidebarFontSize)
        let color = state.isSelected ? Theme.chromePrimaryText : Theme.chromeMutedText
        titleLabel.textColor = color
        iconView.contentTintColor = color
        iconView.image = inspectorSymbolImage(
            state.systemImage,
            size: 10 * fontSize / AppSettings.defaultSidebarFontSize,
            accessibilityDescription: state.title
        )
        layer?.backgroundColor = (state.isSelected ? Theme.chromeSelected : .clear).cgColor
        toolTip = state.help
        setAccessibilityLabel(state.title)
        setAccessibilityValue(state.accessibilityValue)
        setAccessibilityHelp(state.help)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 10 * fontSize / AppSettings.defaultSidebarFontSize
        let spacing: CGFloat = 5
        titleLabel.sizeToFit()
        let contentWidth = iconSize + spacing + titleLabel.bounds.width
        var x = max(4, (bounds.width - contentWidth) / 2)
        let iconY = (bounds.height - iconSize) / 2
        iconView.frame = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
        x += iconSize + spacing
        titleLabel.frame = NSRect(
            x: x,
            y: (bounds.height - titleLabel.bounds.height) / 2,
            width: titleLabel.bounds.width,
            height: titleLabel.bounds.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onSelect?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

final class AppKitInspectorTabBar: NSView {
    private var buttons: [AppKitInspectorTabButton] = []
    private(set) var selected: RightPanel = .files
    var onSelect: ((RightPanel) -> Void)?
    var fontSize: CGFloat = AppSettings.defaultSidebarFontSize

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.chromeHeader.cgColor
        buttons = RightPanel.allCases.map { _ in AppKitInspectorTabButton(frame: .zero) }
        buttons.forEach { addSubview($0) }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func configure(selected: RightPanel, fontSize: CGFloat, onSelect: @escaping (RightPanel) -> Void) {
        self.selected = selected
        self.fontSize = fontSize
        self.onSelect = onSelect
        refresh()
    }

    func debugSelect(_ panel: RightPanel) {
        onSelect?(panel)
    }

    var debugTabTitles: [String] {
        InspectorTabDisplayState.all(selected: selected).map(\.title)
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 8
        let spacing: CGFloat = 4
        let count = CGFloat(max(buttons.count, 1))
        let width = max(0, (bounds.width - padding * 2 - spacing * (count - 1)) / count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: padding + CGFloat(index) * (width + spacing),
                y: 6,
                width: width,
                height: max(0, bounds.height - 12)
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        layer?.backgroundColor = Theme.chromeHeader.cgColor
        let states = InspectorTabDisplayState.all(selected: selected)
        for (button, state) in zip(buttons, states) {
            button.onSelect = { [weak self] in self?.onSelect?(state.panel) }
            button.configure(state: state, fontSize: fontSize)
        }
        needsLayout = true
    }
}

final class AppKitInspectorHeaderLabel: NSView {
    private let titleLabel = inspectorLabel()
    private let subtitleLabel = inspectorLabel()
    var fontScale: CGFloat = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        subtitleLabel.lineBreakMode = .byTruncatingHead
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, subtitle: String?, fontScale: CGFloat) {
        self.fontScale = fontScale
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12 * fontScale, weight: .semibold)
        titleLabel.textColor = Theme.chromePrimaryText
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.font = .systemFont(ofSize: 10 * fontScale)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isHidden = subtitle == nil || subtitle?.isEmpty == true
        toolTip = subtitle
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight: CGFloat = 16 * fontScale
        titleLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: titleHeight)
        if subtitleLabel.isHidden {
            subtitleLabel.frame = .zero
        } else {
            subtitleLabel.frame = NSRect(
                x: 0,
                y: titleHeight + 1,
                width: bounds.width,
                height: 13 * fontScale
            )
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: subtitleLabel.isHidden ? 16 * fontScale : 30 * fontScale
        )
    }
}

final class AppKitMiniProgressView: NSProgressIndicator {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .spinning
        controlSize = .mini
        isDisplayedWhenStopped = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func setLoading(_ loading: Bool) {
        if loading {
            isHidden = false
            startAnimation(nil)
        } else {
            stopAnimation(nil)
            isHidden = true
        }
    }
}
