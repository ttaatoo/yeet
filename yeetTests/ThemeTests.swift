//
//  ThemeTests.swift
//  yeetTests
//

import AppKit
import XCTest
@testable import yeet

final class ThemeTests: XCTestCase {
    func testYeetDarkUsesWarmCanvasMintCursorAndOrangeSelection() {
        let theme = Theme.defaultDarkDefinition
        XCTAssertEqual(theme.name, "Yeet Dark")
        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.background, "0B0A09")
        XCTAssertEqual(theme.foreground, "E8E2DC")
        XCTAssertEqual(theme.cursorColor, Theme.progressHex)
        XCTAssertEqual(theme.selectionBackground, "5C2418")
        XCTAssertEqual(theme.palette[4], "58a6ff")
        XCTAssertEqual(theme.palette[5], "bc8cff")
        XCTAssertEqual(theme.palette[13], "d2a8ff")
    }

    func testYeetDarkKeepsGitHubDarkDefaultAvailableAsCatalogGitHubDark() {
        let githubDark = TerminalThemeCatalog.theme(named: "GitHub Dark Default")
        XCTAssertEqual(githubDark?.background, "0d1117")
        XCTAssertEqual(githubDark?.palette[5], "bc8cff")
        XCTAssertNotEqual(Theme.defaultDarkDefinition.background, githubDark?.background)
        XCTAssertNotEqual(Theme.defaultDarkDefinition.cursorColor, githubDark?.cursorColor)
    }

    func testYeetDarkAccentUsesMascotOrangeNotAnsiBlue() {
        let accent = Theme.defaultDarkDefinition.accentNSColor
        let expected = nsColor(Theme.accentHex)
        XCTAssertEqual(accent.redComponent, expected.redComponent, accuracy: 0.001)
        XCTAssertEqual(accent.greenComponent, expected.greenComponent, accuracy: 0.001)
        XCTAssertEqual(accent.blueComponent, expected.blueComponent, accuracy: 0.001)
    }

    func testCatalogNamesResolveAndUnknownNamesDoNot() {
        XCTAssertTrue(Theme.isCommonTheme(named: Theme.defaultDarkThemeName, dark: true))
        XCTAssertTrue(Theme.isCommonTheme(named: Theme.defaultLightThemeName, dark: false))
        XCTAssertTrue(Theme.isCommonTheme(named: Theme.legacyDefaultDarkThemeName, dark: true))
        XCTAssertTrue(Theme.isCommonTheme(named: Theme.legacyDefaultLightThemeName, dark: false))
        XCTAssertFalse(Theme.isCommonTheme(named: Theme.defaultDarkThemeName, dark: false))
        XCTAssertNil(Theme.definition(named: "not-a-real-theme"))
        XCTAssertEqual(Theme.definition(named: "GitHub Dark")?.name, "GitHub Dark")
        XCTAssertEqual(Theme.definition(named: "Default Dark")?.name, Theme.defaultDarkThemeName)
        XCTAssertEqual(Theme.definition(named: "Default Light")?.name, Theme.defaultLightThemeName)
        XCTAssertEqual(Theme.commonDarkThemes.first?.name, Theme.defaultDarkThemeName)
        XCTAssertEqual(Theme.commonLightThemes.first?.name, Theme.defaultLightThemeName)
        XCTAssertLessThanOrEqual(Theme.commonDarkThemes.count, 30)
        XCTAssertLessThanOrEqual(Theme.commonLightThemes.count, 30)
        XCTAssertGreaterThan(Theme.commonDarkThemes.count, 1)
        XCTAssertGreaterThan(Theme.commonLightThemes.count, 1)
        XCTAssertEqual(
            Set(Theme.commonDarkThemes.map(\.name)).count,
            Theme.commonDarkThemes.count
        )
        XCTAssertEqual(
            Set(Theme.commonLightThemes.map(\.name)).count,
            Theme.commonLightThemes.count
        )
    }

    func testYeetLightUsesWarmPaperAndDeepMintCursor() {
        let light = Theme.defaultLightDefinition
        XCTAssertEqual(light.name, "Yeet Light")
        XCTAssertFalse(light.isDark)
        XCTAssertEqual(light.background, "F7F1EA")
        XCTAssertEqual(light.foreground, "1F1A16")
        XCTAssertEqual(light.cursorColor, Theme.progressLightHex)
        XCTAssertEqual(light.selectionBackground, "F0C2B0")
        let github = TerminalThemeCatalog.theme(named: "GitHub Light Default")
        XCTAssertNotEqual(light.background, github?.background)
        XCTAssertNotEqual(light.cursorColor, github?.cursorColor)
    }

    func testDarkChromeSitsOneStepAboveTheTerminalCanvas() {
        assertColor(Theme.sidebarFill(dark: true), "161412")
        XCTAssertNotEqual(Theme.defaultDarkDefinition.background, "161412")
        XCTAssertEqual(Theme.defaultDarkDefinition.background, "0B0A09")

        let dark = NSAppearance(named: .darkAqua)!
        assertColor(resolved(Theme.chromeHeader, appearance: dark), "161412")
        assertColor(resolved(Theme.chromeAccent, appearance: dark), Theme.accentHex)
        assertColor(resolved(Theme.chromeProgress, appearance: dark), Theme.progressHex)
        assertColor(resolved(Theme.chromeSelected, appearance: dark), "2A2420")
    }

    private func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: color.cgColor) ?? color
        }
        return result
    }

    private func assertColor(_ color: NSColor, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = nsColor(hex)
        let actual = color.usingColorSpace(.sRGB) ?? color
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
    }

    private func nsColor(_ hex: String) -> NSColor {
        let value = Int(hex, radix: 16)!
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }
}
