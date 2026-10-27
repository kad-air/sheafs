import Foundation

/// The state machine behind `XHTMLConverter`: consumes tokens and accumulates blocks.
///
/// The element stack mirrors CREngine's view of the document so that `Block.elementPath`
/// lines up with KOReader xpointers. Every non-void element gets a stack frame with per-tag
/// child counters; a child's step is `tag[n]`, `n` being 1-based among same-tag siblings
/// opened so far under that parent. Void elements never get a frame; they are counted only
/// under their own tag (`img[2]`), which cannot change the step of any other element, so every
/// `p`/`div`/... path is exactly what the reference algorithm produces.
struct ChapterBuilder {
    /// The unit separating the lines of a `br`.
    static let lineSeparator: Unicode.Scalar = "\u{2028}"
    /// The text of an image or rule block.
    static let objectReplacement = "\u{FFFC}"
    /// Joins the cells of a table row.
    static let cellSeparator = " \u{2003} "

    // MARK: Types

    private enum Phase {
        case beforeBody, inBody, afterBody
    }

    /// One open element.
    private struct Frame {
        var tag: String
        /// What stylesheet selectors match against.
        var element: CSSElement
        var path: String
        var role: ElementRole
        /// Children opened so far, by tag (drives the `tag[n]` steps).
        var counts: [String: Int] = [:]

        // Context inherited by everything inside the element.
        var style: InlineStyle
        var link: String?
        var alignment: BlockAlignment?
        var indent: Int
        var inBlockquote: Bool
        var listDepth: Int
        var hidden: Bool
        var inSVG: Bool
        var preformatted: Bool

        // Role-specific.
        var blockKind: BlockKind?
        var isOrderedList = false
        var nextOrdinal = 1
    }

    /// The block currently being filled with text.
    private struct BlockBuilder {
        var kind: BlockKind
        var alignment: BlockAlignment
        var indent: Int
        var path: String
        var preformatted: Bool
        var isRow: Bool
        /// HTML ignores one newline right after `<pre>`.
        var dropLeadingNewline: Bool
        var runs: [InlineRun] = []
        /// UTF-16 length of the text so far (used for anchor offsets).
        var length = 0
        /// True at the start of a block and after a line break: whitespace is dropped there.
        var lastWasSpace = true
        /// A table cell ended; the next cell with content is preceded by the separator.
        var pendingSeparator = false
        /// Anchors recorded while this block was open; clamped to the block's final extent.
        var anchorIDs: [String] = []

        mutating func append(_ text: String, style: InlineStyle, link: String?) {
            var piece = String.UnicodeScalarView()
            if preformatted {
                var previousWasCR = false
                for scalar in text.unicodeScalars {
                    if dropLeadingNewline {
                        dropLeadingNewline = false
                        if scalar == "\n" { continue }
                        if scalar == "\r" {
                            previousWasCR = true
                            continue
                        }
                    }
                    switch scalar {
                    case "\r":
                        piece.append(ChapterBuilder.lineSeparator)
                        previousWasCR = true
                    case "\n":
                        if previousWasCR { previousWasCR = false } else { piece.append(ChapterBuilder.lineSeparator) }
                    default:
                        previousWasCR = false
                        piece.append(scalar)
                    }
                }
            } else {
                if pendingSeparator, text.unicodeScalars.contains(where: { !ChapterBuilder.isCollapsibleSpace($0) }) {
                    pendingSeparator = false
                    if !runs.isEmpty {
                        trimTrailingSpace()
                        appendRaw(ChapterBuilder.cellSeparator, style: [], link: nil)
                        lastWasSpace = true
                    }
                }
                var last = lastWasSpace
                for scalar in text.unicodeScalars {
                    if ChapterBuilder.isCollapsibleSpace(scalar) {
                        if !last {
                            piece.append(" ")
                            last = true
                        }
                    } else {
                        piece.append(scalar)
                        last = scalar == ChapterBuilder.lineSeparator
                    }
                }
                lastWasSpace = last
            }
            guard !piece.isEmpty else { return }
            appendRaw(String(piece), style: style, link: link)
        }

