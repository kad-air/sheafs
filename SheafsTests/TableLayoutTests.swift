import Testing
import Foundation
import UIKit
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// Tables are typeset as one attachment per row (and one for the caption), each one character of
/// the block's text, drawn by `TableLayout`. These tests render real pages: the attachments must
/// draw ink, fit the page, page like lines, and keep their links tappable.
@MainActor
struct TableLayoutTests {
    static let pageSize = LinkStyleTests.pageSize

    static let census = """
    <p>The census of 1901 counted the market towns of the valley.</p>
    <table><caption>Table 1. The <i>census</i> of 1901</caption>
    <thead><tr><th>Town</th><th>People</th><th>Notes</th></tr></thead>
    <tbody><tr><td>Ashby</td><td>1,204</td><td>The <em>old</em> market town</td></tr>
    <tr><td>Bramley</td><td></td><td>Not counted</td></tr></tbody></table>
    <p>After the census the valley emptied.</p>
    """

    static func chapter(_ body: String) -> Chapter {
        XHTMLConverter().convert(Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\(body)</body></html>
        """.utf8))
    }

    static func typeset(_ chapter: Chapter, size: CGSize = pageSize) -> NSAttributedString {
        Typesetter.attributedString(for: chapter, style: ReaderEngineTests.style, images: ChapterImages(), pageSize: size)
    }

    /// Every table row attachment in a typeset string, with its character index.
    static func rows(in string: NSAttributedString) -> [(index: Int, attachment: TableRowAttachment)] {
        var result: [(Int, TableRowAttachment)] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let row = value as? TableRowAttachment { result.append((range.location, row)) }
        }
        return result
    }

    static func ink(_ pixels: [UInt8], palette: ReaderPalette = .paper) -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        palette.background.getRed(&r, green: &g, blue: &b, alpha: &a)
        let background = [r, g, b].map { Int($0 * 255) }
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let distance = abs(Int(pixels[i]) - background[0]) + abs(Int(pixels[i + 1]) - background[1]) + abs(Int(pixels[i + 2]) - background[2])
            if distance > 60 { count += 1 }
        }
        return count
    }

    @Test func tableTypesetsAsOneAttachmentPerRowAndKeepsTheOffsets() throws {
        let chapter = Self.chapter(Self.census)
        let string = Self.typeset(chapter)
        #expect(string.length == chapter.textLength)
        let block = try #require(chapter.blocks.first { if case .table = $0.kind { true } else { false } })
        #expect(block.text == "\u{FFFC}\u{2028}\u{FFFC}\u{2028}\u{FFFC}\u{2028}\u{FFFC}")
        #expect((string.string as NSString).substring(with: NSRange(location: block.textOffset, length: block.textLength)) == block.text)
        let rows = Self.rows(in: string)
        // Three rows and the caption, at the objects' offsets.
        #expect(rows.map { $0.index } == [0, 2, 4, 6].map { block.textOffset + $0 })
        #expect(rows.map { $0.attachment.part } == [.row(0), .row(1), .row(2), .caption])
        for (_, row) in rows {
            #expect(row.bounds.width <= Self.pageSize.width)
            #expect(row.bounds.width > 100)
            #expect(row.bounds.height > 10 && row.bounds.height < Self.pageSize.height)
        }
        // The text after the table starts where the chapter offsets say.
        let after = chapter.blocks[block.id + 1]
        #expect((string.string as NSString).substring(with: NSRange(location: after.textOffset, length: after.textLength)) == after.text)
    }

    @Test func tableDrawsInkInsideThePage() throws {
        let withTable = LinkStyleTests.page(Self.census)
        let withoutTable = LinkStyleTests.page("""
        <p>The census of 1901 counted the market towns of the valley.</p><p>After the census the valley emptied.</p>
        """)
        let tableInk = Self.ink(LinkStyleTests.pixels(of: withTable.view))
        let textInk = Self.ink(LinkStyleTests.pixels(of: withoutTable.view))
        // Three rows of three cells, rules and a caption draw far more than the two paragraphs alone.
        #expect(tableInk > textInk + 1500, "table \(tableInk), text alone \(textInk)")
        #expect(withTable.chapter.pageCount == 1)

        // The ink is inside the rows' frames: render one row on its own and look at it.
        let string = withTable.chapter.textStorage
        let header = try #require(Self.rows(in: string).first?.attachment)
        let image = header.layout.image(of: .row(0), scale: 2)
        #expect(image.size.width <= Self.pageSize.width)
        let pixels = Self.pixels(of: image)
        #expect(Self.ink(pixels, palette: ReaderPalette(background: .white)) > 200)
    }

    /// The census of eight towns from the visual check: wider than a page, it fits once scaled, so
    /// no word may break (scaling once by the measured ratio left 93 % of such tables squeezed:
    /// type does not narrow in proportion).
    static let towns = """
    <table><tr><th>Year</th><th>Ashby</th><th>Bramley</th><th>Coldharbour</th><th>Dunmere</th><th>Eastwick</th>\
    <th>Fallow</th><th>Grange</th></tr><tr><td>1881</td><td>1,102</td><td>644</td><td>402</td><td>1,980</td>\
    <td>212</td><td>77</td><td>1,450</td></tr></table>
    """

    @Test func wideTableScalesDownWithoutBreakingWords() throws {
        var scaled = 0
        for width in stride(from: 300, through: 640, by: 11) {
            let size = CGSize(width: CGFloat(width), height: 600)
            let layout = try #require(Self.rows(in: Self.typeset(Self.chapter(Self.towns), size: size)).first?.attachment.layout)
            #expect(layout.width <= size.width)
            if layout.scale < 1 { scaled += 1 }
            // Every column holds its longest word at the final scale, unless even the smallest
            // scale could not make the table fit.
            if layout.minimumColumnWidths.reduce(0, +) <= size.width {
                for (column, minimum) in layout.minimumColumnWidths.enumerated() {
                    #expect(layout.columnWidths[column] >= minimum, "page \(width), column \(column), scale \(layout.scale)")
                }
            } else {
                #expect(layout.scale == TableLayout.minimumScale, "page \(width): squeezed above the smallest scale")
                // Squeezed: only the widest columns are cut, all to one level; the others ("Year",
                // "1881") keep their whole words (a proportional squeeze broke "Yea/r").
                let cut = zip(layout.columnWidths, layout.minimumColumnWidths).filter { $0 < $1 }.map(\.0)
                let level = cut.max() ?? 0
                #expect(cut.allSatisfy { abs($0 - level) <= 1 }, "page \(width): \(layout.columnWidths)")
                for (column, minimum) in layout.minimumColumnWidths.enumerated() where layout.columnWidths[column] >= minimum {
                    #expect(minimum <= level + 1, "page \(width), column \(column) kept although wider than the level")
                }
            }
        }
        #expect(scaled > 10)
        // The spread's page width on the Duo (≈ 430 pt): fits scaled, no squeeze.
        let duo = try #require(Self.rows(in: Self.typeset(Self.chapter(Self.towns), size: CGSize(width: 430, height: 600))).first?.attachment.layout)
        #expect(duo.scale < 1 && duo.scale > TableLayout.minimumScale)
        #expect(zip(duo.columnWidths, duo.minimumColumnWidths).allSatisfy { $0 >= $1 })
    }

    @Test func levellingCutsOnlyTheWidestColumns() {
        #expect(TableLayout.levelled([40, 60, 120, 130], toFit: 300) == [40, 60, 100, 100])
        #expect(TableLayout.levelled([50, 50, 50], toFit: 120) == [40, 40, 40])
        #expect(TableLayout.levelled([10, 200], toFit: 100) == [10, 90])
    }

    @Test func wideTableScalesDownToThePage() throws {
        let cells = (1...8).map { "<td>Extraordinarily\($0)</td>" }.joined()
        let chapter = Self.chapter("<table><tr>\(cells)</tr><tr>\(cells)</tr></table>")
        let rows = Self.rows(in: Self.typeset(chapter))
        #expect(rows.count == 2)
        let layout = try #require(rows.first?.attachment.layout)
        #expect(layout.scale < 1)
        #expect(layout.width <= Self.pageSize.width)
        #expect(layout.columnWidths.count == 8)
        #expect(abs(layout.columnWidths.reduce(0, +) - layout.width) < 1)
        for (_, row) in rows { #expect(row.bounds.width <= Self.pageSize.width) }
    }

    @Test func columnsNeverGoBelowTheirLongestWord() throws {
        // A short bold header beside a long column: sharing out the room once floored "No." below its
        // own width and it wrapped as "No" / ".".
        let rows = (1...3).map { "<tr><td>\($0)</td><td>Plate \($0): a view of the valley from the north road</td><td>\($0 * 7)</td></tr>" }
        let chapter = Self.chapter("<table><thead><tr><th>No.</th><th>Plate</th><th>Page</th></tr></thead>\(rows.joined())</table>")
        var scaledWidths = 0
        for width in stride(from: 100, through: 460, by: 7) {
            let rowAttachments = Self.rows(in: Self.typeset(chapter, size: CGSize(width: CGFloat(width), height: 500)))
            let layout = try #require(rowAttachments.first?.attachment.layout)
            if layout.scale < 1 { scaledWidths += 1 }
            guard layout.minimumColumnWidths.reduce(0, +) <= CGFloat(width) else { continue }
            for (column, minimum) in layout.minimumColumnWidths.enumerated() {
                #expect(layout.columnWidths[column] >= minimum, "page \(width), column \(column)")
            }
            // Every header cell ("No.", "Plate", "Page") sets on one line in its column, at any scale.
            for (column, cell) in layout.rows[0].enumerated() {
                let free = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
                let oneLine = cell.string.boundingRect(with: free, options: options, context: nil).height
                let set = cell.string.boundingRect(with: CGSize(width: cell.frame.width - 2 * layout.padding.width, height: .greatestFiniteMagnitude),
                                                   options: options, context: nil).height
                #expect(set <= oneLine + 0.5, "page \(width), scale \(layout.scale), header \(column): \(set) vs one line \(oneLine)")
            }
        }
        #expect(scaledWidths > 3)
    }

    @Test func narrowTableKeepsItsNaturalWidth() throws {
        let rows = Self.rows(in: Self.typeset(Self.chapter("<table><tr><td>a</td><td>b</td></tr></table>")))
        let layout = try #require(rows.first?.attachment.layout)
        #expect(layout.scale == 1)
        #expect(layout.width < Self.pageSize.width / 2)
    }

    @Test func tallTablePagesBetweenRows() throws {
        let body = (1...80).map { "<tr><td>Row \($0)</td><td>Some words in the second column of row \($0)</td></tr>" }.joined()
        let chapter = Self.chapter("<p>Before.</p><table>\(body)</table><p>After.</p>")
        let string = Self.typeset(chapter)
        #expect(string.length == chapter.textLength)
        let paginated = PaginatedChapter(spineIndex: 0, attributedString: string, pageSize: Self.pageSize)
        #expect(paginated.pageCount > 3)
        var cursor = 0
        for page in 0 ..< paginated.pageCount {
            let range = paginated.range(ofPage: page)
            #expect(range.location == cursor)
            cursor = NSMaxRange(range)
        }
        #expect(cursor == string.length)
        // No row is lost at a page break: every row attachment is on exactly one page.
        let rows = Self.rows(in: string)
        #expect(rows.count == 80)
        for (index, _) in rows {
            let page = paginated.pageIndex(containing: index)
            #expect(paginated.attachmentFrame(at: index, page: page) != nil, "row at \(index)")
        }
        // An anchor at a row (a saved position, a sync) starts a page there.
        let block = try #require(chapter.blocks.first { if case .table = $0.kind { true } else { false } })
        let anchor = block.textOffset + 2 * 40
        let anchored = PaginatedChapter(spineIndex: 0, attributedString: string, pageSize: Self.pageSize, anchor: anchor)
        #expect(anchored.pageRanges.contains { $0.location == anchor })
    }

    /// A row taller than a page is set smaller until it fits, and no row (the first one, with the
    /// spacing before the table, included) runs past the page into the folio.
    @Test func rowsNeverExceedThePage() throws {
        let sentence = "The surveyor walked the boundary again and wrote down every stone he found. "
        let tall = TableContent.Cell(runs: [InlineRun(text: String(repeating: sentence, count: 7))])
        let table = TableContent(rows: (1...4).map { r in
            TableContent.Row(cells: [TableContent.Cell(runs: [InlineRun(text: "Row \(r)")]), tall],
                             elementPath: "/body/table[1]/tr[\(r)]")
        })
        let chapter = Chapter(blocks: [
            Block(id: 0, kind: .paragraph, runs: [InlineRun(text: "Before the table.")], elementPath: "/body/p[1]", textOffset: 0),
            Block(id: 1, kind: .table(table), runs: [InlineRun(text: table.objectText)], elementPath: "/body/table[1]", textOffset: 18),
        ], textLength: 18 + table.objectText.utf16.count + 1, anchorOffsets: [:])
        let size = CGSize(width: 300, height: 360)
        let string = Self.typeset(chapter, size: size)
        #expect(string.length == chapter.textLength)
        let layout = try #require(Self.rows(in: string).first?.attachment.layout)
        let natural = TableLayout(table: table, style: ReaderEngineTests.style, pageSize: CGSize(width: 300, height: 10_000))
        #expect(natural.size(of: .row(0)).height > size.height, "the test needs a row taller than the page")
        for row in 0 ..< 4 { #expect(layout.size(of: .row(row)).height < size.height - 19) }
        // Set smaller, not cut: the text still fits its row.
        let cell = layout.rows[0][1]
        let needed = cell.string.boundingRect(with: CGSize(width: cell.frame.width - 2 * layout.padding.width, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        #expect(needed + 2 * layout.padding.height <= cell.frame.height + 0.5)
        // On the pages: every row lies inside its page.
        let paginated = PaginatedChapter(spineIndex: 0, attributedString: string, pageSize: size)
        for (index, _) in Self.rows(in: string) {
            let frame = try #require(paginated.attachmentFrame(at: index, page: paginated.pageIndex(containing: index)))
            #expect(frame.minY >= 0 && frame.maxY <= size.height, "row at \(index): \(frame)")
        }
    }

    @Test func rowsReadAsTextForHighlightsExportAndVoiceOver() throws {
        let chapter = Self.chapter(Self.census)
        let block = try #require(chapter.blocks.first { if case .table = $0.kind { true } else { false } })
        // A highlight over the first body row quotes the row, and the export shows it.
        let quoted = chapter.displayText(in: block.textOffset + 2 ..< block.textOffset + 3)
        #expect(quoted == "Ashby · 1,204 · The old market town")
        let markdown = AnnotationExport.markdown(title: "Three Towns", author: nil,
                                                 annotations: [(chapter: "Census", text: quoted, note: "")])
        #expect(markdown.contains("\n> Ashby · 1,204 · The old market town"))
        #expect(!markdown.contains("\u{FFFC}"))
        // VoiceOver reads the rows and the caption, not object characters.
        let page = LinkStyleTests.page(Self.census)
        let label = try #require(page.view.accessibilityLabel)
        #expect(label.contains("Town · People · Notes"))
        #expect(label.contains("Bramley · Not counted"))
        #expect(label.contains("Table 1. The census of 1901"))
        #expect(!label.contains("\u{FFFC}"))
    }

    @Test func linksInTableCellsAreTappable() throws {
        // Alice's contents page is a table of chapter links.
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let epub = try EPUBBook(url: url)
        let chapter = XHTMLConverter().convert(try epub.data(for: epub.spine[1].item))
        let size = CGSize(width: 360, height: 640)
        let string = Self.typeset(chapter, size: size)
        let paginated = PaginatedChapter(spineIndex: 1, attributedString: string, pageSize: size)
        let first = try #require(Self.rows(in: string).first)
        let page = paginated.pageIndex(containing: first.index)
        let frame = try #require(paginated.attachmentFrame(at: first.index, page: page))
        let view = PageView(frame: CGRect(origin: .zero, size: size))
        view.chapter = paginated
        view.page = page
        let layout = first.attachment.layout
        // The first cell ("CHAPTER I.") links to chapter 1; the second cell has no link.
        let inFirstCell = CGPoint(x: frame.minX + layout.columnWidths[0] / 2, y: frame.midY)
        #expect(view.tableLink(at: inFirstCell)?.hasSuffix("#chap01") == true)
        let inSecondCell = CGPoint(x: frame.minX + layout.columnWidths[0] + layout.columnWidths[1] / 2, y: frame.midY)
        #expect(view.tableLink(at: inSecondCell) == nil)
    }

    /// A 1,000 × 4 table (numbers and a long text column) laid out at a comfortable width and at a
    /// width that forces scaling. Prints the time (`[table-timing]` in the test log); the bound is
    /// loose, for a shared simulator: it catches a quadratic slip, not a few milliseconds.
    @Test func largeTableLaysOutQuickly() throws {
        let rows = (0 ..< 1000).map { r in
            TableContent.Row(cells: (0 ..< 4).map { c in
                TableContent.Cell(runs: [InlineRun(text: c == 1 ? "Plate \(r): a view of the valley from the north road"
                                                              : "\(r * (c + 3))")])
            }, elementPath: "/body/table[1]/tr[\(r + 1)]")
        }
        let table = TableContent(rows: rows)
        for width in [320.0, 150.0] {
            let start = ContinuousClock.now
            let layout = TableLayout(table: table, style: ReaderEngineTests.style, pageSize: CGSize(width: width, height: 500))
            let elapsed = ContinuousClock.now - start
            print("[table-timing] 1000x4 at width \(Int(width)): \(elapsed), scale \(layout.scale)")
            #expect(layout.rows.count == 1000)
            #expect(elapsed < .seconds(4))
        }
    }

    /// An image's pixels, RGBA, at its own scale.
    static func pixels(of image: UIImage) -> [UInt8] {
        guard let cgImage = image.cgImage else { return [] }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}

private extension ReaderPalette {
    init(background: UIColor) {
        self = .paper
        self.background = background
    }
}
