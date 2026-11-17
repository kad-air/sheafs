import Foundation
import Testing
@testable import SheafsKit

/// Reference pages (the folio and "N of M"): the page list parsed like Python parses it, each
/// print-page marker resolved to the place where Python finds its text, the fallbacks to synthetic
/// pages, and the synthetic pages' boundaries.
@Suite("Reference pages")
struct ReferencePagesTests {
    /// Every chapter converted as the app converts it (`BookSession.load`): with the book's stylesheets.
    static func chapters(of book: EPUBBook) throws -> [Chapter] {
        let converter = XHTMLConverter()
        let stylesheets = StylesheetLibrary(book: book)
        return try book.spine.map { converter.convert(try book.data(for: $0.item), documentPath: $0.item.path, stylesheets: stylesheets) }
    }

    /// The text from `offset` on as a reader sees it (`Chapter.displayText`: a table row reads as
    /// its cells), pictures (U+FFFC) dropped, whitespace runs one space: the Python reference's folding.
    static func readerText(_ chapter: Chapter, from offset: Int) -> String {
        chapter.displayText(in: min(offset, chapter.textLength) ..< chapter.textLength)
            .replacingOccurrences(of: "\u{FFFC}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: The page list against Python

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func pageListMatchesPython(_ name: String) throws {
        let book = try EPUBBook(url: EPUBTestSupport.epubURL(name))
        let reference = try EPUBTestSupport.reference(name)
        #expect(book.pageList.count == reference.pageList.count)
        for (entry, row) in zip(book.pageList, reference.pageList) {
            #expect(entry.label == row.label)
            #expect(entry.path == row.path)
            #expect(entry.fragment == row.fragment)
        }
    }

    /// Pride and Prejudice (Project Gutenberg, EPUB 2) carries its print edition's 453 pages in the
    /// NCX. Every marker must resolve, in reading order, to where Python's reading of the XHTML says
    /// the page's text begins; the labels lose Gutenberg's braces; M is the last printed page, 476.
    @Test func pridePagesResolveWhereThePrintPagesBegin() throws {
        let book = try EPUBBook(url: EPUBTestSupport.epubURL("pride-epub2"))
        let chapters = try Self.chapters(of: book)
        let reference = try EPUBTestSupport.reference("pride-epub2")
        let pages = ReferencePages(book: book, chapters: chapters)
        #expect(pages.source == .pageList)
        #expect(pages.rejection == nil)
        #expect(pages.pages.count == 453)
        #expect(pages.total == 476)
        #expect(pages.pages.first?.label == "vii")
        #expect(pages.pages.last?.label == "476")
        var checked = 0
        for (page, row) in zip(pages.pages, reference.pageList) {
            #expect(page.label == ReferencePages.cleanLabel(row.label))
            #expect(book.spine[page.spineIndex].item.path == row.path)
            let after = try #require(row.textAfter)
            let text = Self.readerText(chapters[page.spineIndex], from: page.offset)
            if after.isEmpty {
                // The marker ends its document: the page begins with the next file.
                #expect(text.isEmpty, "page \(page.label): \"\(text.prefix(30))\" after a marker that ends its file")
            } else {
                #expect(text.hasPrefix(after), "page \(page.label) begins \"\(text.prefix(30))\", Python says \"\(after)\"")
            }
            checked += 1
        }
        #expect(checked == 453)
        // Text before the first marker (cover, title page, imprint) has no reference page.
        let first = try #require(pages.pages.first)
        #expect(pages.page(spineIndex: 0, offset: 0) == nil)
        #expect(pages.page(spineIndex: first.spineIndex, offset: max(0, first.offset - 1)) == nil || first.offset == 0)
        #expect(pages.page(spineIndex: first.spineIndex, offset: first.offset)?.label == "vii")
        // A chapter with no marker of its own before its text continues the page before.
        let endsItsFile = try #require(pages.pages.first { $0.label == "132" })
        #expect(pages.page(spineIndex: endsItsFile.spineIndex + 1, offset: 0)?.label == "132")
    }

    /// The other fixtures have no page list: synthetic pages, no rejection.
    @Test func booksWithoutAPageListGetSyntheticPages() throws {
        let book = try EPUBBook(url: EPUBTestSupport.epubURL("alice-epub3"))
        let chapters = try Self.chapters(of: book)
        let pages = ReferencePages(book: book, chapters: chapters)
        #expect(book.pageList.isEmpty)
        #expect(pages.source == .synthetic)
        #expect(pages.rejection == nil)
        let expected = chapters.reduce(0) { $0 + max(1, Int((Double($1.textLength) / 1024).rounded(.up))) }
        #expect(pages.total == expected)
        #expect(pages.pages.count == expected)
    }

    // MARK: EPUB 3 navigation document

    private static func epub(nav: String, chapters: [String], ncx: String? = nil) throws -> EPUBBook {
        var manifest = """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            """
        var spine = ""
        var files = [("OEBPS/nav.xhtml", nav)]
        for (index, body) in chapters.enumerated() {
            manifest += "<item id=\"c\(index)\" href=\"Text/c\(index).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(index)\"/>"
            files.append(("OEBPS/Text/c\(index).xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\(body)</body></html>"))
        }
        if let ncx {
            manifest += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
            files.append(("OEBPS/toc.ncx", ncx))
        }
        let opf = """
            <?xml version="1.0" encoding="utf-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
            """
        return try EPUBBook(data: TestZipBuilder.epub(opf: opf, files: files))
    }

    private static func nav(_ links: [(String, String)]) -> String {
        let items = links.map { "<li><a href=\"\($0.1)\">\($0.0)</a></li>" }.joined()
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="toc"><ol><li><a href="Text/c0.xhtml">Front</a></li><li><a href="Text/c1.xhtml">One</a></li></ol></nav>
            <nav epub:type="page-list" hidden=""><ol>\(items)</ol></nav>
            </body></html>
            """
    }

    private static let twoChapters = [
        "<h1>Front</h1><p>Before any page.</p><p><span id=\"pv\" epub:type=\"pagebreak\" title=\"v\"/>Preface text.</p>",
        "<h1 id=\"p1\">One</h1><p>First page text <span id=\"p2\" epub:type=\"pagebreak\"/>second page text.</p>",
    ]

    /// The nav document's page list, roman and arabic labels as given, a target with no fragment
    /// (the file's start), M the highest whole number, nothing before the first marker.
    @Test func navigationDocumentPageList() throws {
        let book = try Self.epub(nav: Self.nav([("v", "Text/c0.xhtml#pv"), ("1", "Text/c1.xhtml"), ("2", "Text/c1.xhtml#p2"), ("xi", "Text/c1.xhtml#p2")]),
                                 chapters: Self.twoChapters)
        #expect(book.pageList.map(\.label) == ["v", "1", "2", "xi"])
        #expect(book.toc.map(\.title) == ["Front", "One"], "the page list must not leak into the contents")
        let chapters = try Self.chapters(of: book)
        let pages = ReferencePages(book: book, chapters: chapters)
        #expect(pages.source == .pageList)
        #expect(pages.total == 2)
        #expect(pages.page(spineIndex: 0, offset: 0) == nil, "front matter before the first marker has no page")
        let preface = try #require(chapters[0].anchorOffsets["pv"])
        #expect(Self.readerText(chapters[0], from: preface).hasPrefix("Preface text."))
        #expect(pages.page(spineIndex: 0, offset: preface)?.label == "v")
        #expect(pages.page(spineIndex: 1, offset: 0)?.label == "1")
        let second = try #require(chapters[1].anchorOffsets["p2"])
        #expect(Self.readerText(chapters[1], from: second).hasPrefix("second page text."))
        #expect(pages.page(spineIndex: 1, offset: second - 1)?.label == "1")
        // Two markers at one place: the later one names the text there.
        #expect(pages.page(spineIndex: 1, offset: second)?.label == "xi")
    }

    /// No page list in the nav document: the NCX's, `value` standing in for a missing label.
    @Test func ncxPageListWhenTheNavHasNone() throws {
        let ncx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap/>
            <pageList><navLabel><text>Pages</text></navLabel>
              <pageTarget value="1" type="normal"><navLabel><text> 1 </text></navLabel><content src="Text/c1.xhtml#p1"/></pageTarget>
              <pageTarget value="2" type="normal"><content src="Text/c1.xhtml#p2"/></pageTarget>
            </pageList></ncx>
            """
        let book = try Self.epub(nav: Self.nav([]), chapters: Self.twoChapters, ncx: ncx)
        #expect(book.pageList == [PageListEntry(label: "1", path: "OEBPS/Text/c1.xhtml", fragment: "p1"),
                                  PageListEntry(label: "2", path: "OEBPS/Text/c1.xhtml", fragment: "p2")])
        let pages = ReferencePages(book: book, chapters: try Self.chapters(of: book))
        #expect(pages.source == .pageList)
        #expect(pages.pages.map(\.label) == ["1", "2"])
    }

