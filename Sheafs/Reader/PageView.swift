import UIKit
import PencilKit
import SheafsKit

/// Draws one page of a paginated chapter with a running head (top, centered) and a folio
/// (page number, bottom, centered), like a printed book.
final class PageView: UIView {
    var chapter: PaginatedChapter? { didSet { placedSketches = nil; setNeedsDisplay() } }
    var page: Int = 0 { didSet { placedSketches = nil; setNeedsDisplay() } }
    var palette: ReaderPalette = .paper { didSet { backgroundColor = palette.background; setNeedsDisplay() } }
    var textInsets: UIEdgeInsets = .zero { didSet { placedSketches = nil; setNeedsDisplay() } }
    /// The running head: the book title on a left page, the chapter title on a right or single page.
    var head = "" { didSet { setNeedsDisplay() } }
    /// The page number.
    var folio = "" { didSet { setNeedsDisplay() } }
    /// The cover camera's hole in this view's coordinates; the running head keeps clear of it.
    var camera: CGRect? { didSet { setNeedsDisplay() } }
    /// The page stands on the fold (tabletop): its last points turn away from the light as the
    /// paper curves over the hinge. Drawn under the text, and carried by the turning leaf.
    var curvesOverFold = false { didSet { if curvesOverFold != oldValue { setNeedsDisplay() } } }
    static let foldCurve: CGFloat = 22
    /// Highlights of this page's chapter (any page; the view keeps what falls on its own).
    var marks: [HighlightMark] = [] { didSet { if marks != oldValue { setNeedsDisplay() } } }
    /// The live text selection, in chapter coordinates, drawn over the glyphs like iOS does.
    var selection: NSRange? { didSet { if selection != oldValue { setNeedsDisplay() } } }
    /// Pencil markings of this page's chapter (any page; the view draws the strokes whose
    /// characters are on its own, `SketchLayout.place`).
    var sketches: [SketchMark] = [] { didSet { if sketches != oldValue { placedSketches = nil; setNeedsDisplay() } } }
    /// While the page is marked up its strokes are on the canvas over it, not drawn by the page.
    var hidesSketches = false { didSet { if hidesSketches != oldValue { setNeedsDisplay() } } }
    private var placedSketches: [SketchLayout.Placed]?
    /// The page holds a bookmark: a ribbon hangs from its top edge.
    var isBookmarked = false { didSet { if isBookmarked != oldValue { setNeedsDisplay() } } }
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
        if curvesOverFold { drawFoldCurve(ctx) }
        drawMarks(ctx)
        chapter?.draw(page: page, at: textOrigin)
        if !hidesSketches { drawSketches(ctx) }
        drawSelection(ctx)
        drawMargins()
        drawRibbon(ctx)
    }

    /// The bookmark ribbon: a band in the theme's accent hanging from the top edge with a notch
    /// cut into its end, over the text's right edge (left of the cover camera when that is there).
    /// Drawn, not added to the text, like the highlights.
    private func drawRibbon(_ ctx: CGContext) {
        guard isBookmarked else { return }
        let frame = Self.ribbonFrame(bounds: bounds, textInsets: textInsets, camera: camera)
        let notch = min(6, frame.height / 4)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: frame.minX, y: frame.minY))
        ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
        ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        ctx.addLine(to: CGPoint(x: frame.midX, y: frame.maxY - notch))
        ctx.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
        ctx.closePath()
        ctx.setFillColor(palette.link.cgColor)
        ctx.fillPath()
    }

    nonisolated static let ribbonSize = CGSize(width: 14, height: 30)

    /// Where the ribbon hangs: from the page's top edge, its right side on the text's right edge,
    /// within the head band (it never reaches the text). Where the cover camera's hole is near
    /// (the cover display in portrait), it moves to the left of the hole.
    nonisolated static func ribbonFrame(bounds: CGRect, textInsets: UIEdgeInsets, camera: CGRect?) -> CGRect {
        let height = min(ribbonSize.height, max(12, textInsets.top - 6))
        var frame = CGRect(x: bounds.width - textInsets.right - ribbonSize.width, y: 0,
                           width: ribbonSize.width, height: height)
        if let hole = camera, frame.insetBy(dx: -6, dy: -6).intersects(hole) {
            frame.origin.x = hole.minX - 10 - ribbonSize.width
        }
        return frame
    }

    private func drawFoldCurve(_ ctx: CGContext) {
        let depth: CGFloat = palette.isDark ? 0.3 : 0.055
        let colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(depth).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        let top = bounds.maxY - Self.foldCurve
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: top, width: bounds.width, height: Self.foldCurve))
        // Eased toward the edge, like light falling off a curve, not a straight ramp.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top + Self.foldCurve * 0.35), end: CGPoint(x: 0, y: bounds.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Highlights go under the glyphs (a translucent band, or a 2 pt underline); the text stays crisp.
    private func drawMarks(_ ctx: CGContext) {
        for mark in marks where !mark.isFound {
            let rects = rects(for: mark.range)
            guard !rects.isEmpty else { continue }
            if mark.isUnderline {
                ctx.setFillColor(mark.color.underline(dark: palette.isDark).cgColor)
                for rect in rects { ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2.5, width: rect.width, height: 2)) }
            } else {
                ctx.setFillColor(mark.color.fill(dark: palette.isDark).cgColor)
                for rect in rects { ctx.fill(rect.insetBy(dx: -1, dy: 0.5)) }
            }
        }
        drawFound(ctx)
    }

    /// Search hits: a rounded find-orange band, like a browser's find in page, distinct from both
    /// the highlight colours and the selection; still under the glyphs.
    private func drawFound(_ ctx: CGContext) {
        let found = marks.filter(\.isFound)
        guard !found.isEmpty else { return }
        ctx.setFillColor(Self.foundColor.withAlphaComponent(palette.isDark ? 0.42 : 0.5).cgColor)
        for mark in found {
            for rect in rects(for: mark.range) {
                ctx.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: 0), cornerRadius: 3).cgPath)
            }
        }
        ctx.fillPath()
    }

    static let foundColor = UIColor(red: 1.0, green: 0.62, blue: 0.1, alpha: 1)

    /// The pencil strokes on this page, in this view's coordinates (placed once per layout).
    func sketchStrokes() -> [SketchLayout.Placed] {
        if let placedSketches { return placedSketches }
        guard let chapter, !sketches.isEmpty else { return [] }
        let area = bounds.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y)
        let shift = CGAffineTransform(translationX: textOrigin.x, y: textOrigin.y)
        let placed = SketchLayout.place(sketches, chapter: chapter, page: page, area: area).map { placed in
            var placed = placed
            placed.stroke.transform = shift
            placed.stroke = SketchLayout.normalized(placed.stroke)[0]
            return placed
        }
        placedSketches = placed
        return placed
    }

    /// Pencil markings go over the glyphs, like ink on paper, in the page's light or dark (PencilKit
    /// lightens dark inks on a dark page, as its canvas does).
    private func drawSketches(_ ctx: CGContext) {
        let strokes = sketchStrokes()
        guard !strokes.isEmpty else { return }
        let drawing = PKDrawing(strokes: strokes.map(\.stroke))
        let rect = drawing.bounds.intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: palette.isDark ? .dark : .light).performAsCurrent {
            image = drawing.image(from: rect, scale: max(2, ctx.ctm.a.magnitude, contentScaleFactor))
        }
        image?.draw(in: rect)
    }

    private func drawSelection(_ ctx: CGContext) {
        guard let selection else { return }
        ctx.setFillColor(palette.link.withAlphaComponent(0.25).cgColor)
        for rect in rects(for: selection) { ctx.fill(rect) }
    }

    /// Rects (view coordinates) enclosing the part of a chapter range that lies on this page.
    func rects(for range: NSRange) -> [CGRect] {
        guard let chapter else { return [] }
        return chapter.rects(for: range, page: page).map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
    }

    /// The character nearest to a point in this view's coordinates, clamped to the page.
    func nearestCharacter(to point: CGPoint) -> (index: Int, fraction: CGFloat)? {
        guard let chapter else { return nil }
        return chapter.nearestCharacter(to: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y), page: page)
    }

    /// The highlight under a point, if any.
    func mark(at point: CGPoint) -> HighlightMark? {
        guard let index = characterIndex(at: point) else { return nil }
        return marks.first { !$0.isFound && NSLocationInRange(index, $0.range) }
    }

    private func drawMargins() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: marginFont, .foregroundColor: palette.secondary, .paragraphStyle: para]
        let lineHeight = marginFont.lineHeight + 2
        if !head.isEmpty {
            let ribbon = isBookmarked ? Self.ribbonFrame(bounds: bounds, textInsets: textInsets, camera: camera) : nil
            let frame = Self.headFrame(bounds: bounds, textInsets: textInsets, lineHeight: lineHeight, camera: camera, ribbon: ribbon)
            (head as NSString).draw(in: frame, withAttributes: attrs)
        }
        if !folio.isEmpty {
            let frame = Self.folioFrame(bounds: bounds, textInsets: textInsets, lineHeight: lineHeight)
            (folio as NSString).draw(in: frame, withAttributes: attrs)
        }
    }

    /// Where the running head goes: centred over the text in the band above it, narrowed
    /// symmetrically so it stays clear of a camera hole in that band (the cover display's hole
    /// sits at the top right, in the vertical bar's strip) and of a bookmark ribbon.
    nonisolated static func headFrame(bounds: CGRect, textInsets: UIEdgeInsets, lineHeight: CGFloat,
                                      camera: CGRect?, ribbon: CGRect? = nil) -> CGRect {
        let y = max(4, textInsets.top - lineHeight - 6)
        var left = textInsets.left
        var right = bounds.width - textInsets.right
        let center = (left + right) / 2
        for obstacle in [camera, ribbon].compactMap({ $0 }) where obstacle.minY < y + lineHeight && obstacle.maxY > y {
            if obstacle.midX >= center { right = min(right, obstacle.minX - 8) } else { left = max(left, obstacle.maxX + 8) }
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

    /// Draws the page into `context`, set up the UIKit way (origin top-left, scaled), exactly as
    /// `draw(_:)` paints it on screen; the page flip renders its leaves this way.
    func render(in context: CGContext) {
        UIGraphicsPushContext(context)
        draw(bounds)
        UIGraphicsPopContext()
    }

    override var accessibilityLabel: String? {
        get {
            guard let chapter else { return nil }
            let range = chapter.range(ofPage: page)
            // A table row reads as its cells (VoiceOver would say nothing for its object character).
            let text = NSMutableString(string: (chapter.textStorage.string as NSString).substring(with: range))
            var rows: [(NSRange, String)] = []
            chapter.textStorage.enumerateAttribute(.attachment, in: range) { value, found, _ in
                if let row = value as? TableRowAttachment {
                    rows.append((NSRange(location: found.location - range.location, length: found.length), row.plainText))
                }
            }
            for (local, replacement) in rows.reversed() { text.replaceCharacters(in: local, with: replacement) }
            return text.replacingOccurrences(of: TableContent.lineSeparator, with: "\n")
        }
        set {}
    }

    /// The image under a point in this view's coordinates, with its rect in this view's coordinates.
    func image(at point: CGPoint) -> PageImage? {
        guard let chapter,
              var hit = chapter.image(at: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y), page: page) else { return nil }
        hit.rect = hit.rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
        return hit
    }

    /// The images on this page, with their rects in this view's coordinates.
    func images() -> [PageImage] {
        guard let chapter else { return [] }
        return chapter.images(onPage: page).map { image in
            var image = image
            image.rect = image.rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
            return image
        }
    }

    /// The link in a table cell under a point in this view's coordinates, if any: a table row is
    /// one attachment, so its links are not in the chapter's attributes.
    func tableLink(at point: CGPoint) -> String? {
        guard let chapter, let index = characterIndex(at: point), index < chapter.textStorage.length,
              let row = chapter.textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? TableRowAttachment,
              let frame = chapter.attachmentFrame(at: index, page: page) else { return nil }
        return row.link(at: CGPoint(x: point.x - textOrigin.x - frame.minX, y: point.y - textOrigin.y - frame.minY))
    }

    /// The character index under a point in this view's coordinates, if over text.
    func characterIndex(at point: CGPoint) -> Int? {
        guard let chapter else { return nil }
        let local = CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y)
        return chapter.characterIndex(at: local, page: page)
    }
}
