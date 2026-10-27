import Foundation

/// Positions in a chapter: plain-text offsets ↔ CREngine pointers, and putting stored offsets
/// right when the chapter converts differently than when they were saved (a stylesheet now
/// hides front matter, so everything after it moved up).
///
/// Offsets are the fast path everywhere; the pointers name the element and the offset inside its
/// block, which hidden content elsewhere in the chapter does not shift.
extension Chapter {
    /// The pointer for an offset: the block containing it and the offset within that block (our
    /// own convention: `text()[1]` and the offset in the block's text).
    public func pointer(at offset: Int, spineIndex: Int) -> XPointer {
        guard let block = block(containing: offset) else {
            return XPointer(spineIndex: spineIndex, elementPath: "/body")
        }
        let within = max(0, min(offset - block.textOffset, block.textLength))
        return XPointer(spineIndex: spineIndex, elementPath: block.elementPath, textNodeIndex: 1, characterOffset: within)
    }

    /// The offset a pointer names, or nil when no block has its element path. `exact: false`
    /// also accepts the nearest ancestor block (pointers into inline elements from other readers).
    public func offset(of pointer: XPointer, exact: Bool = false) -> Int? {
        let found = block(atElementPath: pointer.elementPath) ?? (exact ? nil : block(nearestElementPath: pointer.elementPath))
        guard let block = found else { return nil }
        return block.textOffset + max(0, min(pointer.characterOffset ?? 0, block.textLength))
    }

    /// The plain text (blocks + "\n" separators) in a UTF-16 range; nil when it runs off the end.
    public func text(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= textLength else { return nil }
        var result = ""
        for block in blocks {
            let blockEnd = block.textOffset + block.textLength + 1
            guard block.textOffset < range.upperBound else { break }
            guard blockEnd > range.lowerBound else { continue }
            let full = (block.text + "\n") as NSString
            let lower = max(0, range.lowerBound - block.textOffset)
            let upper = min(full.length, range.upperBound - block.textOffset)
            if upper > lower { result += full.substring(with: NSRange(location: lower, length: upper - lower)) }
        }
        return result
    }

    /// A highlight's range as the chapter converts now. Nil when the stored offsets still hold
    /// `text` (nothing to do) or when the pointers don't lead to it either (leave it alone); else
    /// the range the pointers name, which holds `text`.
    public func reanchoredRange(_ range: Range<Int>, text quoted: String, startPointer: String?, endPointer: String?) -> Range<Int>? {
        if text(in: range) == quoted { return nil }
        guard let start = startPointer.flatMap(XPointer.init(parsing:)).flatMap({ offset(of: $0, exact: true) }),
              let end = endPointer.flatMap(XPointer.init(parsing:)).flatMap({ offset(of: $0, exact: true) }),
              start <= end, text(in: start ..< end) == quoted else { return nil }
        return start ..< end
    }

    /// A reading position as the chapter converts now: the offset the stored pointer names when
    /// that differs from `offset`, else nil. The pointer must name this chapter and an element
    /// that still has a block (a hidden one doesn't: then the offset stays).
    public func reanchoredOffset(_ offset: Int, pointer serialized: String?, spineIndex: Int) -> Int? {
        guard let pointer = serialized.flatMap(XPointer.init(parsing:)), pointer.spineIndex == spineIndex,
              let resolved = self.offset(of: pointer, exact: true), resolved != offset else { return nil }
        return resolved
    }
}
