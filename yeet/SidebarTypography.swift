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
        if family.isEmpty {
            return .system(size: size, weight: weight, design: design)
        }

        let nsWeight = nsFontWeight(weight)
        if let nsFont = NSFontManager.shared.font(
            withFamily: family,
            traits: fontTraits(weight),
            weight: nsWeight,
            size: size
        ) {
            return Font(nsFont)
        }

        // Bundled JetBrains Mono is registered for this process; family
        // lookup can still miss it before faces have been enumerated.
        if family == TerminalFont.bundledFamily {
            return Font(TerminalFont.resolve(family: family, size: size))
                .weight(weight)
        }

        return .custom(family, size: size).weight(weight)
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
