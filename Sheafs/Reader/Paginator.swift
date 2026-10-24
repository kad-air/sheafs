import Foundation
import UIKit

/// A chapter laid out into fixed-size pages with TextKit: one `NSTextContainer` per page sharing a
/// layout manager. When an `anchor` offset is given, a page break is forced exactly there, so the
/// text at the reading position is the first line of its page after a fold, a rotation or a font
/// change. Create and use on the main actor.
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
            parts = [Part(attributedString: prefix, offset: 0, pageSize: pageSize),
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

    /// One contiguous stretch of the chapter laid out from its first character.
    private final class Part {
        let offset: Int
        let textStorage: NSTextStorage
        let layoutManager = NSLayoutManager()
        private(set) var containers: [NSTextContainer] = []
        private(set) var pageRanges: [NSRange] = []
        var firstPage = 0

        init(attributedString: NSAttributedString, offset: Int, pageSize: CGSize) {
            self.offset = offset
            textStorage = NSTextStorage(attributedString: attributedString)
            layoutManager.usesFontLeading = true
            layoutManager.allowsNonContiguousLayout = false
            textStorage.addLayoutManager(layoutManager)
            paginate(pageSize: pageSize)
        }

        private func paginate(pageSize: CGSize) {
            let total = textStorage.length
            var laidOut = 0
            var guardCount = 0
            while laidOut < total, guardCount < 10_000 {
                guardCount += 1
                let container = NSTextContainer(size: pageSize)
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                containers.append(container)
                let glyphRange = layoutManager.glyphRange(for: container)
                if glyphRange.length == 0 {
                    // Nothing fits (e.g. an oversized attachment). Skip one character to make progress.
                    pageRanges.append(NSRange(location: laidOut, length: 1))
                    laidOut += 1
                    continue
                }
                let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                pageRanges.append(charRange)
                laidOut = max(laidOut + 1, NSMaxRange(charRange))
            }
            if pageRanges.isEmpty {
                let container = NSTextContainer(size: pageSize)
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                containers.append(container)
                pageRanges.append(NSRange(location: 0, length: 0))
            }
        }

        func draw(page: Int, at origin: CGPoint) {
            guard page >= 0, page < containers.count else { return }
            let container = containers[page]
            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.length > 0 else { return }
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        }

        func characterIndex(at point: CGPoint, page: Int) -> Int? {
            guard page >= 0, page < containers.count else { return nil }
            let container = containers[page]
            var fraction: CGFloat = 0
            let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
            return layoutManager.characterIndexForGlyph(at: glyph)
        }
    }
}
