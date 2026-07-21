import AppKit
import CoreText

/// Geometry for drawing a replacement bullet with its ink centered in the
/// actual TextKit line fragment while retaining the source marker's advance.
struct BulletMarkerGeometry {
    /// A small optical correction in the flipped drawing coordinate space.
    /// Exact ink centering reads slightly high beside system body text.
    static let opticalOffsetY: CGFloat = 0.5

    let drawOrigin: CGPoint
    let renderedGlyphBounds: CGRect

    static func make(
        markerOriginX: CGFloat,
        markerWidth: CGFloat,
        lineBounds: CGRect,
        font: NSFont
    ) -> BulletMarkerGeometry? {
        let coreTextFont = font as CTFont
        var character = UniChar(0x2022)
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(coreTextFont, &character, &glyph, 1) else {
            return nil
        }

        var glyphBounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(coreTextFont, .horizontal, &glyph, &glyphBounds, 1)
        guard !glyphBounds.isNull, !glyphBounds.isEmpty else { return nil }

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(coreTextFont, .horizontal, &glyph, &advance, 1)

        let drawOrigin = CGPoint(
            x: markerOriginX + max(0, (markerWidth - advance.width) / 2),
            y: lineBounds.midY + glyphBounds.midY - font.ascender + opticalOffsetY
        )
        let baselineY = drawOrigin.y + font.ascender
        let renderedGlyphBounds = CGRect(
            x: drawOrigin.x + glyphBounds.minX,
            y: baselineY - glyphBounds.maxY,
            width: glyphBounds.width,
            height: glyphBounds.height
        )
        return BulletMarkerGeometry(
            drawOrigin: drawOrigin,
            renderedGlyphBounds: renderedGlyphBounds
        )
    }
}
