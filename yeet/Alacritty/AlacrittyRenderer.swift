//
//  AlacrittyRenderer.swift
//  kero
//

import AppKit
import CoreText

/// Cell geometry and the four font faces a terminal grid needs.
///
/// The advance comes from the font's own digit width rather than
/// `maximumAdvancement`, which on many "monospace" faces is set by a wide
/// symbol and would space the grid out visibly.
struct AlacrittyMetrics {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Baseline measured down from the top of the cell.
    let baseline: CGFloat
    let fontThicken: Bool

    init(family: String, size: CGFloat, fontThicken: Bool) {
        let regular = TerminalFont.resolve(family: family, size: size)
        let manager = NSFontManager.shared
        self.regular = regular
        bold = manager.convert(regular, toHaveTrait: .boldFontMask)
        italic = manager.convert(regular, toHaveTrait: .italicFontMask)
        boldItalic = manager.convert(
            manager.convert(regular, toHaveTrait: .boldFontMask),
            toHaveTrait: .italicFontMask
        )

        let advance = AlacrittyMetrics.advance(of: regular)
        // Round to whole points so column positions stay on pixel boundaries
        // and glyphs do not shimmer as the grid scrolls.
        cellWidth = max(1, advance.rounded())
        let ascent = regular.ascender
        let descent = -regular.descender
        let leading = regular.leading
        cellHeight = max(1, (ascent + descent + leading).rounded())
        baseline = (ascent + leading / 2).rounded()
        self.fontThicken = fontThicken
    }

    private static func advance(of font: NSFont) -> CGFloat {
        var glyph = CGGlyph()
        var character: UniChar = 0x30 // "0"
        let ctFont = font as CTFont
        guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) else {
            return font.maximumAdvancement.width
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        return advance.width > 0 ? advance.width : font.maximumAdvancement.width
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
        switch (isBold, isItalic) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }
}

/// Packed-cell colours for the Metal grid. Inverse video and SGR 2 are
/// resolved here rather than in the bridge, so the snapshot keeps the
/// terminal's own colours and the renderer decides how to present them.
enum AlacrittyRenderer {
    static func foreground(of cell: KeroCell, default background: UInt32) -> UInt32 {
        var color = cell.flags & UInt16(KERO_CELL_INVERSE) != 0 ? cell.bg : cell.fg
        if cell.flags & UInt16(KERO_CELL_DIM) != 0 {
            color = dim(color)
        }
        if cell.flags & UInt16(KERO_CELL_SELECTED) != 0 {
            // Selection inverts, so the text takes the pane background.
            color = background
        }
        return color
    }

    static func background(of cell: KeroCell, default background: UInt32) -> UInt32 {
        if cell.flags & UInt16(KERO_CELL_SELECTED) != 0 {
            return cell.flags & UInt16(KERO_CELL_INVERSE) != 0 ? cell.bg : cell.fg
        }
        return cell.flags & UInt16(KERO_CELL_INVERSE) != 0 ? cell.fg : cell.bg
    }

    private static func dim(_ value: UInt32) -> UInt32 {
        let scale = { (channel: UInt32) in (channel * 2 / 3) & 0xff }
        return (scale((value >> 16) & 0xff) << 16)
            | (scale((value >> 8) & 0xff) << 8)
            | scale(value & 0xff)
    }

    static func color(_ packed: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((packed >> 16) & 0xff) / 255,
            green: CGFloat((packed >> 8) & 0xff) / 255,
            blue: CGFloat(packed & 0xff) / 255,
            alpha: 1
        )
    }
}
