//
//  SidebarTypography.swift
//  kero
//

import AppKit
import SwiftUI

private struct SidebarFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct SidebarFontFamilyKey: EnvironmentKey {
    /// Empty means the system UI font — the default for every sidebar
    /// except the Files tree, which can override this with a chosen family.
    static let defaultValue = ""
}

extension EnvironmentValues {
    var sidebarFontScale: CGFloat {
        get { self[SidebarFontScaleKey.self] }
        set { self[SidebarFontScaleKey.self] = newValue }
    }

    var sidebarFontFamily: String {
        get { self[SidebarFontFamilyKey.self] }
        set { self[SidebarFontFamilyKey.self] = newValue }
    }
}

/// Scales a sidebar font from its designed size while preserving the relative
/// hierarchy between section labels, content, metadata, and controls.
///
/// An empty `sidebarFontFamily` keeps the system UI font. A non-empty family
/// resolves through the same faces as the terminal picker (including bundled
/// JetBrains Mono).
enum SidebarTypography {
    /// Designed file-name size in `FileTreeRow`. Files settings use
    /// `files.font-size / designedFileNameSize` as `sidebarFontScale`.
    static let designedFileNameSize: CGFloat = 11.5

    static func font(
        family: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        Font(nsFont(family: family, size: size, weight: weight, design: design))
    }

    /// AppKit counterpart of `font(family:size:weight:design:)`. Files/Git
    /// inspector rows paint with NSFont so a SwiftUI environment is not required.
    static func nsFont(
        family: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> NSFont {
        let nsWeight = nsFontWeightValue(weight)
        if family.isEmpty {
            if design == .monospaced {
                return .monospacedSystemFont(ofSize: size, weight: nsWeight)
            }
            return .systemFont(ofSize: size, weight: nsWeight)
        }

        if let matched = NSFontManager.shared.font(
            withFamily: family,
            traits: fontTraits(weight),
            weight: nsFontWeight(weight),
            size: size
        ) {
            return matched
        }

        // Bundled JetBrains Mono is registered for this process; family
        // lookup can still miss it before faces have been enumerated.
        if family == TerminalFont.bundledFamily {
            return TerminalFont.resolve(family: family, size: size)
        }

        return NSFont(name: family, size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
    }

    private static func nsFontWeightValue(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    private static func nsFontWeight(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        case .black: return 11
        default: return 5
        }
    }

    private static func fontTraits(_ weight: Font.Weight) -> NSFontTraitMask {
        switch weight {
        case .bold, .heavy, .black:
            return .boldFontMask
        default:
            return []
        }
    }
}

private struct SidebarFontModifier: ViewModifier {
    @Environment(\.sidebarFontScale) private var scale
    @Environment(\.sidebarFontFamily) private var family

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(
            SidebarTypography.font(
                family: family,
                size: size * scale,
                weight: weight,
                design: design
            )
        )
    }
}

extension View {
    func sidebarFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(SidebarFontModifier(size: size, weight: weight, design: design))
    }
}
