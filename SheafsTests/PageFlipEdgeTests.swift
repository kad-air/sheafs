import Testing
import Metal
import UIKit
@testable import Sheafs

/// The page textures the turning leaf and the page beneath are drawn from. In the tabletop pose the
/// page ends at the fold, 455.5 pt down the Duo's inner display: 1366.5 px at 3×. The texture used
/// to draw the page at 3× into 1367 rows, so its last row was half painted (alpha 0.5) and the
/// shader, which reads the colour premultiplied, drew it as half-dark paper: a grey line across the
/// whole display for as long as a page turned. Every row of a page texture must be the page, opaque.
@MainActor
struct PageFlipEdgeTests {
    static func rows(pageHeight: Double, palette: ReaderPalette) throws -> [(alpha: Int, red: Int, green: Int, blue: Int)] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 668, height: pageHeight))
        page.palette = palette
        page.folio = "382"
        let texture = try #require(PageFlipView.texture(for: page, scale: 3, device: device))
        #expect(texture.height == Int((pageHeight * 3).rounded()))
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        // One pixel per row, a third of the way across (clear of the folio's text, if any).
        let x = texture.width / 3
        return (0..<texture.height).map { y in
            let i = y * bytesPerRow + x * 4   // BGRA
            return (alpha: Int(bytes[i + 3]), red: Int(bytes[i + 2]), green: Int(bytes[i + 1]), blue: Int(bytes[i]))
        }
    }

    @Test(arguments: [455.5, 455.0, 455.333, 951.0])
    func everyRowIsOpaquePaper(pageHeight: Double) throws {
        for palette in [ReaderPalette.paper, .night] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            palette.background.getRed(&r, green: &g, blue: &b, alpha: &a)
            let paper = (Int(r * 255), Int(g * 255), Int(b * 255))
            let rows = try Self.rows(pageHeight: pageHeight, palette: palette)
            // The edges are what went wrong; the middle rows are the control.
            for y in [0, 1, rows.count / 2, rows.count - 2, rows.count - 1] {
                let row = rows[y]
                #expect(row.alpha == 255, "row \(y) of \(rows.count) at \(pageHeight) pt: alpha \(row.alpha)")
                #expect(abs(row.red - paper.0) <= 2 && abs(row.green - paper.1) <= 2 && abs(row.blue - paper.2) <= 2,
                        "row \(y) of \(rows.count) at \(pageHeight) pt: \(row) is not the paper \(paper)")
            }
        }
    }
}
