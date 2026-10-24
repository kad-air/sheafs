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

    /// Alignment declared by the element itself: inline `text-align`, then the `align`
    /// attribute, then the `center`/`right`-style class conventions.
    static func alignment(of attributes: [String: String], css: InlineCSS) -> BlockAlignment? {
        if let fromStyle = css.alignment { return fromStyle }
        if let align = attributes["align"]?.lowercased() {
            switch align.trimmingCharacters(in: .whitespaces) {
            case "center": return .center
            case "right": return .trailing
            case "justify": return .justified
            case "left": return .natural
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

/// The few inline CSS declarations that matter to the text model.
struct InlineCSS {
    var style: InlineStyle = []
    var alignment: BlockAlignment?
    /// `display: none`.
    var hidden = false

    init(_ declarations: String?) {
        guard let declarations else { return }
        for declaration in declarations.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: colon)...].lowercased()
            if let important = value.range(of: "!important") { value.removeSubrange(important) }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = value.split(whereSeparator: \.isWhitespace)

            switch property {
            case "font-style":
                if words.contains("italic") || words.contains("oblique") { style.insert(.italic) }
            case "font-weight":
                if let word = words.first, word == "bold" || word == "bolder" {
                    style.insert(.bold)
                } else if let word = words.first, let weight = Int(word), (600...900).contains(weight) {
                    style.insert(.bold)
                }
            case "text-decoration", "text-decoration-line":
                if words.contains("underline") { style.insert(.underline) }
                if words.contains("line-through") { style.insert(.strikethrough) }
            case "font-variant", "font-variant-caps":
                if words.contains("small-caps") { style.insert(.smallCaps) }
            case "text-align":
                switch words.first {
                case "center": alignment = .center
                case "right", "end": alignment = .trailing
                case "justify": alignment = .justified
                case "left", "start": alignment = .natural
                default: break
                }
            case "display":
                if words.first == "none" { hidden = true }
            default:
                break
            }
        }
    }
}
