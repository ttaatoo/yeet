//
//  AppSettings.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// The app-specific language macOS should use when Kero next launches.
///
/// `AppleLanguages` is stored in Kero's own defaults domain, matching the
/// per-app language preference managed by System Settings. Removing it returns
/// control to the user's system language order.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// Language names are autonyms so the picker stays usable even when the
    /// current app language is unfamiliar to the user.
    var title: String {
        switch self {
        case .system:
            String(
                localized: "System Default",
                comment: "Language choice that follows the macOS setting."
            )
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        case .japanese:
            "日本語"
        }
    }

    static var saved: AppLanguage {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            let domain = UserDefaults.standard.persistentDomain(
                forName: bundleIdentifier
            ),
            let identifiers = domain["AppleLanguages"] as? [String],
            let identifier = identifiers.first
        else {
            return .system
        }

        return from(identifier: identifier) ?? .system
    }

    private static func from(identifier: String) -> AppLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if normalized == "zh-Hans"
            || normalized.hasPrefix("zh-Hans-")
            || normalized.hasPrefix("zh-CN")
            || normalized.hasPrefix("zh-SG") {
            return .simplifiedChinese
        }
        if normalized == "ja" || normalized.hasPrefix("ja-") {
            return .japanese
        }
        if normalized == "en" || normalized.hasPrefix("en-") {
            return .english
        }
        return nil
    }

    func persist() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese, .japanese:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Whether the toolbar follows project context, always shows, or stays hidden.
enum ToolbarVisibility: String, CaseIterable, Identifiable {
    case auto
    case always
    case hide

    var id: String { rawValue }
}

/// Copies leftover Kerox (then older Kero) directories into Yeet paths when
/// the Yeet directory does not exist yet. Used for `~/.config/yeet` and
/// Application Support history so a rebrand does not drop existing settings.
enum LegacyIdentityStore {
    static func adoptIfMissing(destination: URL, leftovers: [URL]) {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return }
        for leftover in leftovers where fm.fileExists(atPath: leftover.path) {
            do {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: leftover, to: destination)
                return
            } catch {
                NSLog("yeet: failed to copy leftover \(leftover.path) → \(destination.path): \(error)")
            }
        }
    }
}

/// User-configurable settings, persisted to `$HOME/.config/yeet/config.toml`.
/// Views observe this directly; `TerminalManager` re-themes live sessions on
/// any change.
@MainActor
final class AppSettings: nonisolated ObservableObject {
    static let shared = AppSettings()

    /// Development (Debug) builds store their config under `~/.config/yeet-dev`
    /// instead of `~/.config/yeet`, so running a dev build alongside an
    /// installed production build doesn't clobber its settings. This mirrors
    /// the separate `sh.yeet.dev` bundle identifier that keeps the two apps'
    /// `UserDefaults` (session snapshot, sidebar widths, Sparkle) apart —
    /// and keeps this app off official Kero's `sh.kero` / `~/.config/kero`.
    ///
    /// If the Yeet directory is missing, leftover `~/.config/kerox`
    /// (then older `~/.config/kero`) is copied in. Debug uses `yeet-dev`
    /// with leftover `kerox-dev`, then `kero-dev`.
    static let configURL: URL = {
        #if DEBUG
        let directory = "yeet-dev"
        let leftovers = ["kerox-dev", "kero-dev"]
        #else
        let directory = "yeet"
        let leftovers = ["kerox", "kero"]
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        let destDir = home.appendingPathComponent(".config/\(directory)", isDirectory: true)
        LegacyIdentityStore.adoptIfMissing(
            destination: destDir,
            leftovers: leftovers.map {
                home.appendingPathComponent(".config/\($0)", isDirectory: true)
            }
        )
        return destDir.appendingPathComponent("config.toml")
    }()

    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...32
    static let defaultSidebarFontSize: Double = 14
    static let sidebarFontSizeRange: ClosedRange<Double> = 9...18
    /// Designed file-name size in the Files tree. The default matches today's
    /// look at the default sidebar scale (11.5pt).
    static let defaultFilesFontSize = Double(SidebarTypography.designedFileNameSize)
    static let filesFontSizeRange: ClosedRange<Double> = 9...22
    static let defaultToolbarVisibility: ToolbarVisibility = .hide

    /// The language this process launched with, kept separate from the pending
    /// selection so Settings can explain when a relaunch is required.
    let activeLanguage: AppLanguage

