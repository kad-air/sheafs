import Foundation

/// Character-level styling inside a block of text.
public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let italic = InlineStyle(rawValue: 1 << 0)
    public static let bold = InlineStyle(rawValue: 1 << 1)
    public static let underline = InlineStyle(rawValue: 1 << 2)
    public static let strikethrough = InlineStyle(rawValue: 1 << 3)
    public static let code = InlineStyle(rawValue: 1 << 4)
    public static let superscript = InlineStyle(rawValue: 1 << 5)
    public static let `subscript` = InlineStyle(rawValue: 1 << 6)
    public static let smallCaps = InlineStyle(rawValue: 1 << 7)
    /// The markup made this text bold and the stylesheet set it in small caps instead (Standard
    /// Ebooks' `b, strong { font-variant: small-caps; font-weight: normal }`). Only with
    /// `.smallCaps`: in a font without small caps the typesetter draws it bold, as the markup
    /// alone would, so the emphasis does not vanish.
    public static let boldAsSmallCaps = InlineStyle(rawValue: 1 << 8)
}

/// A run of text with one style. Consecutive runs with equal style and link may be merged.
public struct InlineRun: Hashable, Sendable {
    public var text: String
    public var style: InlineStyle
    /// The `href` exactly as written in the source document (not resolved).
    public var link: String?

