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
    /// Joins the cells of a table nested in a table cell (and of a stray row outside any table).
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
        /// Open `table` elements built as tables, this one included: 1 is the table being built,
        /// more is a table nested in one of its cells.
        var tableDepth: Int
        /// Inside a `thead`: its cells are header cells.
        var inTableHead: Bool

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
        /// A block ended inside a table cell; the next text starts a new line of the cell.
        var pendingLineBreak = false
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
                if pendingSeparator || pendingLineBreak,
                   text.unicodeScalars.contains(where: { !ChapterBuilder.isCollapsibleSpace($0) }) {
                    let lineBreak = pendingLineBreak
                    pendingSeparator = false
                    pendingLineBreak = false
                    if !runs.isEmpty {
                        if lineBreak {
                            appendLineBreak()
                        } else {
                            trimTrailingSpace()
                            appendRaw(ChapterBuilder.cellSeparator, style: [], link: nil)
                            lastWasSpace = true
                        }
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

    /// The table being built: finished rows, the open row and cell, the caption.
    private struct TableBuilder {
        let path: String
        let alignment: BlockAlignment
        let indent: Int
        private(set) var rows: [TableContent.Row] = []
        private var rowPath: String?
        private var rowCells: [TableContent.Cell] = []
        /// The open row is the rest of a row an image split: where it carries on, and dropped
        /// if nothing but empty cells follow the image.
        private var rowFirstColumn = 0
        private var rowResumed = false
        private var cell: BlockBuilder?
        private var cellShape = TableContent.Cell(runs: [])
        private var captionText: BlockBuilder?
        private(set) var caption: [InlineRun]?
        /// Anchors recorded inside the table; clamped to its extent when it is emitted.
        var anchorIDs: [String] = []

        init(path: String, alignment: BlockAlignment, indent: Int) {
            self.path = path
            self.alignment = alignment
            self.indent = indent
        }

        /// Where an anchor inside the table points: the object of the row being built.
        var anchorOffset: Int { 2 * rows.count }

        private static func textBuilder() -> BlockBuilder {
            BlockBuilder(kind: .paragraph, alignment: .natural, indent: 0, path: "", preformatted: false,
                         isRow: false, dropLeadingNewline: false)
        }

        mutating func startRow(path: String) {
            finishRow()
            rowPath = path
        }

        mutating func startCell(isHeader: Bool, columnSpan: Int, alignment: BlockAlignment?) {
            finishCaption()
            finishCell()
            if rowPath == nil { rowPath = path }
            cell = Self.textBuilder()
            cellShape = TableContent.Cell(runs: [], isHeader: isHeader, columnSpan: columnSpan, alignment: alignment)
        }

        mutating func startCaption() {
            finishCaption()
            if caption == nil { captionText = Self.textBuilder() }
        }

        mutating func addText(_ text: String, style: InlineStyle, link: String?) {
            if captionText != nil {
                captionText?.append(text, style: style, link: link)
                return
            }
            if cell == nil {
                // Text loose in a row or table (not just indentation) makes a cell of its own.
                guard text.unicodeScalars.contains(where: { !ChapterBuilder.isCollapsibleSpace($0) }) else { return }
                startCell(isHeader: false, columnSpan: 1, alignment: nil)
            }
            cell?.append(text, style: style, link: link)
        }

        mutating func lineBreak() {
            if captionText != nil { captionText?.appendLineBreak() } else { cell?.appendLineBreak() }
        }

        /// A block element opened or closed inside the cell: what follows starts a new line.
        mutating func blockBoundary() {
            if captionText != nil { captionText?.pendingLineBreak = true } else { cell?.pendingLineBreak = true }
        }

        /// A cell of a nested table: joined to the previous one by the cell separator.
        mutating func cellBoundary() {
            cell?.pendingSeparator = true
        }

        mutating func finishCell() {
            guard var text = cell else { return }
            cell = nil
            text.trimTrailing()
            var finished = cellShape
            finished.runs = text.runs
            rowCells.append(finished)
        }

        mutating func finishRow() {
            finishCell()
            let empty = rowCells.allSatisfy(\.runs.isEmpty)
            if let rowPath, !rowCells.isEmpty, !(rowResumed && empty) {
                rows.append(TableContent.Row(cells: rowCells, elementPath: rowPath, firstColumn: rowFirstColumn))
            }
            rowPath = nil
            rowCells = []
            rowFirstColumn = 0
            rowResumed = false
        }

        mutating func finishCaption() {
            guard var text = captionText else { return }
            captionText = nil
            text.trimTrailing()
            if caption == nil, !text.runs.isEmpty { caption = text.runs }
        }

        /// The rows so far, the open row included, without the caption; the open row and cell
        /// continue (same path, same kind of cell) in what comes next.
        mutating func takeFinishedPart() -> TableContent {
            let openPath = rowPath
            let openCell = cell == nil ? nil : cellShape
            // The open cell carries on after the image in its own column.
            let resumeColumn = rowFirstColumn + rowCells.reduce(0) { $0 + $1.columnSpan }
            if var text = cell {
                text.trimTrailing()
                if text.runs.isEmpty { cell = nil }
            }
            // Nothing but empty cells before the image: no row (and no ruled empty table) for it.
            rowResumed = true
            finishRow()
            let part = TableContent(rows: rows)
            rows = []
            if let openPath {
                rowPath = openPath
                rowFirstColumn = resumeColumn
                rowResumed = true
            }
            if let openCell {
                cell = Self.textBuilder()
                cellShape = openCell
            }
            return part
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
    /// The table being built: while it is open every piece of text goes into its cells.
    private var table: TableBuilder?
    /// The tokens of a table held back until its end tag (see `TableShape`).
    private var bufferedTable: [HTMLToken]?
    private var bufferedTableDepth = 0
    /// How the next `table` start (a replayed one) is built.
    private var pendingTableMode: TableMode?

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
        if bufferedTable != nil {
            bufferTableToken(token)
            return
        }
        // A table is held back until its end tag, then replayed as a table or as plain blocks.
        if phase == .inBody, table == nil, pendingTableMode == nil, case let .start(name, _, selfClosing) = token,
           name == "table", !selfClosing {
            bufferedTable = [token]
            bufferedTableDepth = 1
            return
        }
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
        if bufferedTable != nil { replayBufferedTable() }
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
            inSVG: false, preformatted: false, tableDepth: 0, inTableHead: false
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
        let tableMode = name == "table" ? pendingTableMode : nil
        if name == "table" { pendingTableMode = nil }

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
            preformatted: parent.preformatted || name == "pre",
            // A flattened table is not counted: a table inside it is built as an outermost one.
            tableDepth: parent.tableDepth + (name == "table" && (table != nil || tableMode != .flatten) ? 1 : 0),
            inTableHead: name == "thead" || (parent.inTableHead && name != "table")
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

        if !frame.hidden, table != nil {
            handleStartInTable(name, attributes, alignment: ownAlignment, frame: frame)
        } else if !frame.hidden, name == "table", tableMode != .flatten {
            flush()
            recordAnchors(attributes, tag: name)
            table = TableBuilder(path: frame.path, alignment: frame.alignment ?? .natural, indent: frame.indent)
        } else if !frame.hidden {
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
        if table != nil {
            popInTable(frame)
        } else if frame.role != .inline {
            flush()
        }
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

    /// Records the element's `id` (and an `a`'s `name`) at the current offset; inside a table, at
    /// the object of the row being built.
    private mutating func recordAnchors(_ attributes: [String: String], tag: String) {
        let here = offset + (table?.anchorOffset ?? current?.length ?? 0)
        var names: [String] = []
        if let id = attributes["id"], !id.isEmpty { names.append(id) }
        if tag == "a", let name = attributes["name"], !name.isEmpty { names.append(name) }
        for name in names where anchors[name] == nil {
            anchors[name] = here
            if table != nil { table?.anchorIDs.append(name) } else { current?.anchorIDs.append(name) }
        }
    }

    // MARK: Tables

    /// Holds a table's tokens back until its end tag (or a `body` tag), then replays them.
    private mutating func bufferTableToken(_ token: HTMLToken) {
        bufferedTable?.append(token)
        switch token {
        case let .start(name, _, selfClosing) where name == "table" && !selfClosing:
            bufferedTableDepth += 1
        case let .end(name) where name == "table":
            bufferedTableDepth -= 1
        case let .start(name, _, _) where name == "body":
            bufferedTableDepth = 0
        case let .end(name) where name == "body":
            bufferedTableDepth = 0
        default:
            break
        }
        if bufferedTableDepth <= 0 { replayBufferedTable() }
    }

    /// Converts the held-back table as a table or as plain blocks (`TableShape`). A table nested
    /// in a flattened one is held back and decided on its own when the replay reaches it.
    private mutating func replayBufferedTable() {
        guard let tokens = bufferedTable else { return }
        bufferedTable = nil
        bufferedTableDepth = 0
        pendingTableMode = TableShape.mode(of: tokens)
        for token in tokens { consume(token) }
    }

    /// An element opening inside the table being built. Rows, cells and the caption of that
    /// table shape it; anything else only breaks lines inside the current cell (a nested
    /// table's rows become lines, its cells are joined by the cell separator). An image ends
    /// the table so far: the image becomes its own block and the table continues after it in a
    /// new block with the same path, like a paragraph an image interrupts.
    private mutating func handleStartInTable(_ name: String, _ attributes: [String: String], alignment: BlockAlignment?,
                                             frame: Frame) {
        let direct = frame.tableDepth == 1
        switch name {
        case "tr" where direct:
            table?.startRow(path: frame.path)
        case "td" where direct, "th" where direct:
            let span = attributes["colspan"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
            table?.startCell(isHeader: name == "th" || frame.inTableHead, columnSpan: max(1, min(span, 64)),
                             alignment: alignment)
        case "caption" where direct:
            table?.startCaption()
        case "td", "th":
            table?.cellBoundary()
        case "br":
            table?.lineBreak()
        case "img", "image":
            let source = name == "img"
                ? attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"]
                : attributes["xlink:href"] ?? attributes["href"] ?? attributes["src"]
            guard name == "img" || frame.inSVG, let source, !source.isEmpty else { break }
            guard var builder = table else { break }
            table = nil
            let part = builder.takeFinishedPart()
            emitTable(part, from: &builder)
            recordAnchors(attributes, tag: name)
            emitImage(frame: frame, source: source, alt: attributes["alt"])
            table = builder
            return
        default:
            if XHTMLSemantics.role(of: name) != .inline { table?.blockBoundary() }
        }
        recordAnchors(attributes, tag: name)
    }

    /// An element closing inside the table being built.
    private mutating func popInTable(_ frame: Frame) {
        let direct = frame.tableDepth == 1
        switch frame.tag {
        case "table" where direct:
            guard var builder = table else { return }
            table = nil
            builder.finishCaption()
            builder.finishRow()
            let content = TableContent(rows: builder.rows, caption: builder.caption)
            emitTable(content, from: &builder)
        case "tr" where direct:
            table?.finishRow()
        case "td" where direct, "th" where direct:
            table?.finishCell()
        case "caption" where direct:
            table?.finishCaption()
        default:
            if frame.role != .inline { table?.blockBoundary() }
        }
    }

    /// Appends a table block (nothing when it has no rows and no caption) and pulls the anchors
    /// recorded inside it back onto its last object.
    private mutating func emitTable(_ content: TableContent, from builder: inout TableBuilder) {
        let text = content.objectText
        let last = offset + max(0, text.utf16.count - 1)
        for id in builder.anchorIDs {
            if let position = anchors[id], position > last { anchors[id] = last }
        }
        builder.anchorIDs.removeAll()
        guard !text.isEmpty else { return }
        append(Block(
            id: blocks.count, kind: .table(content), runs: [InlineRun(text: text)],
            alignment: builder.alignment, indent: builder.indent, elementPath: builder.path, textOffset: offset
        ))
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
        if table != nil {
            table?.addText(text, style: style, link: link)
            return
        }
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
