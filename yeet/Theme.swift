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

/// App colors, sourced from the catalog themes the user selected in Settings
/// (one per appearance; Yeet Dark / Yeet Light out of the box). Terminal
/// sessions consume the definitions directly via `terminal(dark:)`. The
/// editor, diffs, and pane surfaces follow that palette. Dark sidebar chrome
/// is a hard-coded warm near-black frame one step above the Yeet Dark canvas,
/// with the mascot orange accent, so the project list and Files/Git inspector
/// match after a sidebar swap; light sidebar chrome keeps the selected
/// light theme's solid fill.
enum Theme {
    nonisolated static let defaultDarkThemeName = "Yeet Dark"
    nonisolated static let defaultLightThemeName = "Yeet Light"
    /// Names written by earlier builds. `definition(named:)` and
    /// `isCommonTheme` still accept them so an old `config.toml` keeps its
    /// built-in theme instead of falling through to a catalog row.
    nonisolated static let legacyDefaultDarkThemeName = "Default Dark"
    nonisolated static let legacyDefaultLightThemeName = "Default Light"

    /// Mascot body; selected rows, focus, and blocked-agent chrome.
    nonisolated static let accentHex = "FF4D2E"
    /// Mascot prompt; cursor, in-progress / finished chrome, review counts.
    nonisolated static let progressHex = "7DFFB3"
    /// Deeper mint for light chrome, where `#7DFFB3` fails contrast.
    nonisolated static let progressLightHex = "0F8A5B"

    @MainActor static let changes = ThemeChanges()

    /// Built-in Yeet Dark. GitHub Dark Default for reds, greens, yellows,
    /// blues, cyans, and magenta; a warm near-black canvas; mint cursor;
    /// orange selection.
    nonisolated static let defaultDarkDefinition = TerminalThemeDefinition(
        name: defaultDarkThemeName,
        isDark: true,
        background: "0B0A09",
        foreground: "E8E2DC",
        cursorColor: progressHex,
        selectionBackground: "5C2418",
        palette: [
            "484f58", "ff7b72", "3fb950", "d29922",
            "58a6ff", "bc8cff", "39c5cf", "b1bac4",
            "6e7681", "ffa198", "56d364", "e3b341",
            "79c0ff", "d2a8ff", "56d4dd", "e6edf3",
        ] + Array(repeating: nil, count: 240)
    )

    /// Built-in Yeet Light: warm paper canvas, orange accent, deep mint cursor.
    nonisolated static let defaultLightDefinition = TerminalThemeDefinition(
        name: defaultLightThemeName,
        isDark: false,
        background: "F7F1EA",
        foreground: "1F1A16",
        cursorColor: progressLightHex,
        selectionBackground: "F0C2B0",
        palette: [
            "24292f", "cf222e", "116329", "4d2d00",
            "0969da", "8250df", "1b7c83", "6e7781",
            "57606a", "a40e26", "1a7f37", "633c01",
            "0550ae", "6639ba", "1b7c83", "1f2328",
        ] + Array(repeating: nil, count: 240)
    )

    /// Popular themes from the catalog. Each appearance has 29 catalog themes
    /// plus Yeet's default, keeping either Settings picker capped at 30 choices.
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

    /// Yeet's default comes first. GitHub Light Default is omitted so the
    /// picker stays at 30 (Yeet Light is no longer a copy of that palette).
    /// GitHub Dark Default is omitted so the picker stays at 30; GitHub Dark
    /// is the same catalog row.
    nonisolated static let commonDarkThemes: [TerminalThemeDefinition] =
        [defaultDarkDefinition] + TerminalThemeCatalog.allThemes.filter {
            $0.isDark && commonDarkCatalogThemeNames.contains($0.name)
        }

    nonisolated static let commonLightThemes: [TerminalThemeDefinition] =
        [defaultLightDefinition] + TerminalThemeCatalog.allThemes.filter {
            !$0.isDark && commonLightCatalogThemeNames.contains($0.name)
        }

    nonisolated static func isCommonTheme(named name: String, dark: Bool) -> Bool {
        if dark, isDefaultDarkName(name) { return true }
        if !dark, isDefaultLightName(name) { return true }
        let themes = dark ? commonDarkThemes : commonLightThemes
        return themes.contains { $0.name == name }
    }

    nonisolated static func isDefaultDarkName(_ name: String) -> Bool {
        name == defaultDarkThemeName || name == legacyDefaultDarkThemeName
    }

    nonisolated static func isDefaultLightName(_ name: String) -> Bool {
        name == defaultLightThemeName || name == legacyDefaultLightThemeName
    }

    /// The selected definitions, mirrored out of `AppSettings` because the
    /// dynamic color providers below may resolve outside the main actor.
    private nonisolated static let selection = OSAllocatedUnfairLock(
        initialState: (light: defaultLightDefinition, dark: defaultDarkDefinition)
    )