        /// Appends a line break, taking the style of the text before it so runs do not fragment.
        mutating func appendLineBreak() {
            if !preformatted { trimTrailingSpace() }
            appendRaw(String(ChapterBuilder.lineSeparator), style: runs.last?.style ?? [], link: runs.last?.link)
            lastWasSpace = true
        }

        private mutating func appendRaw(_ text: String, style: InlineStyle, link: String?) {
            if let lastIndex = runs.indices.last, runs[lastIndex].style == style, runs[lastIndex].link == link {
                runs[lastIndex].text += text
            } else {
                runs.append(InlineRun(text: text, style: style, link: link))
            }
            length += text.utf16.count
        }

        /// Removes one trailing ASCII space, if the text ends with one.
        @discardableResult
        mutating func trimTrailingSpace() -> Bool {
            removeTrailing { $0 == " " }
        }

        /// Removes trailing spaces and line breaks (what trailing `<br/>` and indentation leave).
        mutating func trimTrailing() {
            while removeTrailing({ $0 == " " || $0 == ChapterBuilder.lineSeparator }) {}
        }

        /// Removes one trailing line break: the last newline of a `<pre>` ends its last line
        /// rather than starting another, and the block separator already does that job.
        mutating func trimTrailingLineBreak() {
            removeTrailing { $0 == ChapterBuilder.lineSeparator }
        }

        @discardableResult
        private mutating func removeTrailing(_ matches: (Unicode.Scalar) -> Bool) -> Bool {
            guard let lastIndex = runs.indices.last, let scalar = runs[lastIndex].text.unicodeScalars.last,
                  matches(scalar) else { return false }
            runs[lastIndex].text.unicodeScalars.removeLast()
            if runs[lastIndex].text.isEmpty { runs.removeLast() }
            length -= scalar.utf16.count
            return true
        }

        /// A preformatted block with nothing but whitespace and line breaks is dropped.
        var isBlankPreformatted: Bool {
            runs.allSatisfy { run in
                run.text.unicodeScalars.allSatisfy { ChapterBuilder.isCollapsibleSpace($0) || $0 == ChapterBuilder.lineSeparator }
            }
        }
    }

    // MARK: State

    private var phase = Phase.beforeBody
    private var stack: [Frame] = []
    private var current: BlockBuilder?
    private var blocks: [Block] = []
    /// Running plain-text length: every flushed block's text plus its "\n" separator.
    private var offset = 0
    private var anchors: [String: Int] = [:]
    /// The marker of a list item that has no text of its own (`<li><p>text</p></li>`): the first
    /// paragraph inside it becomes the list item block.
    private var pendingListItem: BlockKind?

    // Stylesheets.
    /// Loads the stylesheet a `<link rel="stylesheet" href>` names (nil: none, or no loader).
    private let linkedStylesheet: ((String) -> Stylesheet?)?
    /// The document's stylesheets in order: linked ones and `<style>` blocks from the head.
    private var cascade = StyleCascade()
    private var hasStyleRules = false
    /// The `<html>` element, the ancestor of `<body>` that selectors like `html body p` expect.
    private var rootElement = CSSElement(tag: "html", attributes: [:])
    private var rootAttributes: [String: String] = [:]
    /// The text of the head `<style>` block being read.
    private var styleBuffer: String?

    // Before the body.
    private var inHead = false
    /// The `style`/`script`/`template`/`noscript` element being skipped in the head.
    private var skippedHeadElement: String?
    private var titleBuffer: String?
    private var title: String?

    init(linkedStylesheet: ((String) -> Stylesheet?)? = nil) {
        self.linkedStylesheet = linkedStylesheet
    }

    // MARK: Input

    mutating func consume(_ token: HTMLToken) {
        switch phase {
        case .beforeBody:
            consumeBeforeBody(token)
        case .inBody:
            switch token {
            case let .text(text): handleText(text)
            case let .start(name, attributes, selfClosing): handleStart(name, attributes, selfClosing: selfClosing)
            case let .end(name): handleEnd(name)
            }
        case .afterBody:
            if case let .start(name, attributes, _) = token, name == "body" { beginBody(attributes) }
        }
    }

    mutating func finish() -> Chapter {
        switch phase {
        case .inBody: closeBody()
        case .beforeBody: finishTitle()
        case .afterBody: break
        }
        return Chapter(blocks: blocks, textLength: offset, anchorOffsets: anchors, title: title)
    }

