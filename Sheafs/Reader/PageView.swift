import UIKit

/// Draws one page of a paginated chapter plus its running footer.
final class PageView: UIView {
    struct Footer {
        var leading: String
        var trailing: String
    }

    var chapter: PaginatedChapter? { didSet { setNeedsDisplay() } }
    var page: Int = 0 { didSet { setNeedsDisplay() } }
    var palette: ReaderPalette = .paper { didSet { backgroundColor = palette.background; setNeedsDisplay() } }
    var textInsets: UIEdgeInsets = .zero { didSet { setNeedsDisplay() } }
    var footer = Footer(leading: "", trailing: "") { didSet { setNeedsDisplay() } }
    var footerFont = UIFont.preferredFont(forTextStyle: .footnote)

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
        drawFooter()
    }

    private func drawFooter() {
        let attrs: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: palette.secondary]
        let y = bounds.height - textInsets.bottom + 10
        let trailing = footer.trailing as NSString
        let trailingSize = trailing.size(withAttributes: attrs)
        trailing.draw(at: CGPoint(x: bounds.width - textInsets.right - trailingSize.width, y: y), withAttributes: attrs)
        let available = bounds.width - textInsets.left - textInsets.right - trailingSize.width - 16
        if available > 40 {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            var leadAttrs = attrs
            leadAttrs[.paragraphStyle] = para
            (footer.leading as NSString).draw(in: CGRect(x: textInsets.left, y: y, width: available, height: trailingSize.height + 2),
                                              withAttributes: leadAttrs)
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
