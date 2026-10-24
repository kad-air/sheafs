import Foundation
import UIKit

/// A chapter laid out into fixed-size pages with TextKit: one `NSTextContainer` per page sharing
/// a single layout manager. Create and use on the main actor.
final class PaginatedChapter {
    let spineIndex: Int
    let pageSize: CGSize
    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    private(set) var containers: [NSTextContainer] = []
    /// Character ranges per page.
    private(set) var pageRanges: [NSRange] = []

    var pageCount: Int { max(1, pageRanges.count) }

    init(spineIndex: Int, attributedString: NSAttributedString, pageSize: CGSize) {
        self.spineIndex = spineIndex
        self.pageSize = pageSize
        textStorage = NSTextStorage(attributedString: attributedString)
        layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        layoutManager.allowsNonContiguousLayout = false
        textStorage.addLayoutManager(layoutManager)
        paginate()
    }

    private func paginate() {
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
                let charRange = NSRange(location: laidOut, length: 1)
                pageRanges.append(charRange)
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

    /// Draws page `page` with its top-left corner at `origin` in the current graphics context.
    func draw(page: Int, at origin: CGPoint) {
        guard page >= 0, page < containers.count else { return }
        let container = containers[page]
        let glyphRange = layoutManager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return }
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
    }

    /// The character index under `point` (page-local coordinates) on `page`, or nil when the
    /// point is not over text.
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
