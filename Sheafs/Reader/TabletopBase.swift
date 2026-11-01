import UIKit

/// Below the page in the tabletop pose: the surface the book stands on, and the rest of the book.
/// The page's bottom edge sits on a block of sheet edges, the pages still to read: thick at the
/// start of the book (the empty top of the deck below is its room), a few sheets at the end, with
/// a soft contact shadow under it, so the page reads as the top sheet of a book instead of a
/// colour that runs out at the fold. The top sheet's edge is the page's own: a turn lifts it off
/// with the leaf (`FlipUniforms.edge`), and the line left under the new page is the next sheet's,
/// there all along. It lies above the pages and below the flip view, which draws it as a texture
/// while a page turns (the turning leaf throws its shadow onto it).
final class TabletopBaseView: UIView {
    var palette = ReaderPalette.paper { didSet { if palette != oldValue { setNeedsDisplay() } } }
    /// Sheet edges drawn under the page, 1 … `maxSheets`.
    var sheets = 1 { didSet { if sheets != oldValue { setNeedsDisplay() } } }

    /// The whole book: 60 pt of sheets, about a paperback's thickness beside a page this tall.
    static let maxSheets = 48
    /// While any of the book is left at least this many show, so the block never runs out early.
    static let minSheets = 3
    /// The thickness of one sheet's edge, in points.
    static let sheetPitch: CGFloat = 1.25
    /// How far the contact shadow reaches below the block, in points.
    static let shadowDepth: CGFloat = 14

    /// Where the view starts for a page ending at `pageBottom`: on the whole pixel at or above it.
    /// 🔴 The page ends at the fold, 455.5 pt = 1366.5 px on the Duo, and the view begun there came
    /// out with a dark row along its top (an opaque backing store a pixel taller than what it
    /// draws): a line under the live page that the flip's texture of this view doesn't have, so it
    /// vanished at every turn and came back when the leaf landed. Rounded down, the view covers the
    /// page's half pixel row itself, as the flip does (`baseY`). `scripts/check-tabletop`.
    static func top(pageBottom: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(1, scale)
        return (pageBottom * scale).rounded(.down) / scale
    }

    /// The block for a place in the book: the pages still to read, from `maxSheets` at the start
    /// down to `minSheets` near the end; a single sheet only past the end.
    static func sheets(progress: Double) -> Int {
        let left = 1 - min(1, max(0, progress))
        guard left > 0 else { return 1 }
        return max(minSheets, 1 + Int((left * Double(maxSheets - 1)).rounded()))
    }

    /// What the texture cache keys on: anything that changes what this view draws.
    struct Signature: Equatable {
        var size: CGSize
        var sheets: Int
        var palette: ReaderPalette
    }

    var signature: Signature { Signature(size: bounds.size, sheets: sheets, palette: palette) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(palette.surface.cgColor)
        ctx.fill(bounds)

        let block = CGFloat(sheets) * Self.sheetPitch
        // The contact shadow: darkest right under the block, gone `shadowDepth` below it.
        let depth: CGFloat = palette.isDark ? 0.5 : 0.17
        let colors = [UIColor.black.withAlphaComponent(depth).cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: block, width: bounds.width, height: Self.shadowDepth))
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: block), end: CGPoint(x: 0, y: block + Self.shadowDepth), options: [])
            ctx.restoreGState()
        }

        // The sheets' edges, each a little further into shade than the one above it (the light
        // falls on the top of the block), with a hairline between them; the last one is the
        // bottom of the book. A sheet draws by its place from the top, whatever the block's size,
        // so the block under the next page is this one less a sheet at the bottom, or the same.
        let hairline = 1 / max(1, contentScaleFactor)
        for index in 0 ..< sheets {
            let y = CGFloat(index) * Self.sheetPitch
            let depth = 0.05 + 0.06 * min(1, CGFloat(index) / 30)
            ctx.setFillColor(Self.blend(palette.background, palette.text, depth).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: Self.sheetPitch))
            // Paper edges are never quite even: each hairline has its own weight.
            let line = index == sheets - 1 ? 0.24 : 0.06 + 0.09 * Self.grain(index)
            ctx.setFillColor(palette.text.withAlphaComponent(palette.isDark ? line * 0.7 : line).cgColor)
            ctx.fill(CGRect(x: 0, y: y + Self.sheetPitch - hairline, width: bounds.width, height: hairline))
        }
        // The page's own edge where it meets the block, crisp: drawn here, so the live view and the
        // turning leaf (which carries this row off with it, `sampleEdge`) show the same line.
        ctx.setFillColor(palette.text.withAlphaComponent(palette.isDark ? Self.edgeLine * 0.7 : Self.edgeLine).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: hairline))
    }

    /// The page edge's darkness (text colour alpha) along the top of the block.
    static let edgeLine: CGFloat = 0.22

    /// A fixed 0…1 for each sheet, so a sheet always draws the same.
    static func grain(_ index: Int) -> CGFloat {
        let hash = UInt32(truncatingIfNeeded: (index &+ 1) &* 0x9E37_79B1)
        return CGFloat(hash >> 24) / 255
    }

    static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}
