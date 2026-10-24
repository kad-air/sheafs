import Foundation
import UIKit

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
