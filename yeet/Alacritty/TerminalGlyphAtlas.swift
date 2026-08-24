//
//  TerminalGlyphAtlas.swift
//  kero
//

import AppKit
import CoreText
import Metal
import simd

/// Rasterized glyphs packed into one Metal texture.
///
/// The GPU renderer draws a textured quad per cell, so every glyph has to
/// exist somewhere in a texture first. CoreText does the rasterizing — the
/// same path the CPU renderer used — which keeps font matching, hinting and
/// the system fallback chain identical to the rest of Kero. Only the
/// compositing moves to the GPU.
///
/// Packing is a shelf allocator: glyphs are appended along a row until it is
/// full, then a new row starts below. Growing copies the packed region into a
/// larger texture so rasterized glyphs and shelf state stay valid. At the
/// maximum size, glyphs not requested since the last full rebuild are evicted
/// and survivors are re-packed; a frame whose unique glyphs still cannot fit
/// leaves the remainder blank.
final class TerminalGlyphAtlas {
    enum Content: Hashable {
        case scalar(UInt32)
        case cluster(Data)

        var string: String? {
            switch self {
            case .scalar(let value):
                Unicode.Scalar(value).map(String.init)
            case .cluster(let data):
                String(data: data, encoding: .utf8)
            }
        }
    }

    struct Key: Hashable {
        let content: Content
        let bold: Bool
        let italic: Bool
    }

    /// Where a glyph lives in the atlas, and how to place it in its cell.
    struct Entry {
        /// Normalized texture coordinates.
        let uvOrigin: SIMD2<Float>
        let uvSize: SIMD2<Float>
        /// Size in points.
        let size: SIMD2<Float>
        /// Offset from the cell's text origin to the glyph's bottom-left.
        let bearing: SIMD2<Float>
        /// Color glyphs (emoji) carry their own RGB values instead of using
        /// the terminal cell's foreground color.
        let isColor: Bool
        /// Pixel rect in the atlas. Grow rescales UVs from this; compact
        /// blits it without running CoreText again.
        fileprivate let pixelX: Int
        fileprivate let pixelY: Int
        fileprivate let pixelWidth: Int
        fileprivate let pixelHeight: Int

        fileprivate func withAtlasDimension(_ dimension: Int) -> Entry {
            relocated(pixelX: pixelX, pixelY: pixelY, atlasDimension: dimension)
        }