    // MARK: Before the body

    private mutating func consumeBeforeBody(_ token: HTMLToken) {
        if titleBuffer != nil {
            switch token {
            case let .text(text):
                titleBuffer?.append(text)
            case let .end(name) where name == "title":
                finishTitle()
            case let .end(name) where name == "head":
                finishTitle()
                inHead = false
            case let .start(name, attributes, _) where name == "body":
                finishTitle()
                beginBody(attributes)
            default:
                break
            }
            return
        }
        if let skipped = skippedHeadElement {
            switch token {
            case let .text(text):
                styleBuffer?.append(text)
            case let .end(name) where name == skipped:
                skippedHeadElement = nil
                if let css = styleBuffer {
                    styleBuffer = nil
                    addStylesheet(Stylesheet(css: css))
                }
            default:
                break
            }
            return
        }

        switch token {
        case let .start(name, attributes, selfClosing):
            switch name {
            case "html":
                rootElement = CSSElement(tag: "html", attributes: attributes)
                rootAttributes = attributes
            case "link":
                linkStylesheet(attributes)
            case "meta", "base", "basefont", "bgsound":
                break
            case "head":
                inHead = true
            case "title":
                if title == nil, !selfClosing { titleBuffer = "" }
            case "style", "script", "template", "noscript":
                if !selfClosing {
                    skippedHeadElement = name
                    if name == "style", Self.isCSS(type: attributes["type"]), CSSScanner.mediaApplies(attributes["media"]) {
                        styleBuffer = ""
                    }
                }
            case "body":
                beginBody(attributes)
            default:
                // Any other content starts an implicit body (fragments without <body>).
                beginBody([:])
                consume(token)
            }
        case let .end(name):
            if name == "head" { inHead = false }
        case let .text(text):
            if !inHead, text.unicodeScalars.contains(where: { !Self.isCollapsibleSpace($0) }) {
                beginBody([:])
                consume(token)
            }
        }
    }

