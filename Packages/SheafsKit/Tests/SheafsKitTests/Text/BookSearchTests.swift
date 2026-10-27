import Foundation
import Testing
@testable import SheafsKit

/// Find-in-book: hit offsets are UTF-16 chapter offsets (the position/highlight contract) and
/// resolve to the words searched for; counts agree with an independent count of the source.
@Suite("Book search")
struct BookSearchTests {
    private static func index(_ epub: String) throws -> BookSearchIndex {
        let book = try EPUBBook(url: TextFixture.epubURL(epub))
        let converter = XHTMLConverter()
        return BookSearchIndex(chapters: try book.spine.map { converter.convert(try book.data(for: $0.item)) })
    }

    /// The text a hit covers, read straight out of the chapter's plain text by UTF-16 offset,
    /// exactly as the typeset `NSAttributedString` is indexed.
    private static func text(of hit: SearchHit, in index: BookSearchIndex) -> String {
        let plain = index.chapters[hit.spineIndex].plainText as NSString
        return plain.substring(with: NSRange(location: hit.range.lowerBound, length: hit.range.count))
    }

    @Test("every hit for “rabbit” in Alice resolves to the word, chapter counts as Python counts them")
    func aliceRabbit() throws {
        let index = try Self.index("alice-epub3.epub")
        let result = try #require(index.search("Rabbit"))
        // Counted by Python's html.parser over each spine document's raw XHTML (body text,
        // whitespace collapsed, casefolded, str.count): an independent second source.
        let python = [1: 2, 2: 9, 3: 4, 5: 16, 9: 6, 11: 1, 12: 8, 13: 8]
        #expect(result.countsBySpine == python)
        #expect(result.totalCount == 54)
        #expect(result.hits.count == 54)
        for hit in result.hits {
            #expect(Self.text(of: hit, in: index).lowercased() == "rabbit", "\(hit)")
        }
        // Book order.
        #expect(result.hits == result.hits.sorted { ($0.spineIndex, $0.textOffset) < ($1.spineIndex, $1.textOffset) })
        // And the same offsets a plain case-insensitive NSString search finds, chapter by chapter.
        for (spine, chapter) in index.chapters.enumerated() {
            let plain = chapter.plainText as NSString
            var found: [Range<Int>] = []
            var from = 0
            while true {
                let range = plain.range(of: "rabbit", options: .caseInsensitive, range: NSRange(location: from, length: plain.length - from))
                guard range.location != NSNotFound else { break }
                found.append(range.location ..< NSMaxRange(range))
                from = NSMaxRange(range)
            }
            #expect(result.hits.filter { $0.spineIndex == spine }.map(\.range) == found, "spine \(spine)")
        }
    }

