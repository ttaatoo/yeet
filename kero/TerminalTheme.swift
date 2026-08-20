//
//  TerminalTheme.swift
//  kero
//

import Foundation

/// Terminal color theme definition with hex color strings.
struct TerminalThemeDefinition {
    let name: String
    let isDark: Bool
    let background: String
    let foreground: String
    let cursorColor: String?
    let cursorText: String?
    let selectionBackground: String?
    let selectionForeground: String?
    /// 256-color palette where indices 0-15 are ANSI colors.
    let palette: [String?]
    
    init(
        name: String,
        isDark: Bool = true,
        background: String,
        foreground: String,
        cursorColor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [String?] = Array(repeating: nil, count: 256)
    ) {
        self.name = name
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }
}

/// Catalog of built-in terminal themes.
enum TerminalThemeCatalog {
    /// All available themes across both light and dark appearances.
    static let allThemes: [TerminalThemeDefinition] = darkThemes + lightThemes
    
    /// Look up a theme by exact name match.
    static func theme(named name: String) -> TerminalThemeDefinition? {
        allThemes.first { $0.name == name }
    }
    
    // MARK: - Dark Themes
    
    private static let darkThemes: [TerminalThemeDefinition] = [
        githubDarkDefault,
        githubDark,
        githubDarkDimmed,
        catppuccinMocha,
        catppuccinMacchiato,
        catppuccinFrappe,
        draculaTheme,
        nord,
        tokyoNight,
        tokyoNightStorm,
        gruvboxDark,
        gruvboxMaterial,
        monokaiPro,
        materialDark,
        ayuDark,
        ayuMirage,
        darkPlus,
        atomOneDark,
        nightOwl,
        vesper,
        rosePine,
        rosePineMoon,
        kanagawaWave,
        kanagawaDragon,
        everforestDarkHard,
        flexokiDark,
        iTerm2SolarizedDark,
        adwaitaDark,
        afterglow,
        nvimDark,
    ]
    
    private static let lightThemes: [TerminalThemeDefinition] = [
        githubLightDefault,
        githubLight,
        catppuccinLatte,
        gruvboxLight,
        ayuLight,
        lightPlus,
        atomOneLight,
        iTerm2SolarizedLight,
        rosePineDawn,
        kanagawaLotus,
        everforestLightHard,
        flexokiLight,
        adwaitaLight,
        nvimLight,
    ]
    
    // MARK: - GitHub Themes
    
