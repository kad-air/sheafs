import Foundation
import SheafsKit
import Testing

/// Tables are one block whose rows and cells live in a `.table` payload; the block's text is one
/// U+FFFC per row (plus one for the caption) joined by U+2028, so the offsets contract holds and
/// pagination can break between rows. Element paths stay CREngine's, checked against the Python
/// twin (`scripts/gen_chapter_reference.py`).
@Suite("Tables")
struct TableTests {
    private typealias T = TextTesting

    static func fixture() throws -> Chapter {
        let url = try #require(Bundle.module.url(forResource: "table-chapter", withExtension: "xhtml", subdirectory: "Fixtures"))
        return XHTMLConverter().convert(try Data(contentsOf: url))
    }

    static func table(_ block: Block) -> TableContent? {
        if case .table(let table) = block.kind { return table }
        return nil
    }

    @Test("the 3×3 fixture: rows, cells, header flags, caption, one object per row")
    func fixtureTable() throws {
        let chapter = try Self.fixture()
        // Known from the fixture file itself: a heading, a paragraph, the table, two paragraphs.
        #expect(chapter.blockPaths == [
            "/body/section[1]/h2[1]", "/body/section[1]/p[1]", "/body/section[1]/table[1]",
            "/body/section[1]/p[2]", "/body/section[1]/p[3]",
        ])
        let block = chapter.blocks[2]
        let table = try #require(Self.table(block))
        #expect(block.text == "\u{FFFC}\u{2028}\u{FFFC}\u{2028}\u{FFFC}\u{2028}\u{FFFC}")
        #expect(block.textLength == 7)
        #expect(block.text == table.objectText)
        #expect(table.columnCount == 3)
        #expect(table.rows.map(\.elementPath) == [
            "/body/section[1]/table[1]/thead[1]/tr[1]",
            "/body/section[1]/table[1]/tbody[1]/tr[1]",
            "/body/section[1]/table[1]/tbody[1]/tr[2]",
        ])
        #expect(table.rows.map { $0.cells.map(\.text) } == [
            ["Town", "People", "Notes"],
            ["Ashby", "1,204", "The old market town"],
            ["Bramley", "", "Not counted"],
        ])
        #expect(table.rows.map { $0.cells.map(\.isHeader) } == [[true, true, true], [false, false, false], [false, false, false]])
        #expect(table.rows.map(\.isHeader) == [true, false, false])
        #expect(table.rows[1].cells[2].runs == [T.run("The "), T.run("old", .italic), T.run(" market town")])
        #expect(table.rows[2].cells[1].runs.isEmpty)
        #expect(table.caption == [T.run("Table 1. The "), T.run("census", .italic), T.run(" of 1901")])
        #expect(table.captionOffset == 6)

        // The text around the table is untouched, and offsets run straight through it.
        #expect(chapter.blocks[1].text == "The census of 1901 counted the market towns of the valley.")
        #expect(chapter.blocks[3].text == "After the census the valley emptied.")
        #expect(chapter.blocks[3].textOffset == block.textOffset + 7 + 1)
        #expect(chapter.textLength == chapter.blocks.last.map { $0.textOffset + $0.textLength + 1 })
        #expect((chapter.plainText as NSString).length == chapter.textLength)
        #expect((chapter.plainText as NSString).substring(with: NSRange(location: block.textOffset, length: 7)) == block.text)

        // Anchors: the table's id at its first object, a row's id at that row's object.
        #expect(chapter.anchorOffsets["census"] == block.textOffset)
        #expect(chapter.anchorOffsets["bramley"] == block.textOffset + table.offset(ofRow: 2))
        #expect(chapter.anchorOffsets["before"] == chapter.blocks[1].textOffset)
    }

    @Test("positions in a table resolve to rows, and back")
    func pointers() throws {
        let chapter = try Self.fixture()
        let block = chapter.blocks[2]
        let table = try #require(Self.table(block))
        for row in table.rows.indices {
            let target = chapter.pointer(at: block.textOffset + table.offset(ofRow: row), spineIndex: 0)
            #expect(target.elementPath == table.rows[row].elementPath)
            #expect(target.characterOffset == nil)
            #expect(chapter.offset(of: XPointer(spineIndex: 0, elementPath: target.elementPath)) == block.textOffset + table.offset(ofRow: row))
        }
        // A pointer into a cell's text (KOReader's kind) lands on the row; the separator after a
        // row's object belongs to that row; the caption's object belongs to the last row.
        #expect(chapter.offset(of: XPointer(spineIndex: 0, elementPath: "/body/section[1]/table[1]/tbody[1]/tr[2]/td[3]", characterOffset: 4))
            == block.textOffset + 4)
        #expect(chapter.pointer(at: block.textOffset + 3, spineIndex: 0).elementPath == table.rows[1].elementPath)
        #expect(chapter.pointer(at: block.textOffset + 6, spineIndex: 0).elementPath == table.rows[2].elementPath)
        // The table itself, and text outside it, as before.
        #expect(chapter.offset(of: XPointer(spineIndex: 0, elementPath: "/body/section[1]/table[1]", characterOffset: 3)) == block.textOffset)
        #expect(chapter.offset(of: XPointer(spineIndex: 0, elementPath: "/body/section[1]/p[2]", characterOffset: 5)) == chapter.blocks[3].textOffset + 5)
        #expect(chapter.pointer(at: chapter.blocks[3].textOffset + 5, spineIndex: 0).characterOffset == 5)
    }

    /// With and without the fixtures' stylesheets: none of their rules hides a table.
    @Test("every table matches the Python reference", arguments: Self.referenceCases(), [false, true])
    func tablesMatchReference(_ testCase: ReferenceCase, stylesheets: Bool) throws {
        let chapter = try testCase.chapter(stylesheets: stylesheets)
        let expected = testCase.document.tables
        // A table split by an image is several blocks with one path; none of these are.
        let tables = chapter.blocks.compactMap { block in Self.table(block).map { (block.elementPath, $0) } }
        #expect(tables.map(\.0) == expected.map(\.path), "\(testCase)")
        for ((_, table), reference) in zip(tables, expected) {
            #expect(table.rows.map(\.elementPath) == reference.rows.map(\.path), "\(reference.path)")
            #expect(table.caption.map { T.normalizedWhitespace($0.map(\.text).joined()) } == reference.caption)
            for (row, referenceRow) in zip(table.rows, reference.rows) {
                #expect(row.cells.map(\.isHeader) == referenceRow.cells.map(\.header), "\(referenceRow.path)")
                // Whitespace runs (line breaks, the nested-cell separator) compare as one space; a
                // lost or added word space does not pass.
                #expect(row.cells.map { T.normalizedWhitespace($0.text) } == referenceRow.cells.map(\.text), "\(referenceRow.path)")
            }
        }
    }

    @Test("the reference holds the fixtures' known tables")
    func referenceKnowsTheTables() throws {
        let reference = try ChapterReference.load()
        // Facts from the fixture files: Alice's contents table (12 chapters, two cells each),
        // Pride's imprint and its 102-row list of illustrations, the 3×3 fixture.
        let alice = reference.epubs["alice-epub3.epub"]?.documents.flatMap(\.tables) ?? []
        #expect(alice.map(\.rows.count) == [12])
        #expect(alice.first?.rows.first?.cells.map(\.text) == ["CHAPTER I.", "Down the Rabbit-Hole"])
        let pride = reference.epubs["pride-epub2.epub"]?.documents.flatMap(\.tables) ?? []
        #expect(pride.map(\.rows.count) == [2, 102])
        let fixture = try #require(reference.xhtml["table-chapter.xhtml"])
        #expect(fixture.tables.count == 1)
        #expect(fixture.tables.first?.rows.map(\.cells.count) == [3, 3, 3])
        let shapes = try #require(reference.xhtml["table-shapes.xhtml"])
        // Loose cells, the calibre table (one <p> per cell) and the table nested in a flattened one;
        // the layout, single-column, long-cell and two-paragraph tables are flattened.
        #expect(shapes.tables.map(\.path) == ["/body/table[1]", "/body/table[5]", "/body/table[6]/tr[1]/td[1]/table[1]"])
        #expect(shapes.tables.first?.rows.map(\.cells.count) == [2])
        #expect(shapes.paragraphCount == 7)
        #expect(Self.referenceCases().count == 35)
    }

    @Test("cells hold their blocks as lines; nested tables flatten into the cell")
    func cellContent() throws {
        let chapter = T.convert("""
            <table><tr><td>One<p>Two <b>bold</b></p></td><td>A<br/>B</td>\
            <td><table><tr><td>x</td><td>y</td></tr><tr><td>z</td></tr></table></td></tr></table><p>after</p>
            """)
        #expect(chapter.blocks.count == 2)
        let table = try #require(Self.table(chapter.blocks[0]))
        #expect(table.rows.count == 1)
        #expect(table.rows[0].cells.map(\.text) == ["One\u{2028}Two bold", "A\u{2028}B", "x \u{2003} y\u{2028}z"])
        #expect(table.rows[0].cells[0].runs == [T.run("One\u{2028}Two "), T.run("bold", .bold)])
        #expect(chapter.blocks[1].elementPath == "/body/p[1]")
        #expect(chapter.blocks[1].textOffset == 2)
    }

    @Test("column spans, loose cells, empty tables, hidden tables")
    func shapes() throws {
        let chapter = T.convert("""
            <table><tr><td colspan="3">wide</td></tr><tr><th>a</th><td>b</td><td>c</td></tr></table>\
            <table><tr></tr></table><table style="display:none"><tr><td>secret</td></tr></table>\
            <table><tr><td>first</td><td colspan="x">bad span</td></tr></table>
            """)
        #expect(chapter.blocks.count == 2)
        let wide = try #require(Self.table(chapter.blocks[0]))
        #expect(wide.rows[0].cells.map(\.columnSpan) == [3])
        #expect(wide.columnCount == 3)
        #expect(wide.rows[1].cells.map(\.isHeader) == [true, false, false])
        #expect(wide.rows[1].isHeader == false)
        #expect(chapter.blocks[1].elementPath == "/body/table[4]")
        #expect(Self.table(chapter.blocks[1])?.rows[0].cells.map(\.columnSpan) == [1, 1])
    }

    @Test("an image in a cell splits the table around it, and the row carries on in its column")
    func imageSplitsTable() throws {
        let chapter = T.convert("""
            <table id="t"><tr><td>Plate</td><td><img src="a.png" id="pic"/></td><td>after</td></tr>\
            <tr><td>next</td><td>row</td><td>three</td></tr></table>
            """)
        #expect(chapter.blockTexts == ["\u{FFFC}", "\u{FFFC}", "\u{FFFC}\u{2028}\u{FFFC}"])
        #expect(chapter.blockPaths == ["/body/table[1]", "/body/table[1]/tr[1]/td[2]/img[1]", "/body/table[1]"])
        let first = try #require(Self.table(chapter.blocks[0]))
        let second = try #require(Self.table(chapter.blocks[2]))
        // Before the image: the cell before it (the image's own cell is still empty there).
        #expect(first.rows.map { $0.cells.map(\.text) } == [["Plate"]])
        #expect(first.rows.map(\.firstColumn) == [0])
        // After it: the image's cell and "after" in columns 2 and 3 of 3, then the next row whole.
        #expect(second.rows.map { $0.cells.map(\.text) } == [["", "after"], ["next", "row", "three"]])
        #expect(second.rows.map(\.firstColumn) == [1, 0])
        #expect(second.columnCount == 3)
        #expect(second.rows.map(\.elementPath) == ["/body/table[1]/tr[1]", "/body/table[1]/tr[2]"])
        #expect(chapter.anchorOffsets["t"] == 0)
        #expect(chapter.anchorOffsets["pic"] == chapter.blocks[1].textOffset)
    }

    @Test("images alone in their rows leave no empty tables around them")
    func imageRowsLeaveNoEmptyTables() throws {
        let chapter = T.convert("""
            <table><tr><td><img src="a.png"/></td></tr><tr><td>Plate I</td><td>The valley</td></tr>\
            <tr><td></td><td><img src="b.png"/></td></tr><tr><td>Plate II</td><td>The road</td></tr></table>
            """)
        // image, table [Plate I], image, table [Plate II]: no [[""]] or [["", ""]] mini-tables.
        #expect(chapter.blocks.map { block -> String in
            switch block.kind {
            case .image(let source, _): return source
            case .table(let table): return table.rows.map { $0.cells.map(\.text).joined(separator: "|") }.joined(separator: "/")
            default: return "?"
            }
        } == ["a.png", "Plate I|The valley", "b.png", "Plate II|The road"])
    }

    @Test("a position on the rest of a row an image split stays there")
    func pointerIntoSplitRow() throws {
        let chapter = T.convert("""
            <p>Before.</p><table><tr><td>Plate</td><td><img src="a.png"/></td><td>after</td></tr></table>
            """)
        let parts = chapter.blocks.filter { Self.table($0) != nil }
        #expect(parts.count == 2)
        let path = "/body/table[1]/tr[1]"
        // Without a hint, the first part (as before); near the second part, the second.
        #expect(chapter.offset(of: XPointer(spineIndex: 0, elementPath: path)) == parts[0].textOffset)
        #expect(chapter.offset(of: XPointer(spineIndex: 0, elementPath: path), near: parts[1].textOffset) == parts[1].textOffset)
        #expect(chapter.offset(of: XPointer(spineIndex: 0, elementPath: path), near: 0) == parts[0].textOffset)
    }

    @Test("layout tables flatten into blocks: headings, paragraphs and anchors of their own")
    func layoutTableFlattens() throws {
        let url = try #require(Bundle.module.url(forResource: "table-shapes", withExtension: "xhtml", subdirectory: "Fixtures"))
        let chapter = XHTMLConverter().convert(try Data(contentsOf: url))
        let tables = chapter.blocks.compactMap { block in Self.table(block).map { (block.elementPath, $0) } }
        #expect(tables.map(\.0) == ["/body/table[1]", "/body/table[5]", "/body/table[6]/tr[1]/td[1]/table[1]"])
        // The layout table: two headings and three paragraphs, each its own block at its own path.
        let layout = chapter.blocks.filter { $0.elementPath.hasPrefix("/body/table[2]/") }
        #expect(layout.map(\.elementPath) == [
            "/body/table[2]/tr[1]/td[1]/h2[1]", "/body/table[2]/tr[1]/td[1]/p[1]", "/body/table[2]/tr[1]/td[1]/p[2]",
            "/body/table[2]/tr[1]/td[1]/h2[2]", "/body/table[2]/tr[1]/td[1]/p[3]",
        ])
        #expect(layout.first?.kind == .heading(level: 2))
        // Contents links into it land on their own headings, not all on one row.
        let c1 = try #require(chapter.anchorOffsets["c1"]), c2 = try #require(chapter.anchorOffsets["c2"])
        #expect(c1 == layout[0].textOffset)
        #expect(c2 == layout[3].textOffset)
        #expect(c1 != c2)
        // A single column: each row a paragraph. A cell over the character limit: the row as text.
        #expect(chapter.blocks.filter { $0.elementPath.hasPrefix("/body/table[3]/") }.map(\.text)
            == ["One column", "is a layout, not a table"])
        let long = try #require(chapter.blocks.first { $0.elementPath == "/body/table[4]/tr[1]" })
        #expect(long.text.hasPrefix("Boundary \u{2003} The surveyor walked"))
        // The calibre table (one <p> in each cell) stays a table; the outer table with two
        // paragraphs in a cell is flattened, and the table inside it is a table of its own.
        #expect(tables[1].1.rows.map { $0.cells.map(\.text) } == [["Year", "Stones"], ["1881", "412"]])
        #expect(tables[2].1.rows.first?.cells.map(\.isHeader) == [true, true])
        // Loose cells with no <tr>: one row.
        #expect(tables[0].1.rows.map { $0.cells.map(\.text) } == [["North", "South"]])
        #expect(tables[0].1.rows.first?.elementPath == "/body/table[1]")
    }

    @Test("paragraphs of the loose fixtures match the reference (flattened tables included)")
    func looseFixtureParagraphs() throws {
        let reference = try ChapterReference.load()
        for name in reference.xhtml.keys.sorted() {
            let document = try #require(reference.xhtml[name])
            let chapter = try ReferenceCase(epub: nil, document: document).chapter()
            let paths = Set(chapter.blocks.map(\.elementPath).filter { T.lastStep(of: $0).hasPrefix("p[") })
            #expect(paths.count == document.nonEmptyParagraphCount, "\(name)")
            for sample in document.samples {
                let block = try #require(chapter.block(atElementPath: sample.path), "\(name) \(sample.path)")
                #expect(T.normalizedWhitespace(block.text) == sample.text)
            }
            #expect(Set(chapter.anchorOffsets.keys) == Set(document.ids), "\(name)")
        }
    }

    /// Positions and highlights saved before tables were tables (each row a paragraph of its
    /// cells) sit at offsets that now point earlier in the chapter. They re-anchor through their
    /// CREngine pointers (`Chapter.reanchoredOffset` / `reanchoredRange`, run on open).
    @Test("a position and a highlight saved after Pride's list of illustrations re-anchor", arguments: [false, true])
    func prideReanchors(stylesheets: Bool) throws {
        let path = "OEBPS/1306980130634175271_1342-h-0.htm.html"
        let reference = try ChapterReference.load()
        let spine = try #require(reference.epubs["pride-epub2.epub"]?.documents.first { $0.path == path }).spineIndex
        let chapter = try TextTesting.convert(path, in: "pride-epub2.epub", stylesheets: stylesheets)
        let tables = chapter.blocks.compactMap { block in Self.table(block).map { (block, $0) } }
        #expect(tables.map { $0.1.rows.count } == [2, 102])

        // The old converter's text for a table: one paragraph per row with any text, its non-empty
        // cells joined by " \u{2003} ". What each table took then, less what it takes now:
        func oldLength(_ table: TableContent) -> Int {
            table.rows.map { row -> Int in
                let cells = row.cells.map(\.text).filter { !$0.isEmpty }
                return cells.isEmpty ? 0 : cells.joined(separator: " \u{2003} ").utf16.count + 1
            }.reduce(0, +)
        }
        let shrink = tables.map { oldLength($0.1) - ($0.0.textLength + 1) }
        // The review's probe of the converter before and after: spine item 1 is 3,203 shorter.
        #expect(shrink.reduce(0, +) == 3203)

        // A paragraph after both tables, with the position five characters into it.
        let illustrations = tables[1].0
        let paragraph = try #require(chapter.blocks.first { $0.textOffset > illustrations.textOffset && $0.kind == .paragraph && $0.textLength > 40 })
        let oldOffset = paragraph.textOffset + shrink.reduce(0, +) + 5
        let pointer = XPointer(spineIndex: spine, elementPath: paragraph.elementPath, textNodeIndex: 1, characterOffset: 5).serialized
        #expect(chapter.reanchoredOffset(oldOffset, pointer: pointer, spineIndex: spine) == paragraph.textOffset + 5)

        // A highlight of 20 characters there: its old range no longer holds the quote; the
        // pointers lead back to it.
        let quoted = (paragraph.text as NSString).substring(with: NSRange(location: 5, length: 20))
        #expect(chapter.text(in: oldOffset ..< oldOffset + 20) != quoted)
        let end = XPointer(spineIndex: spine, elementPath: paragraph.elementPath, textNodeIndex: 1, characterOffset: 25).serialized
        #expect(chapter.reanchoredRange(oldOffset ..< oldOffset + 20, text: quoted, startPointer: pointer, endPointer: end)
            == paragraph.textOffset + 5 ..< paragraph.textOffset + 25)

        // A position inside the list (the old pointer named a row's text) lands on that row.
        let table = tables[1].1
        let row = 40
        let rowPointer = XPointer(spineIndex: spine, elementPath: table.rows[row].elementPath, textNodeIndex: 1, characterOffset: 3).serialized
        #expect(chapter.reanchoredOffset(0, pointer: rowPointer, spineIndex: spine) == illustrations.textOffset + table.offset(ofRow: row))
        // And the position written now for that row is the row's own pointer.
        #expect(chapter.pointer(at: illustrations.textOffset + table.offset(ofRow: row), spineIndex: spine).elementPath == table.rows[row].elementPath)
    }

    @Test("table cells receive the stylesheet cascade like any other element")
    func cellsGetTheCascade() throws {
        let chapter = T.convert("""
            <table><tr><th>Town</th><th>People</th></tr><tr><td class="name">Ashby</td><td class="n">1,204</td></tr>\
            <tr class="gone"><td>Hidden</td><td>row</td></tr><tr><td>Bramley <span class="sc">mill</span></td><td class="n">88</td></tr></table>
            """, head: """
            <style>td.name { font-style: italic } .n { text-align: right } tr.gone { display: none }
            th { font-weight: normal } .sc { font-variant: small-caps }</style>
            """)
        let table = try #require(Self.table(chapter.blocks[0]))
        // The hidden row is gone; the others carry the cascade's styles and alignment.
        #expect(table.rows.map { $0.cells.map(\.text) } == [["Town", "People"], ["Ashby", "1,204"], ["Bramley mill", "88"]])
        #expect(table.rows[1].cells[0].runs == [T.run("Ashby", .italic)])
        #expect(table.rows[1].cells[1].alignment == .trailing)
        #expect(table.rows[2].cells[1].alignment == .trailing)
        #expect(table.rows[2].cells[0].runs == [T.run("Bramley "), T.run("mill", .smallCaps)])
        // `th { font-weight: normal }`: the header flag stays (it is structure), no bold run style.
        #expect(table.rows[0].cells.map(\.isHeader) == [true, true])
        #expect(table.rows[0].cells[0].runs == [T.run("Town")])
    }

    @Test("rows read as text: cells joined, for copy, highlights and notes")
    func rowsAsText() throws {
        let chapter = try Self.fixture()
        let block = chapter.blocks[2]
        let table = try #require(Self.table(block))
        #expect(table.plainText(ofRow: 1) == "Ashby · 1,204 · The old market town")
        #expect(table.plainText(ofRow: 2) == "Bramley · Not counted")
        #expect(table.plainText(atOffset: 6) == "Table 1. The census of 1901")
        // A selection over two rows reads as those rows; one running into the next paragraph
        // keeps the paragraph's text after them.
        let start = block.textOffset + 2
        #expect(chapter.displayText(in: start ..< start + 3) == "Ashby · 1,204 · The old market town\nBramley · Not counted")
        let next = chapter.blocks[3]
        #expect(chapter.displayText(in: block.textOffset + 4 ..< next.textOffset + 5)
            == "Bramley · Not counted\nTable 1. The census of 1901\nAfter")
        // Outside tables it is the plain text.
        #expect(chapter.displayText(in: next.textOffset ..< next.textOffset + 9) == "After the")
    }

    // MARK: Cases

    struct ReferenceCase: Sendable, CustomTestStringConvertible {
        var epub: String?
        var document: ChapterReference.Document
        var testDescription: String { "\(epub ?? "Fixtures") \(document.path)" }

        func chapter(stylesheets: Bool = false) throws -> Chapter {
            if let epub { return try TextTesting.convert(document.path, in: epub, stylesheets: stylesheets) }
            let url = try #require(Bundle.module.url(forResource: (document.path as NSString).deletingPathExtension,
                                                     withExtension: "xhtml", subdirectory: "Fixtures"))
            return XHTMLConverter().convert(try Data(contentsOf: url))
        }
    }

    static func referenceCases() -> [ReferenceCase] {
        guard let reference = try? ChapterReference.load() else { return [] }
        return ChapterReference.cases.map { ReferenceCase(epub: $0.epub, document: $0.document) }
            + reference.xhtml.keys.sorted().compactMap { name in reference.xhtml[name].map { ReferenceCase(epub: nil, document: $0) } }
    }
}
