import Foundation
import UIKit

/// An image on a page of a `PaginatedChapter`.
struct PageImage: Equatable {
    /// The attachment's character (one U+FFFC), in chapter coordinates.
    var index: Int
    /// The image's `src` as written in the chapter (`Block.Kind.image`).
    var source: String
    /// Where it draws, in page coordinates (origin at the text's top-left).
    var rect: CGRect
}

/// A chapter laid out into fixed-size pages with TextKit (one tall container per part, cut at
/// line boundaries). When an `anchor` offset is given, a page break is forced exactly there, so the
/// text at the reading position is the first line of its page after a fold, a rotation or a font
/// change; the text before the anchor is cut backward from it. Create and use on the main actor.
final class PaginatedChapter {
    let spineIndex: Int
    let pageSize: CGSize
    /// The whole chapter, for attribute lookups (links, images) by absolute character index.
    let textStorage: NSTextStorage
    /// Character ranges per page, in chapter coordinates.
    private(set) var pageRanges: [NSRange] = []
    /// The offset a page break was forced at, if any.
    let anchor: Int?
    private var parts: [Part] = []

    var pageCount: Int { max(1, pageRanges.count) }

    init(spineIndex: Int, attributedString: NSAttributedString, pageSize: CGSize, anchor: Int? = nil) {
        self.spineIndex = spineIndex
        self.pageSize = pageSize
        textStorage = NSTextStorage(attributedString: attributedString)
        let length = attributedString.length
        if let anchor, anchor > 0, anchor < length {
            self.anchor = anchor
            let prefix = attributedString.attributedSubstring(from: NSRange(location: 0, length: anchor))
            let suffix = Self.continuation(of: attributedString.attributedSubstring(from: NSRange(location: anchor, length: length - anchor)))
            parts = [Part(attributedString: prefix, offset: 0, pageSize: pageSize, backward: true),
                     Part(attributedString: suffix, offset: anchor, pageSize: pageSize)]
        } else {
            self.anchor = nil
            parts = [Part(attributedString: attributedString, offset: 0, pageSize: pageSize)]
        }
        var ranges: [NSRange] = []
        for part in parts {
            part.firstPage = ranges.count
            for range in part.pageRanges {
                ranges.append(NSRange(location: range.location + part.offset, length: range.length))
            }
        }
        pageRanges = ranges
    }

