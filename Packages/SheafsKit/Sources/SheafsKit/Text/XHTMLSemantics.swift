import Foundation

/// How an element takes part in block building.
enum ElementRole: Sendable {
    /// Owns a block of text: `p`, headings, `li`, `pre`, captions, `dt`, `dd`, `tr`.
    case block
    /// Only nests other content: `div`, `section`, `blockquote`, lists, tables, `body`...
    case container
    /// Everything else: text flows through into the surrounding block.
    case inline
}

/// The tag tables and attribute interpretation shared by the converter.
enum XHTMLSemantics {
    static let blockElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre", "figcaption", "caption", "dt", "dd", "tr",
    ]

    static let containerElements: Set<String> = [
        "div", "section", "article", "aside", "nav", "header", "footer", "main", "blockquote",
        "ul", "ol", "table", "tbody", "thead", "tfoot", "figure", "dl", "center", "body",
        // Not in the base rule set, but block-level in every HTML dialect; treating them as
        // inline would run their text into the neighbouring paragraph.
        "address", "details", "summary", "form", "fieldset", "hgroup",
    ]

    /// Elements whose whole subtree is skipped. `case` is the EPUB 3 `epub:case` branch of an
    /// `epub:switch`: a reading system without those namespaces uses `epub:default`.
    static let hiddenElements: Set<String> = ["script", "style", "head", "template", "title", "case"]

    /// Tags whose opening implicitly closes an open `p` (or heading) first.
    static let closesParagraph: Set<String> = blockElements.union(containerElements)
        .union(["hr", "td", "th"])

    static func role(of tag: String) -> ElementRole {
        if blockElements.contains(tag) { return .block }
        if containerElements.contains(tag) { return .container }
        return .inline
    }

    static func isParagraphLike(_ tag: String) -> Bool {
        tag == "p" || headingLevel(tag) != nil
    }

    static func headingLevel(_ tag: String) -> Int? {
        guard tag.utf8.count == 2, tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) else {
            return nil
        }
        return level
    }

    /// The style an element contributes by its tag alone.
    static func style(forTag tag: String) -> InlineStyle {
        switch tag {
        case "em", "i", "cite", "dfn", "var": return .italic
        case "strong", "b": return .bold
        case "u", "ins": return .underline
        case "s", "del", "strike": return .strikethrough
        case "code", "kbd", "samp", "tt": return .code
        case "sup": return .superscript
        case "sub": return .subscript
        default: return []
        }
    }

    /// Alignment from the element's presentational markup: the `align` attribute, then the
    /// `center`/`right`-style class conventions. CSS (stylesheets and the `style` attribute)
    /// outranks both. `justify` reads as `.natural`: justification is the reader's setting.
    static func alignment(of attributes: [String: String]) -> BlockAlignment? {
        if let align = attributes["align"]?.lowercased() {
            switch align.trimmingCharacters(in: .whitespaces) {
            case "center": return .center
            case "right": return .trailing
            case "justify", "left": return .natural
            default: break
            }
        }
        if let classes = attributes["class"] {
            for token in classes.lowercased().split(whereSeparator: \.isWhitespace) {
                switch token {
                case "center", "centered", "tc", "ta-c": return .center
                case "right": return .trailing
                default: continue
                }
            }
        }
        return nil
    }
}
