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
}

/// One block-level piece of a chapter: a paragraph, heading, image, rule...
///
/// Offsets are UTF-16 unit offsets into the chapter's plain text, where the plain text is the
/// concatenation of every block's `text` followed by a single "\n" separator. An image block's
/// text is exactly one U+FFFC (object replacement character). The app's typesetter produces an
/// attributed string with that exact layout, so a `textOffset` is directly usable as an
/// `NSAttributedString` index.
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