    private mutating func finishTitle() {
        guard let buffer = titleBuffer else { return }
        titleBuffer = nil
        let collapsed = Self.collapseWhitespace(buffer)
        if title == nil, !collapsed.isEmpty { title = collapsed }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if isCollapsibleSpace(scalar) {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(scalar)
                lastWasSpace = false
            }
        }
        var collapsed = String(result)
        if collapsed.hasSuffix(" ") { collapsed.removeLast() }
        return collapsed
    }

    // MARK: Stylesheets

    private mutating func linkStylesheet(_ attributes: [String: String]) {
        let rel = (attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
        guard rel.contains("stylesheet"), !rel.contains("alternate"), Self.isCSS(type: attributes["type"]),
              CSSScanner.mediaApplies(attributes["media"]),
              let href = attributes["href"], !href.isEmpty,
              let sheet = linkedStylesheet?(href) else { return }
        addStylesheet(sheet)
    }

    private mutating func addStylesheet(_ sheet: Stylesheet) {
        cascade.sheets.append(sheet)
        if sheet.ruleCount > 0 { hasStyleRules = true }
    }

    private static func isCSS(type: String?) -> Bool {
        guard let type = type?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else { return true }
        return type == "text/css"
    }

    /// The CSS that applies to an element about to be opened under the current stack (`<html>`
    /// above `<body>`): the stylesheets' rules, then its own `style` attribute.
    private func cssProperties(for element: CSSElement, attributes: [String: String], isRoot: Bool = false) -> CSSProperties {
        let inline = CSSDeclarations(attributes["style"])
        guard hasStyleRules else {
            var properties = inline.normal
            properties.overlay(inline.important)
            return properties
        }
        let ancestors = isRoot ? [] : [rootElement] + stack.map(\.element)
        return cascade.properties(for: element, ancestors: ancestors[...], inline: inline)
    }

    /// The tag's style (inherited + its own) with the CSS applied, keeping `.boldAsSmallCaps`
    /// true to its definition: set where small caps replaced the markup's bold, gone otherwise.
    private static func style(markup: InlineStyle, css: CSSProperties) -> InlineStyle {
        var style = css.applied(to: markup)
        if style.contains(.smallCaps), !style.contains(.bold) {
            if markup.contains(.bold) { style.insert(.boldAsSmallCaps) }
        } else {
            style.remove(.boldAsSmallCaps)
        }
        return style
    }

    // MARK: Body

    private mutating func beginBody(_ attributes: [String: String]) {
        // A second <body> restarts the stack, like the reference path algorithm.
        while !stack.isEmpty { popFrame() }
        flush()
        phase = .inBody
        // `<html>` is not a frame, but what the CSS declares on it is inherited by the body.
        let rootCSS = cssProperties(for: rootElement, attributes: rootAttributes, isRoot: true)
        let rootStyle = Self.style(markup: [], css: rootCSS)
        let element = CSSElement(tag: "body", attributes: attributes)
        let css = cssProperties(for: element, attributes: attributes)
        let body = Frame(
            tag: "body", element: element, path: "/body", role: .container,
            style: Self.style(markup: rootStyle, css: css), link: nil,
            alignment: css.alignment ?? XHTMLSemantics.alignment(of: attributes) ?? rootCSS.alignment,
            indent: 0, inBlockquote: false, listDepth: 0,
            hidden: rootCSS.hidden == true || css.hidden == true || attributes["hidden"] != nil,
            inSVG: false, preformatted: false
        )
        stack = [body]
        recordAnchors(attributes, tag: "body")
    }

    private mutating func closeBody() {
        while !stack.isEmpty { popFrame() }
        flush()
        phase = .afterBody
    }

    private mutating func handleText(_ text: String) {
        let top = stack.count - 1
        guard !stack[top].hidden, !stack[top].inSVG else { return }
        addText(text, style: stack[top].style, link: stack[top].link)
    }

    private mutating func handleStart(_ name: String, _ attributes: [String: String], selfClosing: Bool) {
        if name == "body" {
            beginBody(attributes)
            return
        }
        let isVoidElement = HTMLTokenizer.voidElements.contains(name)
        let role = XHTMLSemantics.role(of: name)

        if XHTMLSemantics.closesParagraph.contains(name) { autoClose(for: name) }

        // The step: tag[n], n counting same-tag siblings opened so far under this parent. (Void
        // elements are counted under their own tag only, which cannot change any other step.)
        let top = stack.count - 1
        let n = (stack[top].counts[name] ?? 0) + 1
        stack[top].counts[name] = n
        let parent = stack[top]

        // Stylesheet rules and the style attribute act at exactly this point: they change the
        // frame's style, alignment and visibility, never the element's path.
        let element = CSSElement(tag: name, attributes: attributes)
        let css = cssProperties(for: element, attributes: attributes)
        let ownAlignment = css.alignment ?? XHTMLSemantics.alignment(of: attributes)
        var frame = Frame(
            tag: name, element: element, path: parent.path + "/" + name + "[" + String(n) + "]", role: role,
            style: Self.style(markup: parent.style.union(XHTMLSemantics.style(forTag: name)), css: css),
            link: parent.link,
            alignment: ownAlignment ?? parent.alignment,
            indent: parent.indent, inBlockquote: parent.inBlockquote, listDepth: parent.listDepth,
            hidden: parent.hidden || css.hidden == true || attributes["hidden"] != nil
                || XHTMLSemantics.hiddenElements.contains(name),
            inSVG: parent.inSVG || name == "svg",
            preformatted: parent.preformatted || name == "pre"
        )

        switch name {
        case "a":
            if let href = attributes["href"], !href.isEmpty { frame.link = href }
            if let type = attributes["epub:type"], type.lowercased().contains("noteref") {
                frame.style.insert(.superscript)
            }
        case "center":
            if ownAlignment == nil { frame.alignment = .center }
        case "blockquote":
            frame.indent += 1
            frame.inBlockquote = true
        case "ul", "ol":
            if parent.listDepth > 0 { frame.indent += 1 }
            frame.listDepth += 1
            frame.isOrderedList = name == "ol"
            if name == "ol", let start = attributes["start"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                frame.nextOrdinal = start
            }
        case "dd":
            frame.indent += 1
        default:
            break
        }

        switch name {
        case "p":
            frame.blockKind = frame.inBlockquote ? .blockquote : .paragraph
        case "h1", "h2", "h3", "h4", "h5", "h6":
            frame.blockKind = .heading(level: XHTMLSemantics.headingLevel(name) ?? 1)
        case "li":
            frame.blockKind = listItemKind(attributes: attributes, fallbackOrdinal: n)
        case "pre":
            frame.blockKind = .preformatted
        case "figcaption", "caption":
            frame.blockKind = .caption
        case "dt", "dd", "tr":
            frame.blockKind = .paragraph
        default:
            break
        }

        if !frame.hidden {
            // 1. Close whatever the new element ends, and open its block.
            switch name {
            case "img", "hr":
                flush()
            case "image" where frame.inSVG:
                flush()
            default:
                switch role {
                case .block:
                    flush()
                    openBlock(for: frame)
                case .container:
                    flush()
                case .inline:
                    break
                }
            }
            // 2. Anchors point at the offset where the element's content starts.
            recordAnchors(attributes, tag: name)
            // 3. Leaf content.
            switch name {
            case "img":
                emitImage(frame: frame, source: attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"],
                          alt: attributes["alt"])
            case "image" where frame.inSVG:
                emitImage(frame: frame, source: attributes["xlink:href"] ?? attributes["href"] ?? attributes["src"],
                          alt: attributes["alt"])
            case "hr":
                emitRule(frame: frame)
            case "br":
                current?.appendLineBreak()
            case "td", "th":
                if current?.isRow == true { current?.pendingSeparator = true }
            default:
                break
            }
        } else {
            // Hidden content still has its anchors, at the offset where it would have been: a
            // note link into a CSS-hidden `aside` lands there instead of at the chapter start.
            recordAnchors(attributes, tag: name)
        }

        guard !isVoidElement else { return }
        stack.append(frame)
        if name == "q", !frame.hidden { addText("\u{201C}", style: frame.style, link: frame.link) }
        if selfClosing { popFrame() }
    }

    private mutating func handleEnd(_ name: String) {
        if name == "body" {
            closeBody()
            return
        }
        // Void elements never have a close; an unknown close is ignored.
        guard !HTMLTokenizer.voidElements.contains(name),
              let index = stack.lastIndex(where: { $0.tag == name }), index >= 1 else { return }
        while stack.count > index { popFrame() }
    }

    /// Pops the top frame, finishing whatever it owned.
    private mutating func popFrame() {
        let frame = stack.removeLast()
        guard !frame.hidden else { return }
        if frame.tag == "q" { addText("\u{201D}", style: frame.style, link: frame.link) }
        if frame.role != .inline { flush() }
        if frame.tag == "li" { pendingListItem = nil }
    }

    /// Implicitly closes elements that a new block-level tag ends: an open `p` or heading,
    /// and for `li`/`dt`/`dd`/`tr`/`td`/`th` the previous sibling of the same family.
    private mutating func autoClose(for name: String) {
        let closes: Set<String>
        switch name {
        case "li": closes = ["li"]
        case "dt", "dd": closes = ["dt", "dd"]
        case "tr": closes = ["td", "th", "tr"]
        case "td", "th": closes = ["td", "th"]
        default: closes = []
        }
        var target: Int?
        var index = stack.count - 1
        while index >= 1 {
            let tag = stack[index].tag
            if closes.contains(tag) || XHTMLSemantics.isParagraphLike(tag) {
                target = index
            } else if stack[index].role != .inline {
                break
            }
            index -= 1
        }
        if let target {
            while stack.count > target { popFrame() }
        }
    }

    private mutating func listItemKind(attributes: [String: String], fallbackOrdinal: Int) -> BlockKind {
        guard let listIndex = stack.lastIndex(where: { $0.tag == "ul" || $0.tag == "ol" }) else {
            return .listItem(ordered: false, ordinal: fallbackOrdinal)
        }
        let ordinal = attributes["value"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? stack[listIndex].nextOrdinal
        stack[listIndex].nextOrdinal = ordinal + 1
        return .listItem(ordered: stack[listIndex].isOrderedList, ordinal: ordinal)
    }

    private mutating func recordAnchors(_ attributes: [String: String], tag: String) {
        let here = offset + (current?.length ?? 0)
        var names: [String] = []
        if let id = attributes["id"], !id.isEmpty { names.append(id) }
        if tag == "a", let name = attributes["name"], !name.isEmpty { names.append(name) }
        for name in names where anchors[name] == nil {
            anchors[name] = here
            current?.anchorIDs.append(name)
        }
    }

    // MARK: Blocks

    private mutating func openBlock(for frame: Frame) {
        current = BlockBuilder(
            kind: adoptingListMarker(frame.blockKind ?? .paragraph), alignment: frame.alignment ?? .natural,
            indent: frame.indent,
            path: frame.path, preformatted: frame.preformatted, isRow: frame.tag == "tr",
            dropLeadingNewline: frame.tag == "pre"
        )
    }

    /// Opens a block for text that has no block element of its own: an implicit paragraph of
    /// the nearest container, or the continuation of a block element after an image or a
    /// nested block interrupted it.
    private mutating func openImplicitBlock() {
        guard let ownerIndex = stack.lastIndex(where: { $0.role != .inline }) else { return }
        let owner = stack[ownerIndex]
        let kind: BlockKind
        if owner.role == .block {
            if case .listItem = owner.blockKind { kind = .paragraph } else { kind = owner.blockKind ?? .paragraph }
        } else {
            kind = owner.inBlockquote ? .blockquote : .paragraph
        }
        current = BlockBuilder(
            kind: adoptingListMarker(kind), alignment: owner.alignment ?? .natural, indent: owner.indent,
            path: owner.path,
            preformatted: owner.preformatted, isRow: false, dropLeadingNewline: false
        )
    }

    /// A paragraph that opens inside an empty list item carries the item's marker; any other
    /// block opening ends the wait.
    private mutating func adoptingListMarker(_ kind: BlockKind) -> BlockKind {
        defer { pendingListItem = nil }
        switch kind {
        case .paragraph, .blockquote: return pendingListItem ?? kind
        default: return kind
        }
    }

    private mutating func addText(_ text: String, style: InlineStyle, link: String?) {
        if current == nil {
            guard text.unicodeScalars.contains(where: { !Self.isCollapsibleSpace($0) }) else { return }
            openImplicitBlock()
        }
        current?.append(text, style: style, link: link)
    }

    /// Finishes the open block: trims it and appends it unless it is empty.
    private mutating func flush() {
        guard var block = current else { return }
        current = nil
        var keep = true
        if block.preformatted {
            if block.isBlankPreformatted { keep = false } else { block.trimTrailingLineBreak() }
        } else {
            block.trimTrailing()
            if block.runs.isEmpty {
                keep = false
                if case .listItem = block.kind { pendingListItem = block.kind }
            }
        }
        // Anchors were placed while the block was still growing. Trimming (trailing spaces and
        // line breaks) or dropping the block pulls them back to where its text really ends.
        let end = keep ? offset + block.runs.reduce(0) { $0 + $1.text.utf16.count } : offset
        for id in block.anchorIDs {
            if let position = anchors[id], position > end { anchors[id] = end }
        }
        guard keep else { return }
        append(Block(
            id: blocks.count, kind: block.kind, runs: block.runs, alignment: block.alignment,
            indent: block.indent, elementPath: block.path, textOffset: offset
        ))
    }

    private mutating func emitImage(frame: Frame, source: String?, alt: String?) {
        guard let source, !source.isEmpty else { return }
        append(Block(
            id: blocks.count, kind: .image(source: source, alt: alt),
            runs: [InlineRun(text: Self.objectReplacement, style: [], link: frame.link)],
            alignment: frame.alignment ?? .natural, indent: frame.indent, elementPath: frame.path,
            textOffset: offset
        ))
    }

    /// A rule's text is one U+FFFC, like an image: the typesetter draws it as a text attachment.
    private mutating func emitRule(frame: Frame) {
        append(Block(
            id: blocks.count, kind: .horizontalRule,
            runs: [InlineRun(text: Self.objectReplacement)],
            alignment: frame.alignment ?? .natural,
            indent: frame.indent, elementPath: frame.path, textOffset: offset
        ))
    }

    private mutating func append(_ block: Block) {
        blocks.append(block)
        offset += block.textLength + 1
    }

    // MARK: Characters

    /// Whitespace that collapses: space, tab, newline, carriage return, form feed. U+00A0 and
    /// the other Unicode spaces are content and stay as written.
    static func isCollapsibleSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0C: return true
        default: return false
        }
    }
}
