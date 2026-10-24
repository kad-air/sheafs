import UIKit

/// Draws one page of a paginated chapter with a running head (top, centered) and a folio
/// (page number, bottom, centered), like a printed book.
final class PageView: UIView {
    var chapter: PaginatedChapter? { didSet { setNeedsDisplay() } }
    var page: Int = 0 { didSet { setNeedsDisplay() } }
    var palette: ReaderPalette = .paper { didSet { backgroundColor = palette.background; setNeedsDisplay() } }
    var textInsets: UIEdgeInsets = .zero { didSet { setNeedsDisplay() } }
    /// The running head: the book title on a left page, the chapter title on a right or single page.
    var head = "" { didSet { setNeedsDisplay() } }
    /// The page number.
    var folio = "" { didSet { setNeedsDisplay() } }
    /// Camera holes in this view's coordinates; the running head keeps clear of them.
    var occlusions: [CGRect] = [] { didSet { setNeedsDisplay() } }
    var marginFont = UIFont.preferredFont(forTextStyle: .footnote)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        backgroundColor = palette.background
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var textOrigin: CGPoint { CGPoint(x: textInsets.left, y: textInsets.top) }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(palette.background.cgColor)
        ctx.fill(bounds)
        chapter?.draw(page: page, at: textOrigin)
        drawMargins()
    }

    private func drawMargins() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: marginFont, .foregroundColor: palette.secondary, .paragraphStyle: para]
        let lineHeight = marginFont.lineHeight + 2
        if !head.isEmpty {
            let frame = Self.headFrame(bounds: bounds, textInsets: textInsets, lineHeight: lineHeight, occlusions: occlusions)
            (head as NSString).draw(in: frame, withAttributes: attrs)
        }
        if !folio.isEmpty {
            let frame = Self.folioFrame(bounds: bounds, textInsets: textInsets, lineHeight: lineHeight)
            (folio as NSString).draw(in: frame, withAttributes: attrs)
        }
    }

    /// Where the running head goes: centred over the text in the band above it, narrowed
    /// symmetrically so it stays clear of a camera hole in that band (the cover display's hole
    /// sits at the top right, in the vertical bar's strip).
    nonisolated static func headFrame(bounds: CGRect, textInsets: UIEdgeInsets, lineHeight: CGFloat,
                                      occlusions: [CGRect]) -> CGRect {
        let y = max(4, textInsets.top - lineHeight - 6)
        var left = textInsets.left
        var right = bounds.width - textInsets.right
        let center = (left + right) / 2
        for hole in occlusions where hole.minY < y + lineHeight && hole.maxY > y {
            if hole.midX >= center { right = min(right, hole.minX - 8) } else { left = max(left, hole.maxX + 8) }
        }
        let half = max(0, min(center - left, right - center))
        return CGRect(x: center - half, y: y, width: half * 2, height: lineHeight)
    }

    /// Where the folio goes: centred under the text, inside the footer band, above the home
    /// indicator's zone (the page frame already excludes it).
    nonisolated static func folioFrame(bounds: CGRect, textInsets: UIEdgeInsets, lineHeight: CGFloat) -> CGRect {
        let width = bounds.width - textInsets.left - textInsets.right
        return CGRect(x: textInsets.left, y: bounds.height - textInsets.bottom + 8, width: width, height: lineHeight)
    }

    override var accessibilityLabel: String? {
        get {
            guard let chapter else { return nil }
            let range = chapter.range(ofPage: page)
            return (chapter.textStorage.string as NSString).substring(with: range)
        }
        set {}
    }

    /// The character index under a point in this view's coordinates, if over text.
    func characterIndex(at point: CGPoint) -> Int? {
        guard let chapter else { return nil }
        let local = CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y)
        return chapter.characterIndex(at: local, page: page)
    }
}