    @Published var language: AppLanguage {
        didSet { language.persist() }
    }

    var languageRequiresRelaunch: Bool {
        language != activeLanguage
    }

    /// Light/dark appearance override; `system` follows macOS.
    @Published var theme: AppTheme {
        didSet {
            applyAppearance()
            save()
        }
    }

    /// Color theme names, one per appearance; the terminal, editor, and
    /// diffs derive from them. Chrome accent is `chromeAccent`. `Theme`
    /// keeps the resolved definitions (kero built-ins plus the ghostty
    /// catalog).
    @Published var themeDark: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    @Published var themeLight: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    /// Window-chrome accent family. Independent of `themeDark` / `themeLight`.
    /// Persisted as `chrome-accent`; omitted when Coral (the default).
    @Published var chromeAccent: ChromeAccent {
        didSet {
            Theme.reloadChromeAccent(chromeAccent)
            save()
        }
    }

    /// Terminal font family name; empty string means the bundled default
    /// (JetBrains Mono).
    @Published var fontFamily: String {
        didSet { save() }
    }

    @Published var fontSize: Double {
        didSet { save() }
    }

    /// Base text size for the project list and the Git/Info inspector.
    /// Each of those panels keeps its relative hierarchy. The Files tree
    /// uses `filesFontSize` instead.
    @Published var sidebarFontSize: Double {
        didSet { save() }
    }

    /// Files inspector family; empty string means the system UI font.
    @Published var filesFontFamily: String {
        didSet { save() }
    }

    /// File-name size in the Files inspector, in points. Badges, chevrons,
    /// and metadata keep their designed sizes relative to this.
    @Published var filesFontSize: Double {
        didSet { save() }
    }

    /// `auto` shows the toolbar only for Git projects; `always` keeps its Git
    /// panel entry point visible in every project; `hide` suppresses it.
    @Published var toolbarVisibility: ToolbarVisibility {
        didSet { save() }
    }

    /// Off keeps the default layout (project list leading, inspector trailing).
    /// On swaps those panels. Shortcuts and widths stay bound to the panel,
    /// not the physical edge. Persisted as `layout.swap-sidebars`.
    @Published var swapSidebars: Bool {
        didSet { save() }
    }

    /// Render terminal glyphs with slightly heavier strokes, like classic
    /// macOS font smoothing. Each backend maps this to its own rasterizer.
    /// Persisted as `terminal.font-thicken`; off by default so Kero's text
    /// matches a stock Ghostty install.
    @Published var fontThicken: Bool {
        didSet { save() }
    }

    @Published var cursorShape: TerminalCursorShape {
        didSet { save() }
    }

    @Published var cursorBlinking: Bool {
        didSet { save() }
    }

    /// Send Option-key chords to terminal programs as Alt/Meta instead of
    /// letting the active macOS input source produce text. Off by default so
    /// layouts such as Polish Pro can type their Option-composed characters.
    @Published var macosOptionAsAlt: Bool {
        didSet { save() }
    }

    /// Soft-wrap file editor lines to the viewport width. Off by default so
    /// long lines scroll horizontally.
    @Published var wrapLines: Bool {
        didSet { save() }
    }

    /// Restore each terminal's previous scrollback (as static, styled text)
    /// when the app relaunches, above the freshly started shell. Off by
    /// default: opt-in, and it writes captured output to disk.
    @Published var restoreTerminalHistory: Bool {
        didSet { save() }
    }

    /// Relaunch resumes the coding agents that were live at quit — Claude
    /// Code, Codex, Grok, OpenCode, Gemini — by sending each agent's native
    /// resume command with the session identifier an integration hook
    /// reported. Panes whose agent reported no identifier restore as plain
    /// terminals.
    @Published var autoResumeAgents: Bool {
        didSet { save() }
    }

    /// OSC 52 clipboard write from a terminal program. Default `.allow`
    /// matches Ghostty so vim, tmux, and agents can copy without a sheet.
    @Published var clipboardWrite: ClipboardAccessPolicy {
        didSet { save() }
    }

    /// OSC 52 clipboard read from a terminal program, including over SSH.
    /// Default `.ask` matches Ghostty so a remote host cannot exfiltrate
    /// the macOS clipboard silently.
    @Published var clipboardRead: ClipboardAccessPolicy {
        didSet { save() }
    }

    static let defaultClipboardWrite: ClipboardAccessPolicy = .allow
    static let defaultClipboardRead: ClipboardAccessPolicy = .ask