    /// A substring that starts mid-paragraph must not carry the paragraph's first-line indent.
    private static func continuation(of string: NSAttributedString) -> NSAttributedString {
        guard string.length > 0,
              let style = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              style.firstLineHeadIndent != style.headIndent else { return string }
        let mutable = NSMutableAttributedString(attributedString: string)
        let paragraph = (mutable.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let fixed = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        fixed.firstLineHeadIndent = style.headIndent
        mutable.addAttribute(.paragraphStyle, value: fixed, range: paragraph)
        return mutable
    }

    /// The page whose text contains `offset` (clamped to the chapter).
    func pageIndex(containing offset: Int) -> Int {
        guard pageRanges.count > 1 else { return 0 }
        var low = 0, high = pageRanges.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if pageRanges[mid].location <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func range(ofPage page: Int) -> NSRange {
        pageRanges[max(0, min(page, pageRanges.count - 1))]
    }

    private func part(forPage page: Int) -> (Part, Int)? {
        for part in parts where page >= part.firstPage && page < part.firstPage + part.pageRanges.count {
            return (part, page - part.firstPage)
        }
        return nil
    }

    /// Draws page `page` with its top-left corner at `origin` in the current graphics context.
    func draw(page: Int, at origin: CGPoint) {
        guard let (part, local) = part(forPage: page) else { return }
        part.draw(page: local, at: origin)
    }

    /// The character index (chapter coordinates) under `point` on `page`, or nil when not over text.
    func characterIndex(at point: CGPoint, page: Int) -> Int? {
        guard let (part, local) = part(forPage: page), let index = part.characterIndex(at: point, page: local) else { return nil }
        return index + part.offset
    }

    /// The frame (page coordinates, origin at the text's top-left) of the text attachment at
    /// character `index` (chapter coordinates) when it is on `page`.
    func attachmentFrame(at index: Int, page: Int) -> CGRect? {
        guard let (part, local) = part(forPage: page) else { return nil }
        return part.attachmentRect(at: index - part.offset, page: local)
    }

    /// The character nearest to `point` on `page` (chapter coordinates), with how far through the
    /// glyph the point lies, for dragging selection handles past the edges of the text.
    func nearestCharacter(to point: CGPoint, page: Int) -> (index: Int, fraction: CGFloat) {
        guard let (part, local) = part(forPage: page) else { return (0, 0) }
        let hit = part.nearestCharacter(to: point, page: local)
        return (hit.index + part.offset, hit.fraction)
    }

    /// The rects (page coordinates, origin at the text's top-left) enclosing the part of `range`
    /// that lies on `page`; empty when none of it does.
    func rects(for range: NSRange, page: Int) -> [CGRect] {
        guard let (part, local) = part(forPage: page) else { return [] }
        let onPage = NSIntersectionRange(range, self.range(ofPage: page))
        guard onPage.length > 0 else { return [] }
        return part.rects(for: NSRange(location: onPage.location - part.offset, length: onPage.length), page: local)
    }

    /// The images drawn on `page`: each attachment's character (chapter coordinates), its `src` as
    /// written, and the rect it draws in (page coordinates, origin at the text's top-left).
    func images(onPage page: Int) -> [PageImage] {
        guard let (part, local) = part(forPage: page) else { return [] }
        let onPage = range(ofPage: page)
        var result: [PageImage] = []
        textStorage.enumerateAttribute(.sheafsImageSource, in: onPage) { value, range, _ in
            guard let source = value as? String else { return }
            for index in range.location ..< NSMaxRange(range) {
                guard let rect = part.attachmentRect(at: index - part.offset, page: local) else { continue }
                result.append(PageImage(index: index, source: source, rect: rect))
            }
        }
        return result
    }

    /// The image under `point` (page coordinates) on `page`, if any. A few points of slack around
    /// the picture, so a tap on its edge still lands.
    func image(at point: CGPoint, page: Int) -> PageImage? {
        images(onPage: page).first { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }
    }

    /// The word around `index`, for a long press; on whitespace or punctuation the nearest word in
    /// the paragraph, and failing that the character itself.
    func wordRange(at index: Int) -> NSRange {
        Self.wordRange(in: textStorage.string as NSString, at: index)
    }

    nonisolated static func wordRange(in string: NSString, at index: Int) -> NSRange {
        guard string.length > 0 else { return NSRange(location: 0, length: 0) }
        let index = max(0, min(index, string.length - 1))
        let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
        var best: NSRange?
        var bestDistance = Int.max
        string.enumerateSubstrings(in: paragraph, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(index, range) {
                best = range
                bestDistance = 0
                stop.pointee = true
                return
            }
            let distance = index < range.location ? range.location - index : index - NSMaxRange(range) + 1
            if distance < bestDistance {
                best = range
                bestDistance = distance
            }
        }
        if let best, bestDistance <= 2 { return best }
        return string.rangeOfComposedCharacterSequence(at: index)
    }

    /// One contiguous stretch of the chapter, laid out once in a tall container and cut into pages
    /// at line boundaries. Forward parts fill pages from the top; the part before an anchor is cut
    /// backward from the anchor, so its short page lands at the chapter start rather than right
    /// before the reading position.
    private final class Part {
        let offset: Int
        let textStorage: NSTextStorage
        let layoutManager = NSLayoutManager()
        private let container: NSTextContainer
        private(set) var pageRanges: [NSRange] = []
        private var pageGlyphRanges: [NSRange] = []
        private var pageTops: [CGFloat] = []
        var firstPage = 0

        init(attributedString: NSAttributedString, offset: Int, pageSize: CGSize, backward: Bool = false) {
            self.offset = offset
            textStorage = NSTextStorage(attributedString: attributedString)
            container = NSTextContainer(size: CGSize(width: pageSize.width, height: 1_000_000))
            container.lineFragmentPadding = 0
            layoutManager.usesFontLeading = true
            layoutManager.allowsNonContiguousLayout = false
            layoutManager.addTextContainer(container)
            textStorage.addLayoutManager(layoutManager)
            cut(pageHeight: pageSize.height, backward: backward)
        }

        private func cut(pageHeight: CGFloat, backward: Bool) {
            layoutManager.ensureLayout(for: container)
            // A line's fragment rect carries its trailing line spacing (and the paragraph spacing
            // after a paragraph's last line); a page only has to hold the glyphs, so the last line
            // of a page is judged by its glyph bottom, not by the spacing under it.
            var lines: [(glyphs: NSRange, rect: CGRect, bottom: CGFloat)] = []
            let all = layoutManager.glyphRange(for: container)
            let text = textStorage.mutableString
            layoutManager.enumerateLineFragments(forGlyphRange: all) { [layoutManager, textStorage] rect, usedRect, _, glyphRange, _ in
                let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                var trailing: CGFloat = 0
                if chars.length > 0,
                   let style = textStorage.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle {
                    trailing = style.lineSpacing
                    let end = NSMaxRange(chars)
                    if end >= text.length || text.character(at: end - 1) == 0x0A { trailing += style.paragraphSpacing }
                }
                lines.append((glyphRange, rect, min(usedRect.maxY, rect.maxY - trailing)))
            }
            guard !lines.isEmpty else {
                pageRanges = [NSRange(location: 0, length: 0)]
                pageGlyphRanges = [NSRange(location: 0, length: 0)]
                pageTops = [0]
                return
            }
            // Group lines into pages: a page takes lines while they fit, and always at least one.
            var groups: [ClosedRange<Int>] = []
            if backward {
                var end = lines.count - 1
                var start = end
                while start >= 0 {
                    let fits = lines[end].bottom - lines[start].rect.minY <= pageHeight
                    if fits || start == end {
                        start -= 1
                    } else {
                        groups.append((start + 1) ... end)
                        end = start
                    }
                }
                groups.append(0 ... end)
                groups.reverse()
            } else {
                var start = 0
                var end = start
                while end < lines.count {
                    let fits = lines[end].bottom - lines[start].rect.minY <= pageHeight
                    if fits || end == start {
                        end += 1
                    } else {
                        groups.append(start ... (end - 1))
                        start = end
                    }
                }
                groups.append(start ... (lines.count - 1))
            }
            for group in groups {
                let first = lines[group.lowerBound], last = lines[group.upperBound]
                let glyphs = NSRange(location: first.glyphs.location, length: NSMaxRange(last.glyphs) - first.glyphs.location)
                pageGlyphRanges.append(glyphs)
                pageRanges.append(layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
                pageTops.append(first.rect.minY)
            }
        }

        func draw(page: Int, at origin: CGPoint) {
            guard page >= 0, page < pageGlyphRanges.count, pageGlyphRanges[page].length > 0 else { return }
            let shifted = CGPoint(x: origin.x, y: origin.y - pageTops[page])
            layoutManager.drawBackground(forGlyphRange: pageGlyphRanges[page], at: shifted)
            layoutManager.drawGlyphs(forGlyphRange: pageGlyphRanges[page], at: shifted)
        }

        func nearestCharacter(to point: CGPoint, page: Int) -> (index: Int, fraction: CGFloat) {
            guard page >= 0, page < pageGlyphRanges.count, pageGlyphRanges[page].length > 0 else { return (0, 0) }
            let inContainer = CGPoint(x: point.x, y: point.y + pageTops[page])
            var fraction: CGFloat = 0
            var glyph = layoutManager.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let range = pageGlyphRanges[page]
            if glyph < range.location { glyph = range.location; fraction = 0 }
            if glyph >= NSMaxRange(range) { glyph = NSMaxRange(range) - 1; fraction = 1 }
            return (layoutManager.characterIndexForGlyph(at: glyph), fraction)
        }

        func rects(for range: NSRange, page: Int) -> [CGRect] {
            guard page >= 0, page < pageGlyphRanges.count, range.length > 0 else { return [] }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let visible = NSIntersectionRange(glyphs, pageGlyphRanges[page])
            guard visible.length > 0 else { return [] }
            var rects: [CGRect] = []
            let top = pageTops[page]
            layoutManager.enumerateEnclosingRects(forGlyphRange: visible, withinSelectedGlyphRange: visible, in: container) { rect, _ in
                rects.append(rect.offsetBy(dx: 0, dy: -top))
            }
            return rects
        }

        /// Where the attachment at `index` (part coordinates) draws on `page`: its cell, standing on
        /// the line's baseline (`Typesetter` gives every image bounds with a zero origin).
        func attachmentRect(at index: Int, page: Int) -> CGRect? {
            guard page >= 0, page < pageGlyphRanges.count, index >= 0, index < textStorage.length else { return nil }
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            guard NSLocationInRange(glyph, pageGlyphRanges[page]) else { return nil }
            let size = layoutManager.attachmentSize(forGlyphAt: glyph)
            guard size.width > 0, size.height > 0 else { return nil }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyph)
            return CGRect(x: line.minX + location.x, y: line.minY + location.y - size.height - pageTops[page],
                          width: size.width, height: size.height)
        }

        func characterIndex(at point: CGPoint, page: Int) -> Int? {
            guard page >= 0, page < pageGlyphRanges.count else { return nil }
            let inContainer = CGPoint(x: point.x, y: point.y + pageTops[page])
            var fraction: CGFloat = 0
            let glyph = layoutManager.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
            guard NSLocationInRange(glyph, pageGlyphRanges[page]) else { return nil }
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard rect.insetBy(dx: -4, dy: -4).contains(inContainer) else { return nil }
            return layoutManager.characterIndexForGlyph(at: glyph)
        }
    }
}
