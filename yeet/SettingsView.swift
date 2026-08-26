//
//  SettingsView.swift
//  kero
//

import AppKit
import SwiftUI

/// The app settings window (Cmd+,).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared
    @State private var relaunchError = ""
    @State private var isShowingRelaunchError = false

    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()

    private var toolbarVisibilityDescription: LocalizedStringKey {
        switch settings.toolbarVisibility {
        case .auto:
            "Shows the toolbar only in Git repositories"
        case .always:
            "Shows the toolbar in every project"
        case .hide:
            "Keeps the toolbar hidden"
        }
    }

    var body: some View {
        CappedIdealHeight(maxHeight: 600) { form }
    }

    private var form: some View {
        Form {
            Section("Appearance") {
                // A plain row rather than LabeledContent: that stamps its own
                // label onto every child, leaving all three previews named
                // "Theme" to VoiceOver instead of System/Light/Dark.
                HStack {
                    Text("Theme")
                    Spacer()
                    ThemePicker(selection: $settings.theme)
                }

                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }

                DescribedSettingsRow(
                    "Toolbar",
                    description: toolbarVisibilityDescription
                ) {
                    Picker("Toolbar", selection: $settings.toolbarVisibility) {
                        Text("Auto").tag(ToolbarVisibility.auto)
                        Text("Always Show").tag(ToolbarVisibility.always)
                        Text("Hide").tag(ToolbarVisibility.hide)
                    }
                    .labelsHidden()
                }

                DescribedSettingsRow(
                    "Swap sidebars",
                    description: "Puts the Files, Git, and Info inspector on the left and the project list on the right. Shortcuts still apply to those panels"
                ) {
                    Toggle("Swap sidebars", isOn: $settings.swapSidebars)
                        .labelsHidden()
                }

                GlobalHotKeySettingsRow(
                    keyCombo: settings.globalHotkey,
                    registrationFailed: settings.globalHotkeyRegistrationFailed,
                    onChange: { settings.globalHotkey = $0 }
                )
                .frame(minHeight: 44)

                if settings.languageRequiresRelaunch {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Relaunch Yeet to apply the language change.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Yeet") {
                            relaunch()
                        }
                    }
                }
            }

            Section("Colors") {
                Picker("Dark theme", selection: $settings.themeDark) {
                    ForEach(Self.darkThemeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Picker("Light theme", selection: $settings.themeLight) {
                    ForEach(Self.lightThemeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Picker("Accent", selection: $settings.chromeAccent) {
                    ForEach(ChromeAccent.allCases) { family in
                        Text(family.title).tag(family)
                    }
                }
            }

            Section("Font") {
                Picker("Family", selection: $settings.fontFamily) {
                    Text("\(TerminalFont.bundledFamily) (Bundled)").tag("")
                    Divider()
                    ForEach(families.dropFirst(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                }

                // Empty family is the system UI font — not the bundled
                // terminal default, which is a separate tagged option.
                Picker("Files panel", selection: $settings.filesFontFamily) {
                    Text("System Font").tag("")
                    Divider()
                    Text("\(TerminalFont.bundledFamily) (Bundled)")
                        .tag(TerminalFont.bundledFamily)
                    ForEach(families.dropFirst(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .accessibilityLabel("Files family")

                HStack {
                    Text("Files size")
                    Slider(
                        value: $settings.filesFontSize,
                        in: AppSettings.filesFontSizeRange,
                        step: 0.5
                    )
                    .accessibilityLabel("Files font size")
                    Text(pointsLabel(settings.filesFontSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.filesFontSize,
                        in: AppSettings.filesFontSizeRange,
                        step: 0.5
                    )
                    .labelsHidden()
                    .accessibilityLabel("Files font size")
                }

                HStack {
                    Text("Sidebar size")
                    Slider(
                        value: $settings.sidebarFontSize,
                        in: AppSettings.sidebarFontSizeRange,
                        step: 1
                    )
                    .accessibilityLabel("Sidebar font size")
                    Text("\(Int(settings.sidebarFontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.sidebarFontSize,
                        in: AppSettings.sidebarFontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                    .accessibilityLabel("Sidebar font size")
                }
            }

            Section("Preview") {
                // SwiftUI Text cannot show Ghostty's font-thicken — that flag
                // only affects CoreText glyph rasterization — so draw through
                // AppKit with shouldSmoothFonts matching the toggle.
                FontThickenPreview(font: previewFont, thicken: settings.fontThicken)
                    .padding(.vertical, 4)
                    // NSView drawing has no semantic children of its own.
                    // Preserve the sample text that the previous SwiftUI Text
                    // views exposed to VoiceOver.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: """
                    yeet ❯ echo "the quick brown fox" 0O 1lI
                    \u{E0A0} main \u{E0B0} ~/dev/yeet \u{E711} \u{F024B} \u{F0A7D}
                    bold — permission denied (os error 13)
                    """))
                    .accessibilityAddTraits(.isStaticText)
            }

            Section("Terminal") {
                TerminalCursorShapeSettingsRow(
                    shape: settings.cursorShape,
                    onChange: { settings.cursorShape = $0 }
                )

                TerminalCursorBlinkingSettingsRow(
                    isBlinking: settings.cursorBlinking,
                    onChange: { settings.cursorBlinking = $0 }
                )

                DescribedSettingsRow(
                    "Thicken font strokes",
                    description: "Renders terminal text with slightly heavier strokes, like classic macOS font smoothing"
                ) {
                    Toggle("Thicken font strokes", isOn: $settings.fontThicken)
                        .labelsHidden()
                }

                DescribedSettingsRow(
                    "Use Option as Alt/Meta",
                    description: "Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input"
                ) {
                    Toggle(
                        "Use Option as Alt/Meta",
                        isOn: $settings.macosOptionAsAlt
                    )
                    .labelsHidden()
                }

                DescribedSettingsRow(
                    "Restore session history on relaunch",
                    description: "Reopened terminals show their previous scrollback above a fresh shell"
                ) {
                    Toggle(
                        "Restore session history on relaunch",
                        isOn: $settings.restoreTerminalHistory
                    )
                    .labelsHidden()
                }

                DescribedSettingsRow(
                    "Resume agents on relaunch",
                    description: "Agents that were running when Yeet quit restart with their previous session (Claude Code, Codex, Grok, OpenCode, Gemini)"
                ) {
                    Toggle(
                        "Resume agents on relaunch",
                        isOn: $settings.autoResumeAgents
                    )
                    .labelsHidden()
                }

                DescribedSettingsRow(
                    "Clipboard write",
                    description: "When a terminal program copies text with OSC 52 (vim, tmux, coding agents). Allow writes immediately. Ask shows a confirmation. Deny ignores the copy."
                ) {
                    Picker("Clipboard write", selection: $settings.clipboardWrite) {
                        ForEach(ClipboardAccessPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                }

                DescribedSettingsRow(
                    "Clipboard read",
                    description: "When a terminal program requests the macOS clipboard with OSC 52, including over SSH. Ask confirms first. Allow returns it immediately. Deny returns nothing."
                ) {
                    Picker("Clipboard read", selection: $settings.clipboardRead) {
                        ForEach(ClipboardAccessPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                }
            }

            Section("Text Editing") {
                Toggle("Wrap lines to editor width", isOn: $settings.wrapLines)
            }

            Section("Automation") {
                AgentCLISupportSettingsRow(
                    isEnabled: settings.aiEnabled,
                    onChange: { try settings.setAIEnabled($0) }
                )
                .frame(minHeight: 44)
            }

            if updater.hasUpdateFeed {
                Section("Updates") {
                    Toggle(
                        "Automatically check for updates",
                        isOn: $updater.automaticallyChecksForUpdates
                    )

                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    .disabled(settings.fontFamily.isEmpty
                        && settings.fontSize == AppSettings.defaultFontSize
                        && settings.sidebarFontSize == AppSettings.defaultSidebarFontSize
                        && settings.filesFontFamily.isEmpty
                        && settings.filesFontSize == AppSettings.defaultFilesFontSize
                        && !settings.fontThicken
                        && settings.cursorShape == .block
                        && settings.cursorBlinking
                        && !settings.macosOptionAsAlt
                        && settings.language == .system
                        && settings.theme == .system
                        && settings.themeDark == Theme.defaultDarkThemeName
                        && settings.themeLight == Theme.defaultLightThemeName
                        && settings.chromeAccent == .coral
                        && settings.toolbarVisibility == AppSettings.defaultToolbarVisibility
                        && !settings.swapSidebars
                        && !settings.wrapLines
                        && !settings.restoreTerminalHistory
                        && settings.autoResumeAgents
                        && settings.clipboardWrite == AppSettings.defaultClipboardWrite
                        && settings.clipboardRead == AppSettings.defaultClipboardRead
                        && !settings.aiEnabled
                        && settings.globalHotkey == KeyCombo.default)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .alert(
            "Couldn’t Relaunch Yeet",
            isPresented: $isShowingRelaunchError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: relaunchError)
        }
    }

    private var previewFont: NSFont {
        TerminalFont.resolve(family: settings.fontFamily, size: CGFloat(settings.fontSize))
    }

    /// Whole-point sizes match the terminal/sidebar labels (`13 pt`);
    /// the Files default is 11.5, so keep one decimal when needed.
    private func pointsLabel(_ size: Double) -> String {
        if size == size.rounded() {
            return "\(Int(size)) pt"
        }
        return String(format: "%.1f pt", size)
    }

    private func relaunch() {
        TerminalManager.saveForRelaunch()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                if let error {
                    relaunchError = error.localizedDescription
                    isShowingRelaunchError = true
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The compact catalog of popular themes, split by the appearance slot
    /// they suit. Yeet only hosts the Alacritty surface.
    private static let darkThemeNames = Theme.commonDarkThemes.map(\.name)
    private static let lightThemeNames = Theme.commonLightThemes.map(\.name)
}

/// Matches macOS Settings: a title and explanation form one label stack,
/// while the setting control stays aligned to the row's top-right corner.
private struct DescribedSettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let control: Control

    init(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Settings font preview that honors `font-thicken`. Ghostty thickens by
/// enabling CoreText font smoothing when rasterizing glyphs; SwiftUI `Text`
/// does not, so toggling the setting left this preview unchanged.
private struct FontThickenPreview: NSViewRepresentable {
    var font: NSFont
    var thicken: Bool

    func makeNSView(context: Context) -> FontThickenPreviewView {
        FontThickenPreviewView()
    }

    func updateNSView(_ view: FontThickenPreviewView, context: Context) {
        view.previewFont = font
        view.thicken = thicken
        view.needsDisplay = true
        view.invalidateIntrinsicContentSize()
    }
}

private final class FontThickenPreviewView: NSView {
    var previewFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var thicken = false

    /// Regular / icon / bold lines — same samples as the old SwiftUI preview.
    private let lines: [(text: String, bold: Bool)] = [
        ("yeet ❯ echo \"the quick brown fox\" 0O 1lI", false),
        ("\u{E0A0} main \u{E0B0} ~/dev/yeet \u{E711} \u{F024B} \u{F0A7D}", false),
        ("bold — permission denied (os error 13)", true),
    ]

    private let lineSpacing: CGFloat = 6
    private let verticalPadding: CGFloat = 4

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        let height = verticalPadding * 2
            + CGFloat(lines.count) * lineHeight
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Mirror Ghostty's CoreText glyph path (face/coretext.zig):
        // font-thicken == shouldSmoothFonts.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(thicken)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let color = NSColor.labelColor
        var y = verticalPadding
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        for (text, bold) in lines {
            let font = bold
                ? NSFontManager.shared.convert(previewFont, toHaveTrait: .boldFontMask)
                : previewFont
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
            y += lineHeight + lineSpacing
        }
    }
}

/// Sizes its sole child to the child's ideal height, capped at `maxHeight`.
/// A `maxHeight` frame plus `fixedSize` can't express this: the grouped Form
/// is a List, which only scrolls when *proposed* the capped height, yet still
/// has to be measured unconstrained to hug shorter content.
private struct CappedIdealHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let ideal = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

/// Theme chooser modelled on the Appearance control in System Settings: one
/// tappable preview per option instead of a row of words.
private struct ThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases) { theme in
                ThemeOption(
                    theme: theme,
                    isSelected: selection == theme,
                    select: { selection = theme }
                )
            }
        }
    }
}

private struct ThemeOption: View {
    let theme: AppTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                ThemePreview(theme: theme)
                Text(theme.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    // Without this the row's HStack can squeeze a label to
                    // zero width, wrapping it into blank lines that stretch
                    // that one option taller than its neighbours.
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(isSelected ? 0.15 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature Yeet window painted in one appearance's real colors. `system`
/// splits down the middle — light on the left, dark on the right — the same
/// way System Settings previews "Auto".
private struct ThemePreview: View {
    let theme: AppTheme

    private static let size = CGSize(width: 76, height: 50)
    private static let corner: CGFloat = 7

    var body: some View {
        ZStack {
            switch theme {
            case .light:
                MiniWindow(dark: false)
            case .dark:
                MiniWindow(dark: true)
            case .system:
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: Self.size.width / 2)
                    }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// Sidebar, traffic lights, a tab, and a few lines of terminal output —
/// enough of Yeet's layout to read at thumbnail size.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let theme = Theme.terminal(dark: dark)
        let text = Color(nsColor: theme.foregroundNSColor)
        let cursor = Color(nsColor: theme.cursorNSColor)

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2.5) {
                    dot(0xFF5F57)
                    dot(0xFEBC2E)
                    dot(0x28C840)
                }
                .padding(.bottom, 3)

                bar(11, text.opacity(0.35))
                bar(8, text.opacity(0.35))
                bar(11, text.opacity(0.35))
            }
            .padding(5)
            .frame(minWidth: 22, maxWidth: 22, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: Theme.sidebarFill(dark: dark)))

            VStack(alignment: .leading, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(text.opacity(0.12))
                    .frame(width: 14, height: 5)
                    .padding(.bottom, 1)

                HStack(spacing: 2) {
                    bar(3, cursor)
                    bar(22, text.opacity(0.8))
                }
                bar(30, text.opacity(0.45))
                bar(16, text.opacity(0.45))
                HStack(spacing: 2) {
                    bar(3, cursor)
                    bar(7, text.opacity(0.8))
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: theme.backgroundNSColor))
        }
    }

    private func dot(_ hex: Int) -> some View {
        Circle()
            .fill(Color(
                .sRGB,
                red: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255
            ))
            .frame(width: 3.5, height: 3.5)
    }

    private func bar(_ width: CGFloat, _ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(fill)
            .frame(width: width, height: 2.5)
    }
}

#Preview {
    SettingsView()
}
