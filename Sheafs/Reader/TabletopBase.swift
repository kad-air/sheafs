import UIKit

/// Below the page in the tabletop pose: the surface the book stands on. The page's bottom edge
/// sits on a block of sheet edges (the pages still to come, thinner toward the end of the book)
/// with a soft contact shadow under it, so the page reads as a sheet with an edge instead of a
/// colour that runs out at the fold. It lies above the pages and below the flip view, which
/// draws it as a texture while a page turns (the turning leaf throws its shadow onto it).
final class TabletopBaseView: UIView {
    var palette = ReaderPalette.paper { didSet { if palette != oldValue { setNeedsDisplay() } } }
    /// Sheet edges drawn under the page, 1 … `maxSheets`.
    var sheets = 1 { didSet { if sheets != oldValue { setNeedsDisplay() } } }

    static let maxSheets = 7
    /// The thickness of one sheet's edge, in points.
    static let sheetPitch: CGFloat = 1.25
    /// How far the contact shadow reaches below the block, in points.
    static let shadowDepth: CGFloat = 14

    /// The block for a place in the book: thick at the start, one sheet at the end.
    static func sheets(progress: Double) -> Int {
        let left = 1 - min(1, max(0, progress))
        return 1 + Int((left * Double(maxSheets - 1)).rounded())
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

        // The sheets' edges, each a little further into shade than the one above it, with a
        // hairline between them; the last one is the bottom of the book.
        let hairline = 1 / max(1, contentScaleFactor)
        for index in 0 ..< sheets {
            let y = CGFloat(index) * Self.sheetPitch
            let depth = 0.05 + 0.05 * CGFloat(index) / CGFloat(Self.maxSheets - 1)
            ctx.setFillColor(Self.blend(palette.background, palette.text, depth).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: Self.sheetPitch))
            let line = index == sheets - 1 ? 0.24 : 0.12
            ctx.setFillColor(palette.text.withAlphaComponent(palette.isDark ? line * 0.7 : line).cgColor)
            ctx.fill(CGRect(x: 0, y: y + Self.sheetPitch - hairline, width: bounds.width, height: hairline))
        }
    }

    static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}
