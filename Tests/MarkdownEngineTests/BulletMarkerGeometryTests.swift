import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
struct BulletMarkerGeometryTests {
    @Test("Bullet ink applies its optical offset from the line center", arguments: [
        (CGFloat(13), CGFloat(18), false),
        (CGFloat(16), CGFloat(24), false),
        (CGFloat(22), CGFloat(32), true),
    ])
    func centersBulletInk(fontSize: CGFloat, lineHeight: CGFloat, isBold: Bool) throws {
        let font = isBold
            ? NSFont.boldSystemFont(ofSize: fontSize)
            : NSFont.systemFont(ofSize: fontSize)
        let lineBounds = CGRect(x: 8, y: 12, width: 240, height: lineHeight)
        let geometry = try #require(BulletMarkerGeometry.make(
            markerOriginX: 20,
            markerWidth: 12,
            lineBounds: lineBounds,
            font: font
        ))

        let expectedMidY = lineBounds.midY + BulletMarkerGeometry.opticalOffsetY
        #expect(abs(geometry.renderedGlyphBounds.midY - expectedMidY) < 0.001)
    }

    @Test("Bullet origin stays within the source marker advance")
    func preservesMarkerAdvance() throws {
        let markerOriginX: CGFloat = 20
        let markerWidth: CGFloat = 18
        let geometry = try #require(BulletMarkerGeometry.make(
            markerOriginX: markerOriginX,
            markerWidth: markerWidth,
            lineBounds: CGRect(x: 0, y: 0, width: 200, height: 24),
            font: .systemFont(ofSize: 16)
        ))

        #expect(geometry.drawOrigin.x >= markerOriginX)
        #expect(geometry.drawOrigin.x < markerOriginX + markerWidth)
    }
}