        fileprivate func relocated(
            pixelX: Int,
            pixelY: Int,
            atlasDimension: Int
        ) -> Entry {
            let d = Float(atlasDimension)
            return Entry(
                uvOrigin: SIMD2(Float(pixelX) / d, Float(pixelY) / d),
                uvSize: SIMD2(Float(pixelWidth) / d, Float(pixelHeight) / d),
                size: size,
                bearing: bearing,
                isColor: isColor,
                pixelX: pixelX,
                pixelY: pixelY,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    private static let initialDimension = 1024
    private static let maximumDimension = 2048

    private let device: MTLDevice
    private(set) var texture: MTLTexture
    private(set) var generation: UInt64 = 0
    private var dimension: Int
    private var scale: CGFloat
    private var entries: [Key: Entry] = [:]
    /// Keys requested since the last live census. Clean rows skip
    /// `entry(for:)`, so this set is only complete after a full rebuild.
    private var live: Set<Key> = []
    /// True after a full rebuild finished marking `live`. Compact refuses to
    /// evict before that so dirty-row reuse cannot drop on-screen glyphs.
    private var liveComplete = false

    /// Shelf state, in device pixels.
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    /// New glyphs did not fit after grow and compact. Cleared when packing
    /// changes; not latched across a successful reclaim.
    private(set) var isFull = false
    /// Overflow happened on a pass whose live set is not this frame's
    /// on-screen glyphs. The renderer rebuilds every row once, then compact
    /// can evict the rest.
    private(set) var needsLiveCensus = false

    private var metrics: AlacrittyMetrics

    init?(device: MTLDevice, metrics: AlacrittyMetrics, scale: CGFloat) {
        let dimension = Self.initialDimension
        guard let texture = Self.makeTexture(device: device, dimension: dimension)
        else { return nil }
        self.device = device
        self.texture = texture
        self.dimension = dimension
        self.metrics = metrics
        self.scale = max(scale, 1)
    }

    /// Drops every glyph. Called when the font or the backing scale changes,
    /// since both invalidate the rasterization.
    func reset(metrics: AlacrittyMetrics, scale: CGFloat) {
        guard metrics.cellWidth != self.metrics.cellWidth
            || metrics.cellHeight != self.metrics.cellHeight
            || metrics.regular != self.metrics.regular
            || metrics.fontThicken != self.metrics.fontThicken
            || scale != self.scale
        else { return }
        self.metrics = metrics
        self.scale = max(scale, 1)
        entries.removeAll(keepingCapacity: true)
        live.removeAll(keepingCapacity: true)
        liveComplete = false
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        isFull = false
        needsLiveCensus = false
        generation &+= 1
    }

    /// Drop historical live marks so the following full rebuild records only
    /// glyphs that are on screen this pass.
    func beginLiveCensus() {
        live.removeAll(keepingCapacity: true)
        liveComplete = false
    }

    /// The just-finished full rebuild called `entry(for:)` for every on-screen
    /// glyph, so compact may evict the rest.
    func markLiveComplete() {
        liveComplete = true
        needsLiveCensus = false
    }

    /// Evict packed glyphs that are not in the live set. Returns true when
    /// packing changed and cached instance UVs must be rebuilt.
    func reclaimUnused() -> Bool {
        guard isFull else { return false }
        return compact()
    }

    /// The atlas entry for a glyph, rasterizing it on first use. Nil for a
    /// glyph with no ink (a space) or once the atlas is full.
    func entry(for key: Key) -> Entry? {
        live.insert(key)
        if let cached = entries[key] { return cached }
        guard !isFull, let text = key.content.string else { return nil }
        guard let rasterized = rasterize(text: text, bold: key.bold, italic: key.italic)
        else { return nil }
        entries[key] = rasterized
        return rasterized
    }

    // MARK: - Rasterization

    private func rasterize(text: String, bold: Bool, italic: Bool) -> Entry? {
        let font = metrics.font(bold: bold, italic: italic)
        // CTLine rather than raw glyph drawing: it runs the system fallback
        // chain, so emoji and Nerd Font icons rasterize the same way they did
        // on the CPU path instead of coming out as missing-glyph boxes.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        var attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        let isColor = containsColorGlyphs(line)
        if metrics.fontThicken, !isColor {
            // CoreText's negative stroke width fills and expands the glyph.
            // Two percent is close to Ghostty's subtle one-pixel thickening
            // without changing the grid advance. Color emoji keep their
            // original artwork rather than receiving a white outline.
            attributes[.strokeColor] = NSColor.white
            attributes[.strokeWidth] = -2
            attributed = NSAttributedString(string: text, attributes: attributes)
            line = CTLineCreateWithAttributedString(attributed)
        }
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // A pixel of bleed on each side keeps linear sampling from picking up
        // a neighbour's ink along the shared edge.
        let padding: CGFloat = 1
        let pixelWidth = Int(((bounds.width + padding * 2) * scale).rounded(.up))
        let pixelHeight = Int(((bounds.height + padding * 2) * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        if pixelWidth > Self.maximumDimension || pixelHeight > Self.maximumDimension {
            return nil
        }
        while (pixelWidth > dimension || pixelHeight > dimension) && grow() {}
        guard pixelWidth <= dimension, pixelHeight <= dimension else { return nil }

        guard let origin = allocate(width: pixelWidth, height: pixelHeight) else { return nil }

        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: space,
                bitmapInfo: bitmapInfo
            )
        }) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        // The atlas stores grayscale coverage, not an opaque LCD surface.
        // Core Graphics font smoothing strengthens that coverage even when
        // `fontThicken` is off, making Alacritty's regular face look heavier
        // than the same font in Ghostty. Keep normal antialiasing, and let the
        // explicit stroke above be the only opt-in thickening pass.
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        // Draw relative to the glyph's own bounds so the bearing below is the
        // only thing that positions it in the cell.
        context.textPosition = CGPoint(x: -bounds.minX + padding, y: -bounds.minY + padding)
        CTLineDraw(line, context)

        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: pixelWidth * 4
        )

        return Entry(
            uvOrigin: .zero,
            uvSize: .zero,
            size: SIMD2(Float(pixelWidth) / Float(scale), Float(pixelHeight) / Float(scale)),
            bearing: SIMD2(Float(bounds.minX - padding), Float(bounds.minY - padding)),
            isColor: isColor,
            pixelX: origin.x,
            pixelY: origin.y,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ).withAtlasDimension(dimension)
    }