    private static let githubDarkDefault = TerminalThemeDefinition(
        name: "GitHub Dark Default",
        isDark: true,
        background: "0d1117",
        foreground: "e6edf3",
        cursorColor: "58a6ff",
        selectionBackground: "1f6feb",
        palette: [
            "484f58", "ff7b72", "3fb950", "d29922",
            "58a6ff", "bc8cff", "39c5cf", "b1bac4",
            "6e7681", "ffa198", "56d364", "e3b341",
            "79c0ff", "d2a8ff", "56d4dd", "e6edf3",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let githubLightDefault = TerminalThemeDefinition(
        name: "GitHub Light Default",
        isDark: false,
        background: "ffffff",
        foreground: "1f2328",
        cursorColor: "0969da",
        selectionBackground: "0969da",
        palette: [
            "24292f", "cf222e", "116329", "4d2d00",
            "0969da", "8250df", "1b7c83", "6e7781",
            "57606a", "a40e26", "1a7f37", "633c01",
            "0550ae", "6639ba", "1b7c83", "1f2328",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let githubDark = TerminalThemeDefinition(
        name: "GitHub Dark",
        isDark: true,
        background: "0d1117",
        foreground: "e6edf3",
        cursorColor: "58a6ff",
        selectionBackground: "1f6feb",
        palette: [
            "484f58", "ff7b72", "3fb950", "d29922",
            "58a6ff", "bc8cff", "39c5cf", "b1bac4",
            "6e7681", "ffa198", "56d364", "e3b341",
            "79c0ff", "d2a8ff", "56d4dd", "e6edf3",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let githubDarkDimmed = TerminalThemeDefinition(
        name: "GitHub Dark Dimmed",
        isDark: true,
        background: "22272e",
        foreground: "adbac7",
        cursorColor: "539bf5",
        selectionBackground: "539bf5",
        palette: [
            "545d68", "f47067", "57ab5a", "c69026",
            "539bf5", "b083f0", "39c5cf", "909dab",
            "636e7b", "ff938a", "6bc46d", "daaa3f",
            "6cb6ff", "dcbdfb", "56d4dd", "cdd9e5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let githubLight = TerminalThemeDefinition(
        name: "GitHub Light",
        isDark: false,
        background: "ffffff",
        foreground: "1f2328",
        cursorColor: "0969da",
        selectionBackground: "0969da",
        palette: [
            "24292f", "cf222e", "116329", "4d2d00",
            "0969da", "8250df", "1b7c83", "6e7781",
            "57606a", "a40e26", "1a7f37", "633c01",
            "0550ae", "6639ba", "1b7c83", "1f2328",
        ] + Array(repeating: nil, count: 240)
    )
    
    // MARK: - Catppuccin Themes
    
    private static let catppuccinMocha = TerminalThemeDefinition(
        name: "Catppuccin Mocha",
        isDark: true,
        background: "1e1e2e",
        foreground: "cdd6f4",
        cursorColor: "f5e0dc",
        selectionBackground: "585b70",
        palette: [
            "45475a", "f38ba8", "a6e3a1", "f9e2af",
            "89b4fa", "f5c2e7", "94e2d5", "bac2de",
            "585b70", "f38ba8", "a6e3a1", "f9e2af",
            "89b4fa", "f5c2e7", "94e2d5", "a6adc8",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let catppuccinMacchiato = TerminalThemeDefinition(
        name: "Catppuccin Macchiato",
        isDark: true,
        background: "24273a",
        foreground: "cad3f5",
        cursorColor: "f4dbd6",
        selectionBackground: "5b6078",
        palette: [
            "494d64", "ed8796", "a6da95", "eed49f",
            "8aadf4", "f5bde6", "8bd5ca", "b8c0e0",
            "5b6078", "ed8796", "a6da95", "eed49f",
            "8aadf4", "f5bde6", "8bd5ca", "a5adcb",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let catppuccinFrappe = TerminalThemeDefinition(
        name: "Catppuccin Frappe",
        isDark: true,
        background: "303446",
        foreground: "c6d0f5",
        cursorColor: "f2d5cf",
        selectionBackground: "626880",
        palette: [
            "51576d", "e78284", "a6d189", "e5c890",
            "8caaee", "f4b8e4", "81c8be", "b5bfe2",
            "626880", "e78284", "a6d189", "e5c890",
            "8caaee", "f4b8e4", "81c8be", "a5adce",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let catppuccinLatte = TerminalThemeDefinition(
        name: "Catppuccin Latte",
        isDark: false,
        background: "eff1f5",
        foreground: "4c4f69",
        cursorColor: "dc8a78",
        selectionBackground: "acb0be",
        palette: [
            "5c5f77", "d20f39", "40a02b", "df8e1d",
            "1e66f5", "ea76cb", "179299", "acb0be",
            "6c6f85", "d20f39", "40a02b", "df8e1d",
            "1e66f5", "ea76cb", "179299", "bcc0cc",
        ] + Array(repeating: nil, count: 240)
    )
    
    // MARK: - Popular Dark Themes
    
    private static let draculaTheme = TerminalThemeDefinition(
        name: "Dracula",
        isDark: true,
        background: "282a36",
        foreground: "f8f8f2",
        cursorColor: "f8f8f2",
        selectionBackground: "44475a",
        palette: [
            "21222c", "ff5555", "50fa7b", "f1fa8c",
            "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
            "6272a4", "ff6e6e", "69ff94", "ffffa5",
            "d6acff", "ff92df", "a4ffff", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let nord = TerminalThemeDefinition(
        name: "Nord",
        isDark: true,
        background: "2e3440",
        foreground: "d8dee9",
        cursorColor: "d8dee9",
        selectionBackground: "4c566a",
        palette: [
            "3b4252", "bf616a", "a3be8c", "ebcb8b",
            "81a1c1", "b48ead", "88c0d0", "e5e9f0",
            "4c566a", "bf616a", "a3be8c", "ebcb8b",
            "81a1c1", "b48ead", "8fbcbb", "eceff4",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let tokyoNight = TerminalThemeDefinition(
        name: "TokyoNight",
        isDark: true,
        background: "1a1b26",
        foreground: "c0caf5",
        cursorColor: "c0caf5",
        selectionBackground: "33467c",
        palette: [
            "15161e", "f7768e", "9ece6a", "e0af68",
            "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
            "414868", "f7768e", "9ece6a", "e0af68",
            "7aa2f7", "bb9af7", "7dcfff", "c0caf5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let tokyoNightStorm = TerminalThemeDefinition(
        name: "TokyoNight Storm",
        isDark: true,
        background: "24283b",
        foreground: "c0caf5",
        cursorColor: "c0caf5",
        selectionBackground: "364a82",
        palette: [
            "1d202f", "f7768e", "9ece6a", "e0af68",
            "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
            "414868", "f7768e", "9ece6a", "e0af68",
            "7aa2f7", "bb9af7", "7dcfff", "c0caf5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let gruvboxDark = TerminalThemeDefinition(
        name: "Gruvbox Dark",
        isDark: true,
        background: "282828",
        foreground: "ebdbb2",
        cursorColor: "ebdbb2",
        selectionBackground: "504945",
        palette: [
            "282828", "cc241d", "98971a", "d79921",
            "458588", "b16286", "689d6a", "a89984",
            "928374", "fb4934", "b8bb26", "fabd2f",
            "83a598", "d3869b", "8ec07c", "ebdbb2",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let gruvboxMaterial = TerminalThemeDefinition(
        name: "Gruvbox Material",
        isDark: true,
        background: "1d2021",
        foreground: "d4be98",
        cursorColor: "d4be98",
        selectionBackground: "45403d",
        palette: [
            "32302f", "ea6962", "a9b665", "d8a657",
            "7daea3", "d3869b", "89b482", "d4be98",
            "45403d", "ea6962", "a9b665", "d8a657",
            "7daea3", "d3869b", "89b482", "d4be98",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let gruvboxLight = TerminalThemeDefinition(
        name: "Gruvbox Light",
        isDark: false,
        background: "fbf1c7",
        foreground: "3c3836",
        cursorColor: "3c3836",
        selectionBackground: "d5c4a1",
        palette: [
            "fbf1c7", "cc241d", "98971a", "d79921",
            "458588", "b16286", "689d6a", "7c6f64",
            "928374", "9d0006", "79740e", "b57614",
            "076678", "8f3f71", "427b58", "3c3836",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let monokaiPro = TerminalThemeDefinition(
        name: "Monokai Pro",
        isDark: true,
        background: "2d2a2e",
        foreground: "fcfcfa",
        cursorColor: "fcfcfa",
        selectionBackground: "5b595c",
        palette: [
            "2d2a2e", "ff6188", "a9dc76", "ffd866",
            "fc9867", "ab9df2", "78dce8", "fcfcfa",
            "5b595c", "ff6188", "a9dc76", "ffd866",
            "fc9867", "ab9df2", "78dce8", "fcfcfa",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let materialDark = TerminalThemeDefinition(
        name: "Material Dark",
        isDark: true,
        background: "212121",
        foreground: "eeffff",
        cursorColor: "ffcc00",
        selectionBackground: "3f51b5",
        palette: [
            "212121", "f07178", "c3e88d", "ffcb6b",
            "82aaff", "c792ea", "89ddff", "eeffff",
            "545454", "f07178", "c3e88d", "ffcb6b",
            "82aaff", "c792ea", "89ddff", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let ayuDark = TerminalThemeDefinition(
        name: "Ayu",
        isDark: true,
        background: "0f1419",
        foreground: "e6e1cf",
        cursorColor: "f29718",
        selectionBackground: "253340",
        palette: [
            "000000", "ff3333", "b8cc52", "e7c547",
            "36a3d9", "f07178", "95e6cb", "ffffff",
            "323232", "ff6565", "eafe84", "fff779",
            "68d5ff", "ffa3aa", "c7fffd", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let ayuMirage = TerminalThemeDefinition(
        name: "Ayu Mirage",
        isDark: true,
        background: "1f2430",
        foreground: "cbccc6",
        cursorColor: "ffcc66",
        selectionBackground: "33415e",
        palette: [
            "191e2a", "ff3333", "bae67e", "ffd580",
            "5ccfe6", "c2d94c", "95e6cb", "ffffff",
            "686868", "ff6565", "d5ff80", "ffefb3",
            "73d0ff", "f28779", "c7fffd", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let ayuLight = TerminalThemeDefinition(
        name: "Ayu Light",
        isDark: false,
        background: "fafafa",
        foreground: "5c6166",
        cursorColor: "ff9940",
        selectionBackground: "d9dbdd",
        palette: [
            "000000", "ff3333", "86b300", "f29718",
            "41a6d9", "f07178", "4dbf99", "ffffff",
            "323232", "ff6565", "b8e532", "ffc94a",
            "73d8ff", "ffa3aa", "7fdecb", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let darkPlus = TerminalThemeDefinition(
        name: "Dark+",
        isDark: true,
        background: "1e1e1e",
        foreground: "d4d4d4",
        cursorColor: "d4d4d4",
        selectionBackground: "264f78",
        palette: [
            "000000", "cd3131", "0dbc79", "e5e510",
            "2472c8", "bc3fbc", "11a8cd", "e5e5e5",
            "666666", "f14c4c", "23d18b", "f5f543",
            "3b8eea", "d670d6", "29b8db", "e5e5e5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let lightPlus = TerminalThemeDefinition(
        name: "Light+",
        isDark: false,
        background: "ffffff",
        foreground: "000000",
        cursorColor: "000000",
        selectionBackground: "add6ff",
        palette: [
            "000000", "cd3131", "00bc00", "949800",
            "0451a5", "bc05bc", "0598bc", "555555",
            "666666", "cd3131", "14ce14", "b5ba00",
            "0451a5", "bc05bc", "0598bc", "a5a5a5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let atomOneDark = TerminalThemeDefinition(
        name: "Atom One Dark",
        isDark: true,
        background: "282c34",
        foreground: "abb2bf",
        cursorColor: "528bff",
        selectionBackground: "3e4451",
        palette: [
            "282c34", "e06c75", "98c379", "e5c07b",
            "61afef", "c678dd", "56b6c2", "abb2bf",
            "545862", "e06c75", "98c379", "e5c07b",
            "61afef", "c678dd", "56b6c2", "c8ccd4",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let atomOneLight = TerminalThemeDefinition(
        name: "Atom One Light",
        isDark: false,
        background: "fafafa",
        foreground: "383a42",
        cursorColor: "526eff",
        selectionBackground: "e5e5e6",
        palette: [
            "000000", "e45649", "50a14f", "c18401",
            "4078f2", "a626a4", "0184bc", "a0a1a7",
            "5c6370", "e06c75", "98c379", "d19a66",
            "61afef", "c678dd", "56b6c2", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let nightOwl = TerminalThemeDefinition(
        name: "Night Owl",
        isDark: true,
        background: "011627",
        foreground: "d6deeb",
        cursorColor: "80a4c2",
        selectionBackground: "1d3b53",
        palette: [
            "011627", "ef5350", "22da6e", "c5e478",
            "82aaff", "c792ea", "21c7a8", "ffffff",
            "575656", "ef5350", "22da6e", "ffeb95",
            "82aaff", "c792ea", "7fdbca", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let vesper = TerminalThemeDefinition(
        name: "Vesper",
        isDark: true,
        background: "101010",
        foreground: "b7b7b7",
        cursorColor: "ffc799",
        selectionBackground: "232323",
        palette: [
            "101010", "de6e6e", "8ac47c", "ffc799",
            "60a9cf", "d7a5d7", "7dbfb0", "b7b7b7",
            "232323", "f87e7e", "99d58c", "ffd7a9",
            "70b9df", "e7b5e7", "8dcfc0", "c7c7c7",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let rosePine = TerminalThemeDefinition(
        name: "Rose Pine",
        isDark: true,
        background: "191724",
        foreground: "e0def4",
        cursorColor: "524f67",
        selectionBackground: "2a273f",
        palette: [
            "26233a", "eb6f92", "31748f", "f6c177",
            "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
            "6e6a86", "eb6f92", "31748f", "f6c177",
            "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let rosePineMoon = TerminalThemeDefinition(
        name: "Rose Pine Moon",
        isDark: true,
        background: "232136",
        foreground: "e0def4",
        cursorColor: "59546d",
        selectionBackground: "393552",
        palette: [
            "393552", "eb6f92", "3e8fb0", "f6c177",
            "9ccfd8", "c4a7e7", "ea9a97", "e0def4",
            "6e6a86", "eb6f92", "3e8fb0", "f6c177",
            "9ccfd8", "c4a7e7", "ea9a97", "e0def4",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let rosePineDawn = TerminalThemeDefinition(
        name: "Rose Pine Dawn",
        isDark: false,
        background: "faf4ed",
        foreground: "575279",
        cursorColor: "cecacd",
        selectionBackground: "dfdad9",
        palette: [
            "f2e9e1", "b4637a", "286983", "ea9d34",
            "56949f", "907aa9", "d7827e", "575279",
            "9893a5", "b4637a", "286983", "ea9d34",
            "56949f", "907aa9", "d7827e", "575279",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let kanagawaWave = TerminalThemeDefinition(
        name: "Kanagawa Wave",
        isDark: true,
        background: "1f1f28",
        foreground: "dcd7ba",
        cursorColor: "c8c093",
        selectionBackground: "2d4f67",
        palette: [
            "090618", "c34043", "76946a", "c0a36e",
            "7e9cd8", "957fb8", "6a9589", "c8c093",
            "727169", "e82424", "98bb6c", "e6c384",
            "7fb4ca", "938aa9", "7aa89f", "dcd7ba",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let kanagawaDragon = TerminalThemeDefinition(
        name: "Kanagawa Dragon",
        isDark: true,
        background: "181616",
        foreground: "c5c9c5",
        cursorColor: "c8c093",
        selectionBackground: "2d4f67",
        palette: [
            "0d0c0c", "c4746e", "8a9a7b", "c4b28a",
            "8ba4b0", "a292a3", "8ea4a2", "c8c093",
            "625e5a", "e46876", "87a987", "e6c384",
            "7fb4ca", "938aa9", "7aa89f", "c5c9c5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let kanagawaLotus = TerminalThemeDefinition(
        name: "Kanagawa Lotus",
        isDark: false,
        background: "f2ecbc",
        foreground: "545464",
        cursorColor: "43436c",
        selectionBackground: "c9cbd1",
        palette: [
            "1f1f28", "c84053", "6f894e", "77713f",
            "4d699b", "b35b79", "597b75", "545464",
            "8a8980", "d7474b", "6e915f", "836f4a",
            "6693bf", "624c83", "5e857a", "43436c",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let everforestDarkHard = TerminalThemeDefinition(
        name: "Everforest Dark Hard",
        isDark: true,
        background: "2b3339",
        foreground: "d3c6aa",
        cursorColor: "d3c6aa",
        selectionBackground: "3e4c54",
        palette: [
            "323c41", "e67e80", "a7c080", "dbbc7f",
            "7fbbb3", "d699b6", "83c092", "d3c6aa",
            "3e4c54", "e67e80", "a7c080", "dbbc7f",
            "7fbbb3", "d699b6", "83c092", "d3c6aa",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let everforestLightHard = TerminalThemeDefinition(
        name: "Everforest Light Hard",
        isDark: false,
        background: "fff9e8",
        foreground: "5c6a72",
        cursorColor: "5c6a72",
        selectionBackground: "edeada",
        palette: [
            "5c6a72", "f85552", "8da101", "dfa000",
            "3a94c5", "df69ba", "35a77c", "5c6a72",
            "a6b0a0", "f85552", "8da101", "dfa000",
            "3a94c5", "df69ba", "35a77c", "5c6a72",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let flexokiDark = TerminalThemeDefinition(
        name: "Flexoki Dark",
        isDark: true,
        background: "100f0f",
        foreground: "cecdc3",
        cursorColor: "cecdc3",
        selectionBackground: "282726",
        palette: [
            "282726", "af3029", "66800b", "ad8301",
            "205ea6", "a02f6f", "24837b", "cecdc3",
            "575653", "d14d41", "879a39", "d0a215",
            "4385be", "ce5d97", "3aa99f", "cecdc3",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let flexokiLight = TerminalThemeDefinition(
        name: "Flexoki Light",
        isDark: false,
        background: "fffcf0",
        foreground: "100f0f",
        cursorColor: "100f0f",
        selectionBackground: "e6e4d9",
        palette: [
            "575653", "af3029", "66800b", "ad8301",
            "205ea6", "a02f6f", "24837b", "100f0f",
            "282726", "d14d41", "879a39", "d0a215",
            "4385be", "ce5d97", "3aa99f", "100f0f",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let iTerm2SolarizedDark = TerminalThemeDefinition(
        name: "iTerm2 Solarized Dark",
        isDark: true,
        background: "002b36",
        foreground: "839496",
        cursorColor: "839496",
        selectionBackground: "073642",
        palette: [
            "073642", "dc322f", "859900", "b58900",
            "268bd2", "d33682", "2aa198", "eee8d5",
            "002b36", "cb4b16", "586e75", "657b83",
            "839496", "6c71c4", "93a1a1", "fdf6e3",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let iTerm2SolarizedLight = TerminalThemeDefinition(
        name: "iTerm2 Solarized Light",
        isDark: false,
        background: "fdf6e3",
        foreground: "657b83",
        cursorColor: "657b83",
        selectionBackground: "eee8d5",
        palette: [
            "073642", "dc322f", "859900", "b58900",
            "268bd2", "d33682", "2aa198", "eee8d5",
            "002b36", "cb4b16", "586e75", "657b83",
            "839496", "6c71c4", "93a1a1", "fdf6e3",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let adwaitaDark = TerminalThemeDefinition(
        name: "Adwaita Dark",
        isDark: true,
        background: "1e1e1e",
        foreground: "d4d4d4",
        cursorColor: "d4d4d4",
        selectionBackground: "3e4451",
        palette: [
            "171421", "c01c28", "26a269", "a2734c",
            "12488b", "a347ba", "2aa1b3", "d0cfcc",
            "5e5c64", "f66151", "33d17a", "e9ad0c",
            "2a7bde", "c061cb", "33c7de", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let adwaitaLight = TerminalThemeDefinition(
        name: "Adwaita Light",
        isDark: false,
        background: "ffffff",
        foreground: "2e3436",
        cursorColor: "2e3436",
        selectionBackground: "d6d6d6",
        palette: [
            "171421", "c01c28", "26a269", "a2734c",
            "12488b", "a347ba", "2aa1b3", "d0cfcc",
            "5e5c64", "f66151", "33d17a", "e9ad0c",
            "2a7bde", "c061cb", "33c7de", "ffffff",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let afterglow = TerminalThemeDefinition(
        name: "Afterglow",
        isDark: true,
        background: "2c2c2c",
        foreground: "d6d6d6",
        cursorColor: "d6d6d6",
        selectionBackground: "6c6c6c",
        palette: [
            "151515", "ac4142", "7e8e50", "e5b567",
            "6c99bb", "9f4e85", "7dd6cf", "d0d0d0",
            "505050", "ac4142", "7e8e50", "e5b567",
            "6c99bb", "9f4e85", "7dd6cf", "f5f5f5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let nvimDark = TerminalThemeDefinition(
        name: "Nvim Dark",
        isDark: true,
        background: "1a1a1a",
        foreground: "d4d4d4",
        cursorColor: "d4d4d4",
        selectionBackground: "3a3a3a",
        palette: [
            "1a1a1a", "f7768e", "9ece6a", "e0af68",
            "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
            "565656", "f7768e", "9ece6a", "e0af68",
            "7aa2f7", "bb9af7", "7dcfff", "c0caf5",
        ] + Array(repeating: nil, count: 240)
    )
    
    private static let nvimLight = TerminalThemeDefinition(
        name: "Nvim Light",
        isDark: false,
        background: "ffffff",
        foreground: "2e3440",
        cursorColor: "2e3440",
        selectionBackground: "e5e9f0",
        palette: [
            "fafafa", "c34043", "6a9a3c", "c08f31",
            "4c94c5", "b762a8", "3c94b5", "2e3440",
            "d5d5d5", "c34043", "6a9a3c", "c08f31",
            "4c94c5", "b762a8", "3c94b5", "1a1a1a",
        ] + Array(repeating: nil, count: 240)
    )
}
