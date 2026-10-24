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
        let width = bounds.width - textInsets.left - textInsets.right
        let lineHeight = marginFont.lineHeight + 2
        if !head.isEmpty {
            // Sits in the top band, just above the text.
            let y = max(6, textInsets.top - lineHeight - 10)
            (head as NSString).draw(in: CGRect(x: textInsets.left, y: y, width: width, height: lineHeight), withAttributes: attrs)
        }
        if !folio.isEmpty {
            let y = bounds.height - textInsets.bottom + 12
            (folio as NSString).draw(in: CGRect(x: textInsets.left, y: y, width: width, height: lineHeight), withAttributes: attrs)
        }
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
