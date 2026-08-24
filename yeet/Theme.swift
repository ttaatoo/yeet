//
//  Theme.swift
//  kero
//

import AppKit
import Combine
import os

/// The user's light/dark preference. Applied by overriding `NSApp.appearance`,
/// which drives every window, the dynamic colors below, and — through
/// `NSApp.effectiveAppearance` — the terminal theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System", comment: "Appearance that follows the macOS setting.")
        case .light: return String(localized: "Light", comment: "Light app appearance.")
        case .dark: return String(localized: "Dark", comment: "Dark app appearance.")
        }
    }

    /// `nil` hands the appearance back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Publishes when the selected terminal themes change, so views painting with
/// `Theme` colors repaint without waiting for an appearance flip.
final class ThemeChanges: nonisolated ObservableObject {}

/// App colors, sourced from the ghostty themes the user selected in Settings
/// (one per appearance; GitHub Dark/Light Default out of the box). Terminal
/// sessions consume the definitions directly via `terminal(dark:)`. The
/// editor, diffs, and pane surfaces follow that palette. Dark sidebar chrome
/// is a hard-coded Codex Dark panel so the project list and Files/Git
/// inspector match after a sidebar swap; light sidebar chrome keeps the
/// selected light theme's solid fill.
enum Theme {
    nonisolated static let defaultDarkThemeName = "Default Dark"
    nonisolated static let defaultLightThemeName = "Default Light"

    @MainActor static let changes = ThemeChanges()

    /// Kero's built-in themes: the GitHub Default palettes under kero's own
    /// names. Dark sidebar chrome is always the solid Codex Dark panel
    /// (see `sidebar`); it no longer follows the selected terminal theme
    /// or the old translucent sidebar material.
    nonisolated static let defaultDarkDefinition = keroDefault(
        named: defaultDarkThemeName, from: "GitHub Dark Default", dark: true
    )
    nonisolated static let defaultLightDefinition = keroDefault(
        named: defaultLightThemeName, from: "GitHub Light Default", dark: false
    )

    /// Popular themes from the catalog. Each appearance has 29 catalog themes
    /// plus Kero's default, keeping either Settings picker capped at 30 choices.
    private nonisolated static let commonDarkCatalogThemeNames: Set<String> = [
        "Adwaita Dark",
        "Afterglow",
        "Atom One Dark",
        "Ayu",
        "Ayu Mirage",
        "Catppuccin Frappe",
        "Catppuccin Macchiato",
        "Catppuccin Mocha",
        "Dark+",
        "Dracula",
        "Everforest Dark Hard",
        "Flexoki Dark",
        "GitHub Dark",
        "GitHub Dark Dimmed",
        "Gruvbox Dark",
        "Gruvbox Material",
        "iTerm2 Solarized Dark",
        "Kanagawa Dragon",
        "Kanagawa Wave",
        "Material Dark",
        "Monokai Pro",
        "Night Owl",
        "Nord",
        "Nvim Dark",
        "Rose Pine",
        "Rose Pine Moon",
        "TokyoNight",
        "TokyoNight Storm",
        "Vesper",
    ]

    private nonisolated static let commonLightCatalogThemeNames: Set<String> = [
        "Adwaita",
        "Alabaster",
        "Apple System Colors Light",
        "Atom One Light",
        "Ayu Light",
        "Bluloco Light",
        "Catppuccin Latte",
        "Dawnfox",
        "Dayfox",
        "Everforest Light Med",
        "Flexoki Light",
        "GitHub",
        "GitHub Light High Contrast",
        "GitLab Light",
        "Gruvbox Light",
        "Gruvbox Material Light",
        "Iceberg Light",
        "iTerm2 Solarized Light",
        "Kanagawa Lotus",
        "Light Owl",
        "Material",
        "Modus Operandi",
        "Monokai Pro Light",
        "Nord Light",
        "Nvim Light",
        "One Half Light",
        "Rose Pine Dawn",
        "TokyoNight Day",
        "Tomorrow",
    ]

    /// Kero's Default comes first; the duplicate GitHub Default catalog rows
    /// are intentionally omitted because the built-ins use those palettes.
    nonisolated static let commonDarkThemes: [TerminalThemeDefinition] =
        [defaultDarkDefinition] + TerminalThemeCatalog.allThemes.filter {
            $0.isDark && commonDarkCatalogThemeNames.contains($0.name)
        }

    nonisolated static let commonLightThemes: [TerminalThemeDefinition] =
        [defaultLightDefinition] + TerminalThemeCatalog.allThemes.filter {
            !$0.isDark && commonLightCatalogThemeNames.contains($0.name)
        }

    nonisolated static func isCommonTheme(named name: String, dark: Bool) -> Bool {
        let themes = dark ? commonDarkThemes : commonLightThemes
        return themes.contains { $0.name == name }
    }