    /// A Yeet built-in or catalog theme by name.
    nonisolated static func definition(named name: String) -> TerminalThemeDefinition? {
        if isDefaultLightName(name) { return defaultLightDefinition }
        if isDefaultDarkName(name) { return defaultDarkDefinition }
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

    static var background: NSColor { dynamic { $0.backgroundNSColor } }
    /// Project list and Files/Git inspector fill. Dark is one step above
    /// the Yeet Dark canvas so the two columns match after Swap
    /// sidebars; light stays the selected theme's solid sidebar shade.
    static var sidebar: NSColor { appearanceDynamic { chromePanel(dark: $0) } }
    static var accent: NSColor { dynamic { $0.accentNSColor } }

    /// Title-bar-ish strip at the top of a chrome column. Dark uses the
    /// same lifted fill as the panel; light stays the same fill as the
    /// rest of the panel.
    static var chromeHeader: NSColor {
        appearanceDynamic { isDark in
            isDark ? hexColor(YeetDarkChrome.header) : chromePanel(dark: false)
        }
    }

    /// Hairline between chrome columns and the pane stack. Dark is the
    /// near-black divider; light keeps the existing theme hairline.
    static var chromeDivider: NSColor {
        appearanceDynamic { isDark in
            if isDark { return hexColor(YeetDarkChrome.divider) }
            return lightChromeDivider
        }
    }

    static var chromeHover: NSColor {
        appearanceDynamic { isDark in
            isDark
                ? hexColor(YeetDarkChrome.hover)
                : NSColor.labelColor.withAlphaComponent(0.04)
        }
    }

    static var chromeSelected: NSColor {
        appearanceDynamic { isDark in
            isDark
                ? hexColor(YeetDarkChrome.selected)
                : NSColor.labelColor.withAlphaComponent(0.09)
        }
    }

    static var chromePrimaryText: NSColor {
        appearanceDynamic { isDark in
            isDark ? hexColor(YeetDarkChrome.primaryText) : NSColor.labelColor
        }
    }

    static var chromeMutedText: NSColor {
        appearanceDynamic { isDark in
            isDark
                ? hexColor(YeetDarkChrome.mutedText)
                : NSColor.secondaryLabelColor
        }
    }

    /// Mascot orange on dark chrome, where the project row already tints the
    /// selected folder. Light keeps the selected terminal theme's accent.
    static var chromeAccent: NSColor {
        appearanceDynamic { isDark in
            isDark ? hexColor(YeetDarkChrome.accent) : terminal(dark: false).accentNSColor
        }
    }

    /// Mint on dark chrome; deeper mint on light. Used for in-progress and
    /// finished agent chrome, the cursor's sibling in the window, and the
    /// pending-review file count.
    static var chromeProgress: NSColor {
        appearanceDynamic { isDark in
            isDark ? hexColor(progressHex) : hexColor(progressLightHex)
        }
    }

    /// Hairline separators outside the chrome columns (session tab bar,
    /// browser, diffs). Those surfaces still follow the terminal theme.
    static var divider: NSColor {
        dynamic { theme in
            theme.isBuiltInDefault
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

    /// Lifted near-black frame in dark appearance; the selected light
    /// theme's sidebar shade otherwise. Shared by `sidebar` and
    /// `sidebarFill`.
    private nonisolated static func chromePanel(dark: Bool) -> NSColor {
        dark ? hexColor(YeetDarkChrome.panel) : terminal(dark: false).sidebarNSColor
    }

    private nonisolated static var lightChromeDivider: NSColor {
        let theme = terminal(dark: false)
        return theme.isBuiltInDefault
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

    /// Dynamic color that keys only on appearance. Dark chrome is the
    /// lifted near-black frame regardless of the selected terminal theme.
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

}

/// Hard-coded dark chrome. One step lighter than Yeet Dark's terminal
/// canvas so the project list and inspector read as a frame. Both chrome
/// columns share these values so they match after a sidebar swap. Not a
/// Settings theme; the terminal, session tabs, and Alacritty palette do
/// not use these values.
private enum YeetDarkChrome {
    static let panel = "161412"
    static let header = "161412"
    static let primaryText = "E8E2DC"
    static let mutedText = "8A8580"
    static let divider = "2C2926"
    static let hover = "1E1C1A"
    static let selected = "2A2420"
    static let accent = Theme.accentHex
}

/// UI-facing colors for a terminal theme definition. The definition stores
/// terminal colors as hex strings; window chrome derives its palette here.
/// Nonisolated so the dynamic color providers can resolve on any thread.
nonisolated extension TerminalThemeDefinition {
    /// Whether this is one of Yeet's built-in default themes, which keep
    /// label-based hairlines on non-chrome surfaces (session tab bar, diffs).
    var isBuiltInDefault: Bool {
        Theme.isDefaultDarkName(name) || Theme.isDefaultLightName(name)
    }

    var backgroundNSColor: NSColor { Self.nsColor(background) }
    var foregroundNSColor: NSColor { Self.nsColor(foreground) }

    var cursorNSColor: NSColor {
        cursorColor.map(Self.nsColor) ?? accentNSColor
    }

    /// Accent for selection highlights, focus rings, and active icons. Yeet
    /// Dark and Yeet Light use mascot orange; every other theme uses ANSI
    /// blue as the "link" color, then the cursor, then the foreground.
    var accentNSColor: NSColor {
        if Theme.isDefaultDarkName(name) || Theme.isDefaultLightName(name) {
            return Self.nsColor(Theme.accentHex)
        }
        return (palette[4] ?? cursorColor).map(Self.nsColor) ?? foregroundNSColor
    }

    /// Light sidebar fill when that appearance is active. Dark chrome no
    /// longer reads this — `Theme.sidebar` uses the lifted near-black
    /// frame instead. Built-in Yeet Light uses warm paper; other light
    /// themes use their own background.
    var sidebarNSColor: NSColor {
        if Theme.isDefaultLightName(name) { return Self.nsColor("F3EBE3") }
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