    @Test("Pride and Prejudice: “darcy” per chapter as Python counts it; straight quotes find curly ones")
    func prideDarcy() throws {
        let index = try Self.index("pride-epub2.epub")
        let result = try #require(index.search("darcy", limit: 10_000))
        let python = [1: 13, 2: 20, 3: 49, 4: 20, 5: 66, 6: 8, 7: 18, 8: 25, 9: 39, 10: 27, 11: 30, 12: 38,
                      13: 6, 14: 23, 15: 19, 16: 31]
        #expect(result.countsBySpine == python)
        for hit in result.hits { #expect(Self.text(of: hit, in: index).lowercased() == "darcy") }

        let straight = try #require(index.search("Mr. Darcy's"))
        let curly = try #require(index.search("mr. darcy’s"))
        #expect(straight.totalCount > 0)
        #expect(straight.hits == curly.hits)
        for hit in straight.hits {
            let text = Self.text(of: hit, in: index)
            #expect(text.lowercased() == "mr. darcy’s" || text.lowercased() == "mr. darcy's", "\(text)")
        }
    }

    @Test("offsets are UTF-16: an emoji before, a combining accent inside, a non-BMP letter")
    func utf16Offsets() throws {
        let chapter = TextTesting.convert("<p>😀 Café au lait</p><p>naïve cafe\u{301} 𝔘nicode Straße</p>")
        #expect(chapter.blocks.map(\.text) == ["😀 Café au lait", "naïve cafe\u{301} 𝔘nicode Straße"])
        // "😀" is two UTF-16 units, so "Café" starts at 3; the second block starts after 15 + "\n".
        #expect(chapter.blocks[1].textOffset == 16)
        let index = BookSearchIndex(chapters: [chapter])

        let cafe = try #require(index.search("CAFE"))
        #expect(cafe.hits.map(\.range) == [3 ..< 7, 22 ..< 27]) // the second includes U+0301
        #expect(cafe.hits.map { Self.text(of: $0, in: index) } == ["Café", "cafe\u{301}"])
        #expect(try #require(index.search("café")).hits == cafe.hits)
        #expect(try #require(index.search("cafe\u{301}")).hits == cafe.hits)

        // "𝔘" (U+1D518, a surrogate pair) folds to "u" under compatibility mapping.
        let unicode = try #require(index.search("unicode"))
        #expect(unicode.hits.map(\.range) == [28 ..< 36])
        #expect(Self.text(of: unicode.hits[0], in: index) == "𝔘nicode")

        #expect(try #require(index.search("naive")).hits.map(\.range) == [16 ..< 21])
        #expect(try #require(index.search("au lait")).hits.map(\.range) == [8 ..< 15])

        let strasse = try #require(index.search("strasse"))
        #expect(strasse.hits.map { Self.text(of: $0, in: index) } == ["Straße"])
        // One character folded to two units is one hit, not two.
        #expect(try #require(index.search("s")).hits.filter { Self.text(of: $0, in: index) == "ß" }.count == 1)
    }

    @Test("soft hyphens and zero-width spaces are skipped; whitespace runs match any run; no match spans blocks")
    func invisiblesAndWhitespace() throws {
        let chapter = TextTesting.convert("<p>won&#173;der&#8203;land</p><p>Mad&#160;  Tea-Party</p><p>the end</p><p>start here</p>")
        let index = BookSearchIndex(chapters: [chapter])
        let wonder = try #require(index.search("wonderland"))
        #expect(wonder.hits.map(\.range) == [0 ..< 12])
        #expect(try #require(index.search("  mad   tea ")).hits.count == 1)
        #expect(try #require(index.search("end start")).totalCount == 0)
        #expect(try #require(index.search("end\nstart")).totalCount == 0)
        #expect(index.search("   ") == nil)
        #expect(index.search("") == nil)
        #expect(index.search("\u{00AD}") == nil)
    }

    @Test("the limit caps the hits listed, not the counts; cancelling gives nothing")
    func limitAndCancel() throws {
        let index = try Self.index("alice-epub3.epub")
        let all = try #require(index.search("the", limit: .max))
        let some = try #require(index.search("the", limit: 10))
        #expect(all.totalCount > 1000)
        #expect(some.hits == Array(all.hits.prefix(10)))
        #expect(some.totalCount == all.totalCount)
        #expect(some.countsBySpine == all.countsBySpine)
        #expect(some.isTruncated && !all.isTruncated)
        #expect(all.countsBySpine.values.reduce(0, +) == all.totalCount)
        #expect(index.search("the", isCancelled: { true }) == nil)
        for spine in index.chapters.indices {
            #expect(index.hits(of: "the", inSpine: spine) == all.hits.filter { $0.spineIndex == spine })
        }
        #expect(index.hits(of: "the", inSpine: 99).isEmpty)
    }

    @Test("snippets: the match with whole words either side, cut at spaces, never inside a character")
    func snippets() throws {
        let long = "One two three four five six seven eight nine ten eleven twelve White Rabbit with pink eyes ran close by her and"
            + " there was nothing so very remarkable in that nor did Alice think it so very much out of the way 😀😀😀"
        let chapter = TextTesting.convert("<p>Short Rabbit.</p><p>\(long)</p>")
        let index = BookSearchIndex(chapters: [chapter])
        let hits = try #require(index.search("rabbit")).hits
        #expect(hits.count == 2)

        let short = index.snippet(for: hits[0])
        #expect(short == SearchSnippet(before: "Short ", match: "Rabbit", after: ".", isCutBefore: false, isCutAfter: false))
        #expect(short.text == "Short Rabbit.")

        let cut = index.snippet(for: hits[1], context: 20)
        #expect(cut.match == "Rabbit")
        #expect(cut.isCutBefore && cut.isCutAfter)
        #expect(cut.before == "eleven twelve White ")
        #expect(cut.after == " with pink eyes ran close by")
        #expect(cut.text == "…eleven twelve White Rabbit with pink eyes ran close by…")

        // A cut that lands inside a surrogate pair moves to a character boundary.
        let emoji = BookSearchIndex.snippet(for: 0 ..< 3, in: TextTesting.convert("<p>abc😀😀😀😀</p>"), context: 5)
        #expect(emoji.match == "abc")
        #expect(emoji.after == "😀😀😀") // 3 + 7 = 10 is inside the fourth emoji; back to 9
        #expect(emoji.isCutAfter)
    }
}