    /// The selected definitions, mirrored out of `AppSettings` because the
    /// dynamic color providers below may resolve outside the main actor.
    private nonisolated static let selection = OSAllocatedUnfairLock(
        initialState: (light: defaultLightDefinition, dark: defaultDarkDefinition)
    )

    /// A kero built-in or catalog theme by name.
    nonisolated static func definition(named name: String) -> TerminalThemeDefinition? {
        if name == defaultLightThemeName { return defaultLightDefinition }
        if name == defaultDarkThemeName { return defaultDarkDefinition }
        return TerminalThemeCatalog.theme(named: name)
    }

    /// Re-resolves the selected themes by name. Called by `AppSettings` on
    /// startup and whenever either terminal theme setting changes; unknown
    /// names keep the defaults.
    @MainActor
    static func reloadSelection(light: String, dark: String) {
        let resolved = (
            light: definition(named: light) ?? defaultLightDefinition,
            dark: definition(named: dark) ?? defaultDarkDefinition
        )
        selection.withLock { $0 = resolved }
        afterViewUpdate { changes.objectWillChange.send() }
    }

    /// Applies one catalog theme without changing the saved setting. The
    /// bundled `yeet +themes` browser uses this while the user moves through
    /// its list, then either commits through `AppSettings` or restores the
    /// saved pair with `reloadSelection`.
    @MainActor
    @discardableResult
    static func previewSelection(named name: String, dark: Bool) -> Bool {
        guard isCommonTheme(named: name, dark: dark),
              let definition = definition(named: name)
        else { return false }
        selection.withLock {
            if dark {
                $0.dark = definition
            } else {
                $0.light = definition
            }
        }
        afterViewUpdate { changes.objectWillChange.send() }
        return true
    }

    /// The selected terminal theme for one appearance.
    nonisolated static func terminal(dark: Bool) -> TerminalThemeDefinition {
        selection.withLock { dark ? $0.dark : $0.light }
    }

    /// A copy of a catalog theme under a kero-owned name.
    private nonisolated static func keroDefault(
        named name: String, from catalogName: String, dark: Bool
    ) -> TerminalThemeDefinition {
        let base = fallback(named: catalogName, dark: dark)
        return TerminalThemeDefinition(
            name: name,
            isDark: dark,
            background: base.background,
            foreground: base.foreground,
            cursorColor: base.cursorColor,
            cursorText: base.cursorText,
            selectionBackground: base.selectionBackground,
            selectionForeground: base.selectionForeground,
            palette: base.palette
        )
    }

    static var background: NSColor { dynamic { $0.backgroundNSColor } }
    /// Project list and Files/Git inspector fill. Dark is Codex Dark so the
    /// two columns match after Swap sidebars; light stays the selected
    /// theme's solid sidebar shade.
    static var sidebar: NSColor { appearanceDynamic { chromePanel(dark: $0) } }
    static var accent: NSColor { dynamic { $0.accentNSColor } }

    /// Title-bar-ish strip at the top of a chrome column. Dark uses the
    /// Codex header; light stays the same fill as the rest of the panel.
    static var chromeHeader: NSColor {
        appearanceDynamic { isDark in
            isDark ? hexColor(CodexDarkChrome.header) : chromePanel(dark: false)
        }
    }

    /// Hairline between chrome columns and the pane stack. Dark is the
    /// Codex divider; light keeps the existing theme hairline.
    static var chromeDivider: NSColor {
        appearanceDynamic { isDark in
            if isDark { return hexColor(CodexDarkChrome.divider) }
            return lightChromeDivider
        }
    }

    static var chromeHover: NSColor {
        appearanceDynamic { isDark in
            isDark
                ? hexColor(CodexDarkChrome.hover)
                : NSColor.labelColor.withAlphaComponent(0.04)
        }
    }

    static var chromeSelected: NSColor {
        appearanceDynamic { isDark in
            isDark
                ? hexColor(CodexDarkChrome.selected)
                : NSColor.labelColor.withAlphaComponent(0.09)
        }
    }

    static var chromePrimaryText: NSColor {
        appearanceDynamic { isDark in
            isDark ? hexColor(CodexDarkChrome.primaryText) : NSColor.labelColor
        }
    }

    static var chromeMutedText: NSColor {
        appearanceDynamic { isDark in
            isDark
                ? hexColor(CodexDarkChrome.mutedText)
                : NSColor.secondaryLabelColor
        }
    }

    /// Amber on dark chrome, where the project row already tints the
    /// selected folder. Light keeps the selected terminal theme's accent.
    static var chromeAccent: NSColor {
        appearanceDynamic { isDark in
            isDark ? hexColor(CodexDarkChrome.accent) : terminal(dark: false).accentNSColor
        }
    }