    /// Link Kero's shared coordination skill plus the native lifecycle
    /// integrations whose provider APIs provide semantic turn events. Other
    /// agents retain process recognition without inferred progress state.
    @Published private(set) var aiEnabled: Bool {
        didSet { save() }
    }

    /// Global hotkey that summons or hides Yeet from any app.
    /// `nil` means none is registered. Default is Option+Space.
    @Published var globalHotkey: KeyCombo? {
        didSet {
            registerGlobalHotkey()
            save()
        }
    }

    /// Last Carbon register for `globalHotkey` failed. Settings shows this
    /// so Debug vs Release both fighting ⌥Space is visible, not log-only.
    @Published private(set) var globalHotkeyRegistrationFailed = false

    private init() {
        let savedLanguage = AppLanguage.saved
        activeLanguage = savedLanguage
        language = savedLanguage

        let existing = TOML.parse(at: Self.configURL)
        let toml = existing ?? Self.legacyDefaults()
        theme = toml["theme"]?.string.flatMap(AppTheme.init(rawValue:)) ?? .system
        themeDark = Self.knownTheme(
            toml["theme-dark"]?.string,
            dark: true,
            fallback: Theme.defaultDarkThemeName
        )
        themeLight = Self.knownTheme(
            toml["theme-light"]?.string,
            dark: false,
            fallback: Theme.defaultLightThemeName
        )
        chromeAccent = toml["chrome-accent"]?.string.flatMap(ChromeAccent.init(rawValue:))
            ?? .coral
        fontFamily = toml["font-family"]?.string ?? ""
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
        let sidebarSize = toml["sidebar.font-size"]?.double
            ?? Self.defaultSidebarFontSize
        sidebarFontSize = Self.sidebarFontSizeRange.contains(sidebarSize)
            ? sidebarSize
            : Self.defaultSidebarFontSize
        filesFontFamily = toml["files.font-family"]?.string ?? ""
        let filesSize = toml["files.font-size"]?.double ?? Self.defaultFilesFontSize
        filesFontSize = Self.filesFontSizeRange.contains(filesSize)
            ? filesSize
            : Self.defaultFilesFontSize
        toolbarVisibility = ToolbarVisibility(
            rawValue: toml["toolbar.visibility"]?.string ?? ""
        ) ?? Self.defaultToolbarVisibility
        swapSidebars = toml["layout.swap-sidebars"]?.bool ?? false
        fontThicken = toml["terminal.font-thicken"]?.bool
            ?? toml["font-thicken"]?.bool
            ?? false
        cursorShape = TerminalCursorShape(
            rawValue: toml["terminal.cursor-shape"]?.string ?? ""
        ) ?? .block
        cursorBlinking = toml["terminal.cursor-blinking"]?.bool ?? true
        macosOptionAsAlt = toml["terminal.macos-option-as-alt"]?.bool ?? false
        wrapLines = toml["editor.wrap-lines"]?.bool ?? false
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? false
        autoResumeAgents = toml["terminal.auto-resume-agents"]?.bool ?? true
        clipboardWrite = ClipboardAccessPolicy(
            rawValue: toml["clipboard-write"]?.string ?? ""
        ) ?? Self.defaultClipboardWrite
        clipboardRead = ClipboardAccessPolicy(
            rawValue: toml["clipboard-read"]?.string ?? ""
        ) ?? Self.defaultClipboardRead
        aiEnabled = toml["ai.enabled"]?.bool ?? false
        globalHotkey = Self.parseGlobalHotkey(toml)
        applyAppearance()
        reloadThemeSelection()
        Theme.reloadChromeAccent(chromeAccent)
        // didSet does not run during init (same as applyAppearance).
        registerGlobalHotkey()
        if existing == nil { save() }
    }

    /// Pushes the current names into `Theme`, which resolves and caches the
    /// definitions. Called from `init` because `didSet` doesn't run there.
    private func reloadThemeSelection() {
        Theme.reloadSelection(light: themeLight, dark: themeDark)
    }

    /// A saved shared-theme name, or `fallback` when it is absent or no longer
    /// part of the cross-backend catalog, so Settings never shows an empty
    /// selection after upgrading from the larger Ghostty-only list.
    private static func knownTheme(
        _ name: String?, dark: Bool, fallback: String
    ) -> String {
        guard let name else { return fallback }
        if dark, Theme.isDefaultDarkName(name) { return Theme.defaultDarkThemeName }
        if !dark, Theme.isDefaultLightName(name) { return Theme.defaultLightThemeName }
        guard Theme.isCommonTheme(named: name, dark: dark) else {
            return fallback
        }
        return name
    }