    public init(text: String, style: InlineStyle = [], link: String? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

public enum BlockAlignment: String, Hashable, Sendable {
    case natural, center, trailing, justified
}

public enum BlockKind: Hashable, Sendable {
    case paragraph
    /// `level` is 1...6.
    case heading(level: Int)
    case blockquote
    case listItem(ordered: Bool, ordinal: Int)
    case preformatted
    /// `source` is the image href exactly as written (resolved by the app against the chapter path).
    case image(source: String, alt: String?)
    case horizontalRule
    case caption
    /// A `<table>`: its rows, cells and caption live in the payload; the block's text is only
    /// object replacement characters (see `TableContent.objectText`).
    case table(TableContent)
}

/// The content of a `<table>` block. Cells carry their own text and inline runs, which are NOT
/// part of the chapter plain text: the block's text is `objectText`, one U+FFFC per row (and one
/// for the caption), so the typesetter can draw each row as one text attachment and the offsets
/// contract holds. Positions in a table resolve to a row, never to a character inside a cell.
public struct TableContent: Hashable, Sendable {
    public struct Cell: Hashable, Sendable {
        public var runs: [InlineRun]
        /// A `th`, or any cell of a `thead` row.
        public var isHeader: Bool
        /// The `colspan` (1 when absent or invalid). `rowspan` is not modelled.
        public var columnSpan: Int
        /// Alignment declared on the cell (`align`, inline `text-align`, a `right`/`center` class).
        public var alignment: BlockAlignment?

        public init(runs: [InlineRun], isHeader: Bool = false, columnSpan: Int = 1, alignment: BlockAlignment? = nil) {
            self.runs = runs
            self.isHeader = isHeader
            self.columnSpan = columnSpan
            self.alignment = alignment
        }

        public var text: String { runs.map(\.text).joined() }
    }

    public struct Row: Hashable, Sendable {
        public var cells: [Cell]
        /// CREngine path of the `tr` (or of the table, for cells outside any `tr`).
        public var elementPath: String
        /// The column of the first cell: 0, except for the rest of a row an image split, which
        /// carries on in the column it left.
        public var firstColumn: Int

        public init(cells: [Cell], elementPath: String, firstColumn: Int = 0) {
            self.cells = cells
            self.elementPath = elementPath
            self.firstColumn = firstColumn
        }

        /// Every cell is a header cell (a `thead` row, or a row of `th`).
        public var isHeader: Bool { !cells.isEmpty && cells.allSatisfy(\.isHeader) }
    }

    public var rows: [Row]
    /// The `<caption>`, drawn beneath the table; nil when absent or empty.
    public var caption: [InlineRun]?

    public init(rows: [Row], caption: [InlineRun]? = nil) {
        self.rows = rows
        self.caption = caption
    }

    /// The widest row, counting column spans.
    public var columnCount: Int { rows.map { $0.cells.reduce($0.firstColumn) { $0 + $1.columnSpan } }.max() ?? 0 }

    /// A row as text, for what reads text rather than draws it (copy, highlights, VoiceOver,
    /// footnotes): its non-empty cells joined by " · ", line breaks in a cell as spaces.
    public func plainText(ofRow index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        return rows[index].cells.map { Self.oneLine($0.text) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The caption as text ("" when there is none).
    public var plainCaption: String { Self.oneLine((caption ?? []).map(\.text).joined()) }

    /// The text of the object at `offset` within the block text: a row, or the caption.
    public func plainText(atOffset offset: Int) -> String {
        if let captionOffset, offset >= captionOffset { return plainCaption }
        return row(atOffset: offset).map(plainText(ofRow:)) ?? ""
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: Self.lineSeparator, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The separator between the row objects: a line separator, so the table stays one paragraph
    /// and every row is a line of its own that pagination can break after.
    public static let lineSeparator = "\u{2028}"

    /// The block's text: one U+FFFC per row, then one for the caption, separated by U+2028.
    public var objectText: String {
        Array(repeating: "\u{FFFC}", count: rows.count + (caption == nil ? 0 : 1))
            .joined(separator: Self.lineSeparator)
    }

    /// Offset of row `index`'s object within the block text.
    public func offset(ofRow index: Int) -> Int { 2 * index }

    /// Offset of the caption's object within the block text, if there is a caption.
    public var captionOffset: Int? { caption == nil ? nil : 2 * rows.count }

    /// The row whose object is at or before `offset` (an offset within the block text).
    public func row(atOffset offset: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        return max(0, min(rows.count - 1, offset / 2))
    }

    /// The row a CREngine path points into: the row whose path is the path or one of its
    /// ancestors (a pointer to a cell or its text lands on the row).
    public func row(forElementPath path: String) -> Int? {
        let wanted = Chapter.normalizedSteps(path)
        var best: (index: Int, depth: Int)?
        for (index, row) in rows.enumerated() {
            let steps = Chapter.normalizedSteps(row.elementPath)
            guard steps.count <= wanted.count, Array(wanted.prefix(steps.count)) == steps else { continue }
            if best == nil || steps.count > best!.depth { best = (index, steps.count) }
        }
        return best?.index
    }
}

/// One block-level piece of a chapter: a paragraph, heading, image, rule...
///
/// Offsets are UTF-16 unit offsets into the chapter's plain text, where the plain text is the
/// concatenation of every block's `text` followed by a single "\n" separator. An image or rule
/// block's text is exactly one U+FFFC (object replacement character). A table block's text is
/// one U+FFFC per row plus one for its caption, separated by U+2028 (`TableContent.objectText`);
/// the cell text lives in the `.table` payload, not in the plain text. The app's typesetter
/// produces an attributed string with that exact layout (one text attachment per U+FFFC), so a
/// `textOffset` is directly usable as an `NSAttributedString` index.
public struct Block: Hashable, Sendable, Identifiable {
    /// Index of the block within its chapter.
    public var id: Int
    public var kind: BlockKind
    public var runs: [InlineRun]
    public var alignment: BlockAlignment
    /// Nesting depth for blockquotes and lists (0 for top-level content).
    public var indent: Int
    /// CREngine-style path of the element that produced this block, from the document body,
    /// every step indexed 1-based among same-tag siblings: "/body/section[1]/p[3]".
    public var elementPath: String
    /// UTF-16 offset of the block's first character in the chapter plain text.
    public var textOffset: Int

    public init(id: Int, kind: BlockKind, runs: [InlineRun], alignment: BlockAlignment = .natural,
                indent: Int = 0, elementPath: String, textOffset: Int) {
        self.id = id
        self.kind = kind
        self.runs = runs
        self.alignment = alignment
        self.indent = indent
        self.elementPath = elementPath
        self.textOffset = textOffset
    }

    public var text: String { runs.map(\.text).joined() }
    public var textLength: Int { runs.reduce(0) { $0 + $1.text.utf16.count } }
    /// The range of this block's text in the chapter plain text (excluding the "\n" separator).
    public var textRange: Range<Int> { textOffset ..< textOffset + textLength }
}

/// The converted content of one spine document.
public struct Chapter: Sendable {
    public var blocks: [Block]
    /// Total length of the plain text in UTF-16 units, separators included.
    public var textLength: Int
    /// Element `id` attributes → the plain-text offset where that element starts.
    public var anchorOffsets: [String: Int]
    /// The document `<title>`, if any.
    public var title: String?

    public init(blocks: [Block], textLength: Int, anchorOffsets: [String: Int], title: String? = nil) {
        self.blocks = blocks
        self.textLength = textLength
        self.anchorOffsets = anchorOffsets
        self.title = title
    }

    public var plainText: String {
        blocks.map(\.text).joined(separator: "\n") + (blocks.isEmpty ? "" : "\n")
    }

    /// The block whose text range contains `offset` (or the last block starting at or before it).
    public func block(containing offset: Int) -> Block? {
        guard !blocks.isEmpty else { return nil }
        var low = 0, high = blocks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if blocks[mid].textOffset <= offset { low = mid } else { high = mid - 1 }
        }
        return blocks[low].textOffset <= offset ? blocks[low] : nil
    }

    /// Finds a block by CREngine element path. Matching is tolerant: a step without an index
    /// means `[1]`, namespace prefixes are ignored, and tag names compare case-insensitively.
    public func block(atElementPath path: String) -> Block? {
        let wanted = Chapter.normalizedSteps(path)
        return blocks.first { Chapter.normalizedSteps($0.elementPath) == wanted }
    }

    /// The chapter text in `range` (UTF-16 offsets) as a reader would quote it: a table's row
    /// objects become their rows' text (`TableContent.plainText`), one line each; everything else
    /// is the plain text as is.
    public func displayText(in range: Range<Int>) -> String {
        var result = ""
        for block in blocks {
            let blockEnd = block.textOffset + block.textLength + 1   // the "\n" separator included
            guard block.textOffset < range.upperBound, blockEnd > range.lowerBound else { continue }
            let start = max(range.lowerBound, block.textOffset) - block.textOffset
            let end = min(range.upperBound, blockEnd) - block.textOffset
            if case .table(let table) = block.kind {
                let objects = stride(from: start + start % 2, to: min(end, block.textLength), by: 2)
                result += objects.map { table.plainText(atOffset: $0) }.joined(separator: "\n")
                if end > block.textLength { result += "\n" }
            } else {
                let units = Array((block.text + "\n").utf16)
                result += String(decoding: units[start ..< end], as: UTF16.self)
            }
        }
        return result
    }


    /// The block whose element path is the deepest ancestor-or-self of `path`, when no block
    /// matches exactly (pointers into inline elements, e.g. ".../p[3]/span[2]").
    public func block(nearestElementPath path: String) -> Block? {
        var steps = Chapter.normalizedSteps(path)
        while !steps.isEmpty {
            if let b = blocks.first(where: { Chapter.normalizedSteps($0.elementPath) == steps }) { return b }
            steps.removeLast()
        }
        return nil
    }

    static func normalizedSteps(_ path: String) -> [String] {
        path.split(separator: "/").map { raw -> String in
            var step = String(raw).lowercased()
            if let colon = step.firstIndex(of: ":"), !step.contains("[") || colon < step.firstIndex(of: "[")! {
                step = String(step[step.index(after: colon)...])
            }
            if !step.contains("[") { step += "[1]" }
            return step
        }
    }
}
