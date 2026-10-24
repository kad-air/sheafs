import Foundation
import SheafsKit
import Testing

/// Offset bookkeeping over every XHTML/HTML document of the three fixture books.
@Suite("Chapter offsets")
struct ChapterOffsetsTests {
    static let epubs = ["alice-epub3.epub", "pride-epub2.epub", "hub-fixture.epub"]

    @Test("offsets are consistent in every fixture document", arguments: epubs)
    func offsetInvariants(epub: String) throws {
        let paths = try TextFixture.documentPaths(in: epub)
        #expect(!paths.isEmpty)
        for path in paths {
            let chapter = XHTMLConverter().convert(try TextFixture.entry(path, in: epub))
            checkInvariants(chapter, "\(epub) \(path)")
        }
    }

    /// `expectTrimmed` is false for markup that may contain `<pre>`, whose text is verbatim.
    private func checkInvariants(_ chapter: Chapter, _ label: String, expectTrimmed: Bool = true) {
        // Block ids and strictly increasing offsets, each exactly one separator after the last.
        var expectedOffset = 0
        for (index, block) in chapter.blocks.enumerated() {
            #expect(block.id == index, "\(label) block \(index) id")
            #expect(block.textOffset == expectedOffset, "\(label) block \(index) offset")
            if index > 0 { #expect(block.textOffset > chapter.blocks[index - 1].textOffset) }
            expectedOffset = block.textOffset + block.textLength + 1
            #expect(!block.text.contains("\n"), "\(label) block \(index) contains a newline")
            switch block.kind {
            case .image, .horizontalRule:
                #expect(block.text == "\u{FFFC}")
            case .preformatted:
                break
            default:
                #expect(!block.text.isEmpty, "\(label) block \(index) is empty")
                if expectTrimmed {
                    #expect(!block.text.hasPrefix(" ") && !block.text.hasSuffix(" "), "\(label) block \(index) untrimmed")
                }
            }
        }
        #expect(chapter.textLength == expectedOffset, "\(label) textLength")
        #expect(chapter.plainText.utf16.count == chapter.textLength, "\(label) plainText length")

        // Block text really is what sits at its range in the plain text.
        let utf16 = Array(chapter.plainText.utf16)
        for block in chapter.blocks {
            #expect(String(decoding: utf16[block.textRange], as: UTF16.self) == block.text, "\(label) block \(block.id) range")
            if block.textRange.upperBound < utf16.count { #expect(utf16[block.textRange.upperBound] == 0x0A) }
        }

        // Position lookup: first and last offset of several blocks map back to the block.
        let step = max(1, chapter.blocks.count / 7)
        for index in stride(from: 0, to: chapter.blocks.count, by: step) + [chapter.blocks.count - 1] where index >= 0 {
            let block = chapter.blocks[index]
            #expect(chapter.block(containing: block.textOffset)?.id == block.id, "\(label) first offset of \(index)")
            if block.textLength > 0 {
                #expect(chapter.block(containing: block.textRange.upperBound - 1)?.id == block.id, "\(label) last offset of \(index)")
            }
        }
        if let first = chapter.blocks.first, let last = chapter.blocks.last {
            #expect(first.textOffset == 0)
            #expect(chapter.block(containing: chapter.textLength - 1)?.id == last.id)
        } else {
            #expect(chapter.textLength == 0)
            #expect(chapter.block(containing: 0) == nil)
        }

        for (id, offset) in chapter.anchorOffsets {
            #expect((0...chapter.textLength).contains(offset), "\(label) anchor \(id)")
        }
    }

    @Test("random tag soup never breaks the offset invariants")
    func tagSoup() {
        let vocabulary = [
            "<p>", "</p>", "<div>", "</div>", "<b>", "</b>", "<i>", "</i>", "<br/>", "<img src='x.png'/>", "<hr/>",
            "<ul>", "<ol start='3'>", "<li>", "</li>", "</ul>", "</ol>", "<table>", "<tr>", "<td>", "</td>", "</tr>",
            "</table>", "<pre>", "</pre>", "<blockquote>", "</blockquote>", "word ", "text, ", "&amp;", "&nbsp;",
            " ", "\n", "<q>", "</q>", "<a href='h' id='i1'>", "</a>", "<h1>", "</h1>", "<h3>", "<span id='s'>",
            "</span>", "<svg>", "<image href='i'/>", "</svg>", "<body>", "</body>", "<!-- c -->", "<![CDATA[x]]>",
            "<script>", "</script>", "<center>", "</center>", "<dl>", "<dt>", "<dd>", "</dl>", "<figure>",
            "<figcaption>", "</figure>", "<epub:switch>", "<epub:case>", "</epub:case>", "</epub:switch>",
            "<p hidden>", "<div style='text-align:right'>", "<section id='sec'>", "</section>", "<", ">", "&",
        ]
        var state: UInt64 = 0x5EED_1234_ABCD_0042
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for round in 0..<400 {
            let length = 1 + next() % 120
            let html = (0..<length).map { _ in vocabulary[next() % vocabulary.count] }.joined()
            let chapter = XHTMLConverter().convert(html)
            checkInvariants(chapter, "soup #\(round): \(html.debugDescription)", expectTrimmed: !html.contains("<pre>"))
        }
    }

    @Test("the hub fixture: 900 identical paragraphs numbered p[1]...p[900]")
    func hubFixture() throws {
        let chapter = XHTMLConverter().convert(try TextFixture.entry("OEBPS/ch1.xhtml", in: "hub-fixture.epub"))
        #expect(chapter.blocks.count == 900)
        #expect(chapter.blocks.map(\.elementPath) == (1...900).map { "/body/p[\($0)]" })
        #expect(Set(chapter.blocks.map(\.text)).count == 1, "every paragraph has identical text")
        let length = chapter.blocks[0].textLength
        #expect(length > 1000)
        #expect(chapter.textLength == 900 * (length + 1))
        #expect(chapter.blocks[899].textOffset == 899 * (length + 1))
        #expect(chapter.block(containing: 450 * (length + 1) + 5)?.elementPath == "/body/p[451]")
    }

    @Test("block(containing:) clamps outside the text")
    func containingOutOfRange() {
        let chapter = TextTesting.convert("<p>ab</p><p>cd</p>")
        #expect(chapter.block(containing: -1) == nil)
        #expect(chapter.block(containing: 0)?.text == "ab")
        #expect(chapter.block(containing: 2)?.text == "ab")  // the separator belongs to the block before it
        #expect(chapter.block(containing: 3)?.text == "cd")
        #expect(chapter.block(containing: 99)?.text == "cd")
    }
}