    /// Overrides the app-wide appearance so every window — and the terminal
    /// theme, which reads `NSApp.effectiveAppearance` — follows the choice.
    /// Called from `init` because `didSet` doesn't run during initialization.
    func applyAppearance() {
        NSApp?.appearance = theme.nsAppearance
    }

    func resetFont() {
        fontFamily = ""
        fontSize = Self.defaultFontSize
        sidebarFontSize = Self.defaultSidebarFontSize
        filesFontFamily = ""
        filesFontSize = Self.defaultFilesFontSize
        fontThicken = false
    }

    func resetToDefaults() {
        resetFont()
        language = .system
        theme = .system
        themeDark = Theme.defaultDarkThemeName
        themeLight = Theme.defaultLightThemeName
        chromeAccent = .coral
        toolbarVisibility = Self.defaultToolbarVisibility
        swapSidebars = false
        cursorShape = .block
        cursorBlinking = true
        macosOptionAsAlt = false
        wrapLines = false
        restoreTerminalHistory = false
        autoResumeAgents = true
        clipboardWrite = Self.defaultClipboardWrite
        clipboardRead = Self.defaultClipboardRead
        globalHotkey = KeyCombo.default
        if aiEnabled {
            do {
                try setAIEnabled(false)
            } catch {
                NSLog("yeet: failed to disable AI support: \(error)")
            }
        }
    }

    /// Persist the setting only after every requested destination operation
    /// returns successfully.
    func setAIEnabled(_ enabled: Bool) throws {
        if enabled {
            try KeroAgentIntegrations.preflightInstallAvailable()
            _ = try KeroAutomationSkill.install(
                destinations: KeroAutomationSkill.Destination.allCases,
                force: false
            )
            try KeroAgentIntegrations.installAvailable()
        } else {
            try KeroAgentIntegrations.preflightUninstallManaged()
            _ = try KeroAutomationSkill.uninstall(
                destinations: KeroAutomationSkill.Destination.allCases,
                force: false
            )
            try KeroAgentIntegrations.uninstallManaged()
        }
        aiEnabled = enabled
    }

    /// App updates normally preserve the bundle path targeted by the links.
    /// Reconcile at launch as well so moving the app or changing Debug build
    /// products repairs only installations the user explicitly enabled.
    func reconcileAIEnabled() {
        guard aiEnabled else { return }
        do {
            _ = try KeroAutomationSkill.install(
                destinations: KeroAutomationSkill.Destination.allCases,
                force: false
            )
            try KeroAgentIntegrations.installAvailable()
        } catch {
            NSLog("yeet: failed to refresh AI support: \(error)")
        }
    }

