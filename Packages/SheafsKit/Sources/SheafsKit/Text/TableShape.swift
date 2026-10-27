import Foundation

/// How a `<table>` is converted.
enum TableMode: Sendable {
    /// One `.table` block, drawn as a table.
    case table
    /// The table's content as ordinary blocks: a row of plain cells becomes a paragraph with its
    /// cells joined by `ChapterBuilder.cellSeparator`, and block elements in cells (headings,
    /// paragraphs) become blocks of their own. What a LAYOUT table (a page of headings and
    /// paragraphs in one cell, common in older converted books) must be: as one table row it
    /// would be cut at the page height and every anchor in it would resolve to the row.
    case flatten
}

/// Decides a table's `TableMode` from its tokens, before any of them is converted. The table is
/// flattened when
/// - one of its cells holds block content: a heading, list, blockquote or `pre`, or two or more
///   paragraphs (`p`, or a `div` with text of its own). A single `<p>` in a cell is plain cell
///   text: converters wrap every cell's text in one;
/// - one of its cells holds more than `cellCharacterLimit` characters other than whitespace (a
///   row that size would not fit a page);
/// - it has a single column (counting `colspan`): that is a layout, not a table.
/// Cells of tables nested in a cell count for the outer cell. `scripts/gen_chapter_reference.py`
/// (`TableDecider`) makes the same decision.
enum TableShape {
    static let cellCharacterLimit = 600

    private static let blockContent: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "blockquote", "pre",
    ]

    /// `tokens` start with the table's start tag and end with its end tag (or the input's end).
    static func mode(of tokens: [HTMLToken]) -> TableMode {
        var depth = 0
        var inCell = false
        var rowColumns = 0, columns = 0
        var openBlocks: [(tag: String, hasText: Bool)] = []
        var textBlocks = 0
        var characters = 0
        for token in tokens {
            switch token {
            case let .start(name, attributes, selfClosing):
                if name == "table" {
                    if !selfClosing { depth += 1 }
                    continue
                }
                if depth == 1 {
                    switch name {
                    case "tr":
                        columns = max(columns, rowColumns)
                        rowColumns = 0
                        inCell = false
                    case "td", "th":
                        let span = attributes["colspan"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                        rowColumns += max(1, min(span, 64))
                        inCell = !selfClosing
                        openBlocks = []
                        textBlocks = 0
                        characters = 0
                        continue
                    case "caption":
                        inCell = false
                    default:
                        break
                    }
                }
                guard inCell else { continue }
                if blockContent.contains(name) { return .flatten }
                if (name == "p" || name == "div") && !selfClosing { openBlocks.append((name, false)) }
            case let .end(name):
                if name == "table" {
                    depth -= 1
                    if depth <= 0 { return decide(columns: max(columns, rowColumns)) }
                    continue
                }
                if depth == 1, name == "td" || name == "th" {
                    inCell = false
                    continue
                }
                guard inCell, name == "p" || name == "div",
                      let index = openBlocks.lastIndex(where: { $0.tag == name }) else { continue }
                let closed = openBlocks[index...]
                if closed.contains(where: \.hasText) {
                    textBlocks += 1
                    if textBlocks >= 2 { return .flatten }
                }
                openBlocks.removeSubrange(index...)
            case let .text(text):
                guard inCell else { continue }
                let count = text.unicodeScalars.reduce(0) { $0 + (ChapterBuilder.isCollapsibleSpace($1) ? 0 : 1) }
                guard count > 0 else { continue }
                characters += count
                if characters > cellCharacterLimit { return .flatten }
                if !openBlocks.isEmpty { openBlocks[openBlocks.count - 1].hasText = true }
            }
        }
        return decide(columns: max(columns, rowColumns))
    }

    private static func decide(columns: Int) -> TableMode {
        columns <= 1 ? .flatten : .table
    }
}