    /// Hairline separators outside the chrome columns (session tab bar,
    /// browser, diffs). Those surfaces still follow the terminal theme.
    static var divider: NSColor {
        dynamic { theme in
            theme.isKeroDefault
                ? NSColor.labelColor.withAlphaComponent(0.06)
                : theme.surfaceNSColor(elevation: 0.08)
        }
    }

    /// Sidebar fill resolved for one appearance. The Settings theme previews
    /// draw light and dark side by side, so they can't use the dynamic
    /// `sidebar` — it would resolve both halves to the ambient appearance.
    static func sidebarFill(dark: Bool) -> NSColor {
        chromePanel(dark: dark)
    }

    /// Solid Codex Dark in dark appearance; the selected light theme's
    /// sidebar shade otherwise. Shared by `sidebar` and `sidebarFill`.
    private nonisolated static func chromePanel(dark: Bool) -> NSColor {
        dark ? hexColor(CodexDarkChrome.panel) : terminal(dark: false).sidebarNSColor
    }

    private nonisolated static var lightChromeDivider: NSColor {
        let theme = terminal(dark: false)
        return theme.isKeroDefault
            ? NSColor.labelColor.withAlphaComponent(0.06)
            : theme.surfaceNSColor(elevation: 0.08)
    }

    /// A fresh dynamic color per access: cached instances keep resolving the
    /// theme they were created under, so views re-rendered after a selection
    /// change would repaint with stale colors.
    private nonisolated static func dynamic(
        _ resolve: @escaping @Sendable (TerminalThemeDefinition) -> NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolve(terminal(dark: isDark))
        }
    }

    /// Dynamic color that keys only on appearance. Dark chrome is Codex Dark
    /// regardless of the selected terminal theme.
    private nonisolated static func appearanceDynamic(
        _ resolve: @escaping @Sendable (Bool) -> NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolve(isDark)
        }
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

    /// Last-resort definition should a default name ever leave the catalog.
    private nonisolated static func fallback(named name: String, dark: Bool) -> TerminalThemeDefinition {
        TerminalThemeCatalog.theme(named: name) ?? TerminalThemeDefinition(
            name: name,
            isDark: dark,
            background: dark ? "0d1117" : "ffffff",
            foreground: dark ? "e6edf3" : "1f2328"
        )
    }
}

/// Hard-coded Codex Dark chrome. Not a Settings theme; the terminal,
/// session tabs, and Alacritty palette do not use these values.
private enum CodexDarkChrome {
    static let panel = "1E1E1E"
    static let header = "141414"
    static let primaryText = "EFEFEF"
    static let mutedText = "888888"
    static let divider = "3D3D3D"
    static let hover = "2E2E2E"
    static let selected = "333333"
    static let accent = "F59E0C"
}

/// UI-facing colors for a terminal theme definition. The definition stores
/// terminal colors as hex strings; window chrome derives its palette here.
/// Nonisolated so the dynamic color providers can resolve on any thread.
nonisolated extension TerminalThemeDefinition {
    /// Whether this is one of kero's built-in Default themes, which keep
    /// label-based hairlines on non-chrome surfaces (session tab bar, diffs).
    var isKeroDefault: Bool {
        name == Theme.defaultDarkThemeName || name == Theme.defaultLightThemeName
    }

    var backgroundNSColor: NSColor { Self.nsColor(background) }
    var foregroundNSColor: NSColor { Self.nsColor(foreground) }

    var cursorNSColor: NSColor {
        cursorColor.map(Self.nsColor) ?? accentNSColor
    }

    /// Accent for selection highlights, focus rings, and active icons: ANSI
    /// blue reads as a theme's "link" color, with the cursor color, then the
    /// foreground, as fallbacks for palettes that don't define one.
    var accentNSColor: NSColor {
        (palette[4] ?? cursorColor).map(Self.nsColor) ?? foregroundNSColor
    }

    /// Light sidebar fill when that appearance is active. Dark chrome no
    /// longer reads this — `Theme.sidebar` uses Codex Dark instead. Built-in
    /// Default Light keeps the GitHub canvas-inset shade; other light
    /// themes use their own background.
    var sidebarNSColor: NSColor {
        if name == Theme.defaultLightThemeName { return Self.nsColor("f6f8fa") }
        return backgroundNSColor
    }

    /// `background` blended toward `foreground`; used for the editor's line
    /// highlight and gutter shades.
    func surfaceNSColor(elevation: CGFloat) -> NSColor {
        backgroundNSColor.blended(withFraction: elevation, of: foregroundNSColor)
            ?? backgroundNSColor
    }

    private static func nsColor(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return .magenta // Unmistakable flag for a malformed catalog entry.
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }
}