    private func save() {
        var lines: [String] = []
        if theme != .system {
            lines.append("theme = \(TOML.quote(theme.rawValue))")
        }
        // Top-level like `theme`: the color theme drives the whole window,
        // not just the terminal.
        if themeDark != Theme.defaultDarkThemeName {
            lines.append("theme-dark = \(TOML.quote(themeDark))")
        }
        if themeLight != Theme.defaultLightThemeName {
            lines.append("theme-light = \(TOML.quote(themeLight))")
        }
        if chromeAccent != .coral {
            lines.append("chrome-accent = \(TOML.quote(chromeAccent.rawValue))")
        }
        if !fontFamily.isEmpty {
            lines.append("font-family = \(TOML.quote(fontFamily))")
        }
        lines.append("font-size = \(TOML.number(fontSize))")
        if sidebarFontSize != Self.defaultSidebarFontSize {
            lines.append("sidebar.font-size = \(TOML.number(sidebarFontSize))")
        }
        if !filesFontFamily.isEmpty {
            lines.append("files.font-family = \(TOML.quote(filesFontFamily))")
        }
        if filesFontSize != Self.defaultFilesFontSize {
            lines.append("files.font-size = \(TOML.number(filesFontSize))")
        }
        if toolbarVisibility != Self.defaultToolbarVisibility {
            lines.append("toolbar.visibility = \(TOML.quote(toolbarVisibility.rawValue))")
        }
        if swapSidebars {
            lines.append("layout.swap-sidebars = true")
        }
        if fontThicken {
            lines.append("terminal.font-thicken = true")
        }
        if cursorShape != .block {
            lines.append("terminal.cursor-shape = \(TOML.quote(cursorShape.rawValue))")
        }
        if !cursorBlinking {
            lines.append("terminal.cursor-blinking = false")
        }
        if macosOptionAsAlt {
            lines.append("terminal.macos-option-as-alt = true")
        }
        if wrapLines {
            lines.append("editor.wrap-lines = true")
        }
        if restoreTerminalHistory {
            lines.append("terminal.restore-history = true")
        }
        if !autoResumeAgents {
            lines.append("terminal.auto-resume-agents = false")
        }
        if clipboardWrite != Self.defaultClipboardWrite {
            lines.append("clipboard-write = \(TOML.quote(clipboardWrite.rawValue))")
        }
        if clipboardRead != Self.defaultClipboardRead {
            lines.append("clipboard-read = \(TOML.quote(clipboardRead.rawValue))")
        }
        if aiEnabled {
            lines.append("ai.enabled = true")
        }
        if let hotkey = globalHotkey {
            lines.append("global-hotkey.key-code = \(TOML.number(Double(hotkey.keyCode)))")
            lines.append("global-hotkey.modifiers = \(TOML.number(Double(hotkey.modifiers)))")
        } else {
            // Cleared must persist; missing keys would default to Option+Space.
            lines.append("global-hotkey.enabled = false")
        }
        let dir = Self.configURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n")
                .write(to: Self.configURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("yeet: failed to write \(Self.configURL.path): \(error)")
        }
    }

    private static func parseGlobalHotkey(_ toml: [String: TOML.Value]) -> KeyCombo? {
        if toml["global-hotkey.enabled"]?.bool == false {
            return nil
        }

        if let keyCode = toml["global-hotkey.key-code"]?.double.map(Int.init),
           let modifiers = toml["global-hotkey.modifiers"]?.double.map(Int.init) {
            let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
            if combo.isValid {
                return combo
            }
            NSLog("yeet: ignoring invalid global-hotkey from config (Shift-only not allowed)")
            return KeyCombo.default
        }

        return KeyCombo.default
    }

    /// Registers the current combo. `didSet` does not run in `init`, so that
    /// path calls this explicitly. Returns whether Carbon accepted the binding.
    @discardableResult
    func registerGlobalHotkey() -> Bool {
        let succeeded = GlobalHotKeyManager.shared.register(keyCombo: globalHotkey) {
            KeroApplicationDelegate.shared?.toggleKeroWindow()
        }
        globalHotkeyRegistrationFailed = globalHotkey != nil && !succeeded
        return succeeded
    }

    /// Settings from releases that stored config in UserDefaults.
    private static func legacyDefaults() -> [String: TOML.Value] {
        var toml: [String: TOML.Value] = [:]
        let defaults = UserDefaults.standard
        if let family = defaults.string(forKey: "terminalFontFamily") {
            toml["font-family"] = .string(family)
        }
        if defaults.object(forKey: "terminalFontSize") != nil {
            toml["font-size"] = .number(defaults.double(forKey: "terminalFontSize"))
        }
        return toml
    }
}

/// Minimal TOML support covering what the config file uses: flat and dotted
/// keys (`font-size = 15`, `terminal.restore-history = true`), string/number/
/// bool values, and `#` comments. `[table]` headers are also accepted and
/// flattened to `table.key`, matching the dotted form.
enum TOML {
    enum Value {
        case string(String)
        case number(Double)
        case bool(Bool)

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var double: Double? {
            if case .number(let n) = self { return n }
            return nil
        }

        var bool: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }
    }

    static func parse(at url: URL) -> [String: Value]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(text)
    }

    /// Same grammar as `parse(at:)`, from an already-read string.
    static func parse(_ text: String) -> [String: Value] {
        var table = ""
        var result: [String: Value] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseValue(rawValue) else { continue }
            result[table.isEmpty ? key : "\(table).\(key)"] = value
        }
        return result
    }

    private static func parseValue(_ raw: String) -> Value? {
        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return .string(out)
                } else {
                    out.append(ch)
                }
            }
            return nil
        }
        // Unquoted: strip a trailing comment, then try bool/number.
        let bare = raw.split(separator: "#", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
        switch bare {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return Double(bare).map(Value.number)
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"", "\\": out.append("\\\(ch)")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15
            ? String(Int(n)) : String(n)
    }
}
