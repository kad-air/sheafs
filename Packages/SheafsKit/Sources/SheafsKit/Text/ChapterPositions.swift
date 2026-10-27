import Foundation

/// Positions in a chapter: plain-text offsets ↔ CREngine pointers, and putting stored offsets
/// right when the chapter converts differently than when they were saved (a stylesheet now
/// hides front matter, so everything after it moved up).
///
/// Offsets are the fast path everywhere; the pointers name the element and the offset inside its
/// block, which hidden content elsewhere in the chapter does not shift.
extension Chapter {
    /// The pointer for an offset: the block containing it and the offset within that block (our
    /// own convention: `text()[1]` and the offset in the block's text). In a table, the row's
    /// `tr` and no text offset: the cells' text is not in the chapter text.
    public func pointer(at offset: Int, spineIndex: Int) -> XPointer {
        guard let block = block(containing: offset) else {
            return XPointer(spineIndex: spineIndex, elementPath: "/body")
        }
        let within = max(0, min(offset - block.textOffset, block.textLength))
        if case .table(let table) = block.kind {
            guard let row = table.row(atOffset: within) else { return XPointer(spineIndex: spineIndex, elementPath: block.elementPath) }
            return XPointer(spineIndex: spineIndex, elementPath: table.rows[row].elementPath)
        }
        return XPointer(spineIndex: spineIndex, elementPath: block.elementPath, textNodeIndex: 1, characterOffset: within)
    }

    /// The offset a pointer names, or nil when no block has its element path. `exact: false`
    /// also accepts the nearest ancestor block (pointers into inline elements from other readers).
    /// A pointer into a table (a row, a cell, text in a cell) names its row's object, exactly;
    /// the character offset is ignored there. A row an image split is in two table parts with
    /// the same path: `near` (the offset the position had before) picks the part holding it,
    /// else the first.
    public func offset(of pointer: XPointer, exact: Bool = false, near: Int? = nil) -> Int? {
        if let block = block(atElementPath: pointer.elementPath) {
            if case .table = block.kind { return block.textOffset }
            return block.textOffset + max(0, min(pointer.characterOffset ?? 0, block.textLength))
        }
        var rows: [(offset: Int, block: Block)] = []
        for block in blocks {
            if case .table(let table) = block.kind, let row = table.row(forElementPath: pointer.elementPath) {
                rows.append((block.textOffset + table.offset(ofRow: row), block))
            }
        }
        if let first = rows.first {
            if let near, let holding = rows.first(where: { $0.block.textOffset <= near && near <= $0.block.textRange.upperBound }) {
                return holding.offset
            }
            return first.offset
        }
        guard !exact, let block = block(nearestElementPath: pointer.elementPath) else { return nil }
        if case .table = block.kind { return block.textOffset }
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
        // Compared as quoted: a highlight over table rows holds the rows' text, not their objects.
        func quotes(_ range: Range<Int>) -> Bool {
            range.lowerBound >= 0 && range.upperBound <= textLength && (text(in: range) == quoted || displayText(in: range) == quoted)
        }
        if quotes(range) { return nil }
        guard let start = startPointer.flatMap(XPointer.init(parsing:)).flatMap({ offset(of: $0, exact: true) }),
              let end = endPointer.flatMap(XPointer.init(parsing:)).flatMap({ offset(of: $0, exact: true) }),
              start <= end, quotes(start ..< end) else { return nil }
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