    // MARK: Fallbacks

    /// Under 90 % of the entries resolve: synthetic pages, and the rejection says why.
    @Test func aPageListThatMostlyFailsToResolveFallsBack() throws {
        var links = [("1", "Text/c1.xhtml#p1"), ("2", "Text/c1.xhtml#p2")]
        links += (3 ... 10).map { ("\($0)", "Text/c1.xhtml#missing\($0)") }
        let book = try Self.epub(nav: Self.nav(links), chapters: Self.twoChapters)
        let chapters = try Self.chapters(of: book)
        let pages = ReferencePages(book: book, chapters: chapters)
        #expect(pages.source == .synthetic)
        #expect(pages.rejection == .tooFewResolved(resolved: 2, of: 10))
        let synthetic = ReferencePages(chapterLengths: chapters.map(\.textLength))
        #expect(pages.pages == synthetic.pages)
        #expect(pages.total == synthetic.total)
        // 9 of 10 is enough: the one that doesn't resolve is left out.
        let enough = try Self.epub(nav: Self.nav((1 ... 9).map { ("\($0)", "Text/c1.xhtml") } + [("10", "Text/c1.xhtml#missing")]),
                                   chapters: Self.twoChapters)
        let used = ReferencePages(book: enough, chapters: try Self.chapters(of: enough))
        #expect(used.source == .pageList)
        #expect(used.pages.count == 9)
        // One marker is not a page list.
        let single = try Self.epub(nav: Self.nav([("1", "Text/c1.xhtml")]), chapters: Self.twoChapters)
        #expect(ReferencePages(book: single, chapters: try Self.chapters(of: single)).rejection == .tooFewResolved(resolved: 1, of: 1))
    }