    /// CoreText's fallback run tells us whether the resolved face has an
    /// intrinsic color table (`sbix`, `COLR`, or SVG). Checking the actual run
    /// matters: the configured monospace face is not a color font, but its
    /// fallback for emoji is Apple Color Emoji.
    private func containsColorGlyphs(_ line: CTLine) -> Bool {
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { continue }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).rawValue & (1 << 13) != 0 {
                return true
            }
        }
        return false
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if let origin = place(width: width, height: height) {
            return origin
        }
        if dimension < Self.maximumDimension, grow() {
            return allocate(width: width, height: height)
        }
        if liveComplete, compact() {
            return place(width: width, height: height)
        }
        isFull = true
        needsLiveCensus = true
        return nil
    }

    /// Place on the current shelf, or the next one, without growing. Shelf
    /// state is unchanged on failure so a subsequent grow can keep packing
    /// into the extra columns of the same row.
    private func place(width: Int, height: Int) -> (x: Int, y: Int)? {
        var x = shelfX
        var y = shelfY
        var rowHeight = shelfHeight
        if x + width > dimension {
            guard x > 0 else { return nil }
            x = 0
            y += rowHeight
            rowHeight = 0
        }
        guard y + height <= dimension else { return nil }
        let origin = (x: x, y: y)
        shelfX = x + width
        shelfY = y
        shelfHeight = max(rowHeight, height)
        return origin
    }

    /// Most terminal sessions use far fewer than a thousand distinct glyph
    /// variants, which fit comfortably in a 1024² atlas (4 MiB). Grow to the
    /// previous 2048² capacity only for a session that actually needs it.
    ///
    /// The packed region is copied into the larger texture and UVs are
    /// rebuilt from stored pixel rects. The renderer observes `generation`
    /// and refreshes cached instance UVs with no CoreText.
    private func grow() -> Bool {
        guard dimension < Self.maximumDimension else { return false }
        let nextDimension = min(dimension * 2, Self.maximumDimension)
        guard let nextTexture = Self.makeTexture(device: device, dimension: nextDimension)
        else { return false }

        let usedHeight = min(dimension, max(shelfY + shelfHeight, 0))
        if usedHeight > 0 {
            copyPixels(
                from: texture,
                sourceOrigin: (0, 0),
                size: (dimension, usedHeight),
                to: nextTexture,
                destinationOrigin: (0, 0)
            )
        }

        for (key, entry) in entries {
            entries[key] = entry.withAtlasDimension(nextDimension)
        }
        texture = nextTexture
        dimension = nextDimension
        live.removeAll(keepingCapacity: true)
        liveComplete = false
        isFull = false
        needsLiveCensus = false
        generation &+= 1
        return true
    }

    /// Keep glyphs requested since the last complete census, re-pack them at
    /// the origin, and drop the rest. Pixel rects are blitted so survivors
    /// do not run CoreText again.
    private func compact() -> Bool {
        let survivors = entries.filter { live.contains($0.key) }
        guard survivors.count < entries.count else { return false }

        let usedHeight = min(dimension, max(shelfY + shelfHeight, 0))
        let oldDimension = dimension
        let oldTexture = texture
        let oldPixels = usedHeight > 0
            ? readPixels(from: oldTexture, width: oldDimension, height: usedHeight)
            : nil

        guard let nextTexture = Self.makeTexture(device: device, dimension: dimension)
        else { return false }

        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        isFull = false
        needsLiveCensus = false
        entries.removeAll(keepingCapacity: true)

        // Tallest first: shelf packing waste depends on insert order, and
        // these rects already fit once.
        let ordered = survivors.sorted {
            if $0.value.pixelHeight != $1.value.pixelHeight {
                return $0.value.pixelHeight > $1.value.pixelHeight
            }
            return $0.value.pixelWidth > $1.value.pixelWidth
        }
        for (key, entry) in ordered {
            guard let origin = place(width: entry.pixelWidth, height: entry.pixelHeight)
            else { continue }
            if let oldPixels, entry.pixelY + entry.pixelHeight <= usedHeight {
                writeGlyph(
                    from: oldPixels,
                    sourceWidth: oldDimension,
                    sourceX: entry.pixelX,
                    sourceY: entry.pixelY,
                    width: entry.pixelWidth,
                    height: entry.pixelHeight,
                    to: nextTexture,
                    destinationX: origin.x,
                    destinationY: origin.y
                )
            }
            entries[key] = entry.relocated(
                pixelX: origin.x,
                pixelY: origin.y,
                atlasDimension: dimension
            )
        }

        texture = nextTexture
        live.removeAll(keepingCapacity: true)
        liveComplete = false
        generation &+= 1
        return true
    }

    private static func makeTexture(device: MTLDevice, dimension: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    private func copyPixels(
        from source: MTLTexture,
        sourceOrigin: (x: Int, y: Int),
        size: (width: Int, height: Int),
        to destination: MTLTexture,
        destinationOrigin: (x: Int, y: Int)
    ) {
        guard size.width > 0, size.height > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        source.getBytes(
            &bytes,
            bytesPerRow: size.width * 4,
            from: MTLRegionMake2D(
                sourceOrigin.x, sourceOrigin.y, size.width, size.height
            ),
            mipmapLevel: 0
        )
        destination.replace(
            region: MTLRegionMake2D(
                destinationOrigin.x, destinationOrigin.y, size.width, size.height
            ),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: size.width * 4
        )
    }

    private func readPixels(
        from texture: MTLTexture,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return bytes
    }

    private func writeGlyph(
        from source: [UInt8],
        sourceWidth: Int,
        sourceX: Int,
        sourceY: Int,
        width: Int,
        height: Int,
        to texture: MTLTexture,
        destinationX: Int,
        destinationY: Int
    ) {
        guard width > 0, height > 0 else { return }
        let end = ((sourceY + height - 1) * sourceWidth + sourceX + width) * 4
        guard end <= source.count else { return }
        source.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let start = base + (sourceY * sourceWidth + sourceX) * 4
            texture.replace(
                region: MTLRegionMake2D(destinationX, destinationY, width, height),
                mipmapLevel: 0,
                withBytes: start,
                bytesPerRow: sourceWidth * 4
            )
        }
    }
}