    /// A marker before the one listed before it (here a later page pointing back into the front
    /// matter): the list can't be trusted, synthetic pages.
    @Test func aPageListThatGoesBackFallsBack() throws {
        let book = try Self.epub(nav: Self.nav([("1", "Text/c1.xhtml"), ("2", "Text/c1.xhtml#p2"), ("3", "Text/c0.xhtml#pv")]),
                                 chapters: Self.twoChapters)
        let pages = ReferencePages(book: book, chapters: try Self.chapters(of: book))
        #expect(pages.source == .synthetic)
        #expect(pages.rejection == .backwards(index: 2, label: "3"))
    }

    // MARK: Synthetic pages

    /// A page per 1,024 UTF-16 units, each chapter starting a new page, an empty chapter still one
    /// page; numbered 1… through the book; M the count.
    @Test func syntheticBoundaries() {
        let pages = ReferencePages(chapterLengths: [0, 1024, 1025, 3000])
        #expect(pages.source == .synthetic)
        #expect(pages.total == 1 + 1 + 2 + 3)
        func label(_ spine: Int, _ offset: Int) -> String? { pages.page(spineIndex: spine, offset: offset)?.label }
        #expect(label(0, 0) == "1")
        #expect(label(1, 0) == "2")
        #expect(label(1, 1023) == "2")
        #expect(label(2, 0) == "3", "a chapter starts a new page")
        #expect(label(2, 1023) == "3")
        #expect(label(2, 1024) == "4")
        #expect(label(3, 0) == "5")
        #expect(label(3, 2047) == "6")
        #expect(label(3, 2048) == "7")
        #expect(label(3, 2999) == "7")
        #expect(pages.pages.map(\.offset) == [0, 0, 0, 1024, 0, 1024, 2048])
    }

    @Test func labels() {
        #expect(ReferencePages.cleanLabel(" {475} ") == "475")
        #expect(ReferencePages.cleanLabel("[xii]") == "xii")
        #expect(ReferencePages.cleanLabel("(3)") == "3")
        #expect(ReferencePages.cleanLabel("xiv") == "xiv")
        #expect(ReferencePages.cleanLabel("{}") == "{}")
        #expect(ReferencePages.cleanLabel("{1}–{2}") == "{1}–{2}")
        #expect(ReferencePages.cleanLabel("Page 12") == "Page 12")
    }
}
