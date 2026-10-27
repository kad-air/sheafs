import Foundation
import SheafsKit
import Testing

/// Hand-written cases for the conversion rules. Every expected value here was worked out from
/// the rules, not copied from the converter's output.
@Suite("XHTMLConverter rules")
struct XHTMLConverterTests {
    private typealias T = TextTesting

    // MARK: Blocks

    @Test("text directly in body or a div opens an implicit paragraph at the container's path")
    func implicitParagraphs() {
        let chapter = T.convert("loose <b>text</b><div>Hello <i>big</i> world<p>Para</p>tail</div>")
        #expect(chapter.blockTexts == ["loose text", "Hello big world", "Para", "tail"])
        #expect(chapter.blockPaths == ["/body", "/body/div[1]", "/body/div[1]/p[1]", "/body/div[1]"])
        #expect(chapter.blocks.allSatisfy { $0.kind == .paragraph })
    }

    @Test("whitespace-only text between blocks makes no blocks")
    func whitespaceBetweenBlocks() {
        let chapter = T.convert("\n  <div>\n  <p>a</p>\n  <p>b</p>\n  </div>\n  ")
        #expect(chapter.blockTexts == ["a", "b"])
    }

    @Test("nested blockquotes add one indent each; bare text inside is a blockquote block")
    func nestedBlockquotes() {
        let chapter = T.convert("""
            <p>before</p>
            <blockquote>one<blockquote><p>two</p></blockquote><p>three</p></blockquote>
            <p>after</p>
            """)
        #expect(chapter.blockTexts == ["before", "one", "two", "three", "after"])
        #expect(chapter.blocks.map(\.indent) == [0, 1, 2, 1, 0])
        #expect(chapter.blocks.map(\.kind) == [.paragraph, .blockquote, .blockquote, .blockquote, .paragraph])
        #expect(chapter.blocks[1].elementPath == "/body/blockquote[1]")
        #expect(chapter.blocks[2].elementPath == "/body/blockquote[1]/blockquote[1]/p[1]")
    }

    @Test("list items are numbered within their own list; nested lists indent")
    func lists() {
        let chapter = T.convert("""
            <ol><li>a</li><li>b<ul><li>c</li><li>d</li></ul></li><li>e</li></ol>
            <ul><li>f</li></ul>
            <ol start="5"><li>g</li><li>h</li></ol>
            """)
        #expect(chapter.blockTexts == ["a", "b", "c", "d", "e", "f", "g", "h"])
        #expect(chapter.blocks.map(\.kind) == [
            .listItem(ordered: true, ordinal: 1),
            .listItem(ordered: true, ordinal: 2),
            .listItem(ordered: false, ordinal: 1),
            .listItem(ordered: false, ordinal: 2),
            .listItem(ordered: true, ordinal: 3),
            .listItem(ordered: false, ordinal: 1),
            .listItem(ordered: true, ordinal: 5),
            .listItem(ordered: true, ordinal: 6),
        ])
        #expect(chapter.blocks.map(\.indent) == [0, 0, 1, 1, 0, 0, 0, 0])
        #expect(chapter.blocks[2].elementPath == "/body/ol[1]/li[2]/ul[1]/li[1]")
        #expect(chapter.blocks[7].elementPath == "/body/ol[2]/li[2]")
    }

    @Test("a list item whose text sits in a paragraph still yields the list item block")
    func listItemsWithParagraphs() {
        let chapter = T.convert("""
            <ol><li><p>first</p><p>second</p></li><li><div>third</div></li><li></li><li>fourth</li></ol><p>after</p>
            """)
        #expect(chapter.blockTexts == ["first", "second", "third", "fourth", "after"])
        #expect(chapter.blocks.map(\.kind) == [
            .listItem(ordered: true, ordinal: 1), .paragraph, .listItem(ordered: true, ordinal: 2),
            .listItem(ordered: true, ordinal: 4), .paragraph,
        ])
        #expect(chapter.blockPaths == [
            "/body/ol[1]/li[1]/p[1]", "/body/ol[1]/li[1]/p[2]", "/body/ol[1]/li[2]/div[1]",
            "/body/ol[1]/li[4]", "/body/p[1]",
        ])
    }

    @Test("unclosed list items close each other")
    func unclosedListItems() {
        let chapter = T.convert("<ul><li>one<li>two<li>three</ul><p>after</p>")
        #expect(chapter.blockTexts == ["one", "two", "three", "after"])
        #expect(chapter.blockPaths == ["/body/ul[1]/li[1]", "/body/ul[1]/li[2]", "/body/ul[1]/li[3]", "/body/p[1]"])
    }

    @Test("br is U+2028, never a newline; spaces around it and a trailing br are dropped")
    func lineBreaks() {
        let chapter = T.convert("<p>one<br/>two <br />  three<br/></p><p><br/>lead</p><div>x<br>y</div>")
        #expect(chapter.blockTexts == ["one\u{2028}two\u{2028}three", "\u{2028}lead", "x\u{2028}y"])
        #expect(chapter.plainText == "one\u{2028}two\u{2028}three\n\u{2028}lead\nx\u{2028}y\n")
        #expect(chapter.blocks.allSatisfy { !$0.text.contains("\n") })
    }

    @Test("an image inside a paragraph splits it: text before, image block, text after")
    func imageSplitsParagraph() {
        let chapter = T.convert("<p>before <img src=\"a.png\" alt=\"An A\"/> after</p>")
        #expect(chapter.blockTexts == ["before", "\u{FFFC}", "after"])
        #expect(chapter.blocks[1].kind == .image(source: "a.png", alt: "An A"))
        #expect(chapter.blocks.map(\.elementPath) == ["/body/p[1]", "/body/p[1]/img[1]", "/body/p[1]"])
        #expect(chapter.blocks.map(\.textOffset) == [0, 7, 9])
        #expect(chapter.textLength == 15)
        #expect(chapter.blocks[0].kind == .paragraph && chapter.blocks[2].kind == .paragraph)
    }

    @Test("image sources: src, xlink:href and href are kept as written; no source, no block")
    func imageSources() {
        let chapter = T.convert("""
            <img src="../Images/a%20b.png"/>
            <div><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image width="1" xlink:href="cover.jpg"/></svg></div>
            <svg><image href="plain.jpg"></image></svg>
            <img alt="no source"/>
            """)
        #expect(chapter.blocks.map(\.kind) == [
            .image(source: "../Images/a%20b.png", alt: nil),
            .image(source: "cover.jpg", alt: nil),
            .image(source: "plain.jpg", alt: nil),
        ])
        #expect(chapter.blockTexts == ["\u{FFFC}", "\u{FFFC}", "\u{FFFC}"])
        #expect(chapter.blocks[1].elementPath == "/body/div[1]/svg[1]/image[1]")
    }

    @Test("hr is kept as a block whose text is one U+FFFC")
    func horizontalRule() {
        let chapter = T.convert("<p>a</p><hr/><p>b</p>")
        #expect(chapter.blocks.map(\.kind) == [.paragraph, .horizontalRule, .paragraph])
        #expect(chapter.blockTexts == ["a", "\u{FFFC}", "b"])
        #expect(chapter.blocks.map(\.textOffset) == [0, 2, 4])
        #expect(chapter.blocks[1].elementPath == "/body/hr[1]")
        #expect(chapter.textLength == 6)
        #expect(chapter.plainText == "a\n\u{FFFC}\nb\n")
    }

    @Test("pre keeps whitespace verbatim with newlines as U+2028; the newline right after <pre> is ignored")
    func preformatted() {
        let chapter = T.convert("<pre>\n  line1\n    <i>line2</i>\r\n\n\tline4</pre><pre>   \n </pre><p>x</p>")
        #expect(chapter.blocks.count == 2)
        #expect(chapter.blocks[0].kind == .preformatted)
        #expect(chapter.blocks[0].text == "  line1\u{2028}    line2\u{2028}\u{2028}\tline4")
        #expect(chapter.blocks[0].runs.map(\.style) == [[], .italic, []])
        #expect(chapter.blocks[1].text == "x")
    }

    @Test("the final newline of a pre ends its last line instead of adding a blank one")
    func preformattedTrailingNewline() {
        let chapter = T.convert("<pre>a\nb\n</pre><pre>c\n\n</pre>")
        #expect(chapter.blockTexts == ["a\u{2028}b", "c\u{2028}"])
    }

    @Test("headings 1 through 6", arguments: 1...6)
    func headings(level: Int) {
        let chapter = T.convert("<h\(level) id=\"h\">Title \(level)</h\(level)>")
        #expect(chapter.blocks.count == 1)
        #expect(chapter.blocks[0].kind == .heading(level: level))
        #expect(chapter.blocks[0].alignment == .natural)
        #expect(chapter.blocks[0].elementPath == "/body/h\(level)[1]")
    }

    @Test("figure captions, definition lists and table rows")
    func captionsDefinitionsAndTables() {
        let chapter = T.convert("""
            <figure><img src="f.png"/><figcaption>A <i>cap</i></figcaption></figure>
            <dl><dt>Term</dt><dd>Meaning</dd></dl>
            <table><caption>Cap2</caption><tr><td>A</td><td>B</td></tr><tr><td> C </td><td></td><td><a href="x">D</a></td></tr></table>
            """)
        #expect(chapter.blockTexts == ["\u{FFFC}", "A cap", "Term", "Meaning", "Cap2", "A \u{2003} B", "C \u{2003} D"])
        #expect(chapter.blocks[1].kind == .caption)
        #expect(chapter.blocks[2].kind == .paragraph)
        #expect(chapter.blocks[2].runs == [T.run("Term", .bold)])
        #expect(chapter.blocks[3].indent == 1)
        #expect(chapter.blocks[3].runs == [T.run("Meaning")])
        #expect(chapter.blocks[4].kind == .caption)
        #expect(chapter.blocks[5].elementPath == "/body/table[1]/tr[1]")
        #expect(chapter.blocks[6].elementPath == "/body/table[1]/tr[2]")
        #expect(chapter.blocks[6].runs == [T.run("C \u{2003} "), T.run("D", link: "x")])
    }

    // MARK: Inline

    @Test("inline tags map to styles and nest")
    func inlineStyles() {
        let chapter = T.convert("""
            <p>plain <em>it <strong>both</strong></em> <b>b</b><u>u</u><s>s</s><code>c</code>x<sup>1</sup><sub>2</sub><small>sm</small><span style="font-variant: small-caps">SC</span></p>
            """)
        #expect(chapter.blocks.count == 1)
        #expect(chapter.blocks[0].runs == [
            T.run("plain "),
            T.run("it ", .italic),
            T.run("both", [.italic, .bold]),
            T.run(" "),
            T.run("b", .bold),
            T.run("u", .underline),
            T.run("s", .strikethrough),
            T.run("c", .code),
            T.run("x"),
            T.run("1", .superscript),
            T.run("2", .subscript),
            T.run("sm"),
            T.run("SC", .smallCaps),
        ])
    }

    @Test("every italic, bold, underline, strikethrough and code tag")
    func styleTagAliases() {
        let cases: [(String, InlineStyle)] = [
            ("em", .italic), ("i", .italic), ("cite", .italic), ("dfn", .italic), ("var", .italic),
            ("strong", .bold), ("b", .bold), ("u", .underline), ("ins", .underline),
            ("s", .strikethrough), ("del", .strikethrough), ("strike", .strikethrough),
            ("code", .code), ("kbd", .code), ("samp", .code), ("tt", .code),
        ]
        for (tag, style) in cases {
            let chapter = T.convert("<p><\(tag)>x</\(tag)></p>")
            #expect(chapter.blocks.first?.runs == [T.run("x", style)], "<\(tag)>")
        }
    }

    @Test("inline style attributes")
    func inlineStyleAttributes() {
        let chapter = T.convert("""
            <p><span style="font-style: oblique">a</span><span style="font-weight:700">b</span><span style="font-weight: normal">c</span>\
            <span style="text-decoration: underline">d</span><span style="text-decoration: line-through">e</span>\
            <span style="FONT-STYLE: Italic !important; font-weight: bold">f</span><span style="font-weight: 300">g</span></p>
            """)
        #expect(chapter.blocks[0].runs == [
            T.run("a", .italic), T.run("b", .bold), T.run("c"), T.run("d", .underline),
            T.run("e", .strikethrough), T.run("f", [.italic, .bold]), T.run("g"),
        ].mergingNeighbours())
    }

    @Test("adjacent runs with the same style and link merge")
    func runsMerge() {
        let chapter = T.convert("<p><i>a</i><i>b</i><em>c</em> d <a href=\"x\">e</a><a href=\"x\">f</a><a href=\"y\">g</a></p>")
        #expect(chapter.blocks[0].runs == [
            T.run("abc", .italic), T.run(" d "), T.run("ef", link: "x"), T.run("g", link: "y"),
        ])
    }

    @Test("links keep their href as written; noteref links are superscript")
    func links() {
        let chapter = T.convert("""
            <p>See <a href="ch2.xhtml#n1">note<sup>1</sup></a> and <a epub:type="noteref" href="#n2">2</a>, \
            <a href="">empty</a> <a name="old">named</a>.</p>
            """)
        #expect(chapter.blocks[0].runs == [
            T.run("See "),
            T.run("note", link: "ch2.xhtml#n1"),
            T.run("1", .superscript, link: "ch2.xhtml#n1"),
            T.run(" and "),
            T.run("2", .superscript, link: "#n2"),
            T.run(", empty named."),
        ])
        #expect(chapter.anchorOffsets["old"] == chapter.blocks[0].text.utf16.count - "named.".utf16.count)
    }

    @Test("q wraps its text in curly quotes")
    func quotes() {
        let chapter = T.convert("<p>He said <q>hi <q>there</q></q>.</p>")
        #expect(chapter.blockTexts == ["He said \u{201C}hi \u{201C}there\u{201D}\u{201D}."])
    }

    // MARK: Alignment

    /// `text-align: justify` reads as `.natural`: whether text is justified is the reader's
    /// setting (`Typesetter` justifies `.justified` blocks whatever the setting says).
    @Test("alignment comes from center, align, text-align and class conventions, and is inherited")
    func alignment() {
        let chapter = T.convert("""
            <center><p>a</p></center>
            <p style="text-align: right">b</p>
            <div class="chapter Center"><p>c</p></div>
            <p align="center">d</p>
            <p class="tc">e</p>
            <h2 class="centered">f</h2>
            <p style="text-align:justify">g</p>
            <div align="right"><p>h</p><p style="text-align: left">i</p></div>
            <p class="ta-c x">j</p>
            <p class="right">k</p>
            <p class="centering-ish">l</p>
            <p>m</p>
            """)
        #expect(chapter.blocks.map(\.alignment) == [
            .center, .trailing, .center, .center, .center, .center, .natural,
            .trailing, .natural, .center, .trailing, .natural, .natural,
        ])
    }

    // MARK: Anchors

    @Test("id and a/name anchors record the plain-text offset where the element starts")
    func anchors() {
        let chapter = T.convert("""
            <p>Hello <span id="mid">world</span></p>
            <p id="second">x</p>
            <div id="between"></div>
            <p>last <a name="legacy"/>tail</p>
            <h2><a id="chap"/>Title</h2>
            """)
        #expect(chapter.blockTexts == ["Hello world", "x", "last tail", "Title"])
        #expect(chapter.blocks.map(\.textOffset) == [0, 12, 14, 24])
        #expect(chapter.anchorOffsets == [
            "mid": 6, "second": 12, "between": 14, "legacy": 19, "chap": 24,
        ])
    }

    @Test("an anchor on an empty paragraph points at the next block; the first of duplicate ids wins")
    func anchorsOnEmptyElements() {
        let chapter = T.convert("<p>a</p><p id=\"gone\"><span id=\"also\"></span></p><p id=\"dup\">b</p><p id=\"dup\">c</p>")
        #expect(chapter.blockTexts == ["a", "b", "c"])
        #expect(chapter.anchorOffsets == ["gone": 2, "also": 2, "dup": 2])
    }

    @Test("anchors in text that gets trimmed or dropped stay within the chapter")
    func anchorsAtTrimmedEnds() {
        let chapter = T.convert("<p>Hello <a id=\"end\"/></p><p><br/><a id=\"lost\"/></p><p>x<br/><span id=\"tail\"/></p>")
        #expect(chapter.blockTexts == ["Hello", "x"])
        #expect(chapter.anchorOffsets == ["end": 5, "lost": 6, "tail": 7])
        #expect(chapter.textLength == 8)
    }

    // MARK: Whitespace and characters

    @Test("whitespace collapses; non-breaking space and other Unicode spaces are kept")
    func whitespace() {
        let chapter = T.convert("<p>  a \n\t b   <b> c </b>  d  </p><p>x&nbsp;&nbsp;y\u{2003}z</p>")
        #expect(chapter.blockTexts == ["a b c d", "x\u{00A0}\u{00A0}y\u{2003}z"])
        #expect(chapter.blocks[0].runs == [T.run("a b "), T.run("c ", .bold), T.run("d")])
    }

    @Test("entities: named, numeric, undefined passthrough")
    func entities() {
        let chapter = T.convert("<p>a&nbsp;b &mdash; &#8217;s &#x1F600; &hellip;&euro;&eacute; &bogus; &amp; &lt;t&gt; AT&T &#150; &#x110000;</p>")
        #expect(chapter.blockTexts == [
            "a\u{00A0}b \u{2014} \u{2019}s \u{1F600} \u{2026}\u{20AC}\u{E9} &bogus; & <t> AT&T \u{2013} \u{FFFD}",
        ])
    }

    @Test("entities in attribute values are decoded")
    func attributeEntities() {
        let chapter = T.convert("<p><a href=\"a?x=1&amp;y=2&copy\">l</a></p>")
        #expect(chapter.blocks[0].runs == [T.run("l", link: "a?x=1&y=2&copy")])
    }

    @Test("comments, CDATA, processing instructions and doctype are handled")
    func markupNoise() {
        let chapter = XHTMLConverter().convert("""
            <?xml version="1.0" encoding="utf-8"?><!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "x.dtd">
            <html><body><p>a<!-- <p>no</p> -->b<![CDATA[<c> & d]]></p><?php nope ?></body></html>
            """)
        #expect(chapter.blockTexts == ["ab<c> & d"])
    }

    // MARK: Skipped content

    @Test("script, style, template and hidden content are skipped but still counted in paths")
    func skippedContent() {
        let chapter = T.convert("""
            <p>a</p><script>var x = "<p>no</p>";</script><style>p { color: red }</style>\
            <p hidden="">h</p><div hidden><p>h2</p></div><template><p>t</p></template>\
            <p style="display:none">d</p><p>b <span hidden>skip</span>c</p>
            """)
        #expect(chapter.blockTexts == ["a", "b c"])
        #expect(chapter.blockPaths == ["/body/p[1]", "/body/p[4]"])
    }

    @Test("the title comes from the head; the head itself is not content")
    func title() {
        let chapter = XHTMLConverter().convert("""
            <html><head><title>  My
              &amp; Title </title><style>p{}</style></head><body><p>x</p></body></html>
            """)
        #expect(chapter.title == "My & Title")
        #expect(chapter.blockTexts == ["x"])
        #expect(T.convert("<p>y</p>").title == nil)
    }

    @Test("epub:switch is transparent and its epub:case branch is skipped")
    func epubSwitch() {
        let chapter = T.convert("""
            <p>a<epub:switch><epub:case required-namespace="http://www.w3.org/1998/Math/MathML">CASE</epub:case>\
            <epub:default>DEFAULT</epub:default></epub:switch>b</p>
            """)
        #expect(chapter.blockTexts == ["aDEFAULTb"])
    }

    @Test("namespace-prefixed and upper-case tags are normalized")
    func prefixesAndCase() {
        let chapter = T.convert("""
            <P CLASS="Center">Hi<BR>there</P>\
            <svg:svg xmlns:svg="http://www.w3.org/2000/svg"><svg:image xlink:href="c.jpg"/></svg:svg>
            """)
        #expect(chapter.blockTexts == ["Hi\u{2028}there", "\u{FFFC}"])
        #expect(chapter.blocks[0].alignment == .center)
        #expect(chapter.blocks[0].elementPath == "/body/p[1]")
        #expect(chapter.blocks[1].kind == .image(source: "c.jpg", alt: nil))
        #expect(chapter.blocks[1].elementPath == "/body/svg[1]/image[1]")
    }

    // MARK: Element paths

    @Test("steps count same-tag siblings per parent")
    func elementPaths() {
        let chapter = T.convert("""
            <section><p>1</p><div><p>2</p></div><p>3</p><br/><img src="i.png"/><p>4</p></section>
            <section><p>5</p><span></span><p>6</p></section>
            """)
        #expect(chapter.blockPaths == [
            "/body/section[1]/p[1]", "/body/section[1]/div[1]/p[1]", "/body/section[1]/p[2]",
            "/body/section[1]/img[1]", "/body/section[1]/p[3]",
            "/body/section[2]/p[1]", "/body/section[2]/p[2]",
        ])
    }

    @Test("a flat run of paragraphs numbers up to the hundreds")
    func manyParagraphs() {
        let html = (1...300).map { "<p>Paragraph \($0)</p>" }.joined()
        let chapter = T.convert("<section>\(html)</section>")
        #expect(chapter.blocks.count == 300)
        #expect(chapter.blocks[104].elementPath == "/body/section[1]/p[105]")
        #expect(chapter.block(atElementPath: "/body/section/p[105]")?.text == "Paragraph 105")
    }

    // MARK: Sloppy markup

    @Test("unclosed paragraphs close when the next block opens")
    func unclosedParagraphs() {
        let chapter = T.convert("<p>one<p>two<p>three<div><p>a<p>b</div>c<h2>head<p>after head")
        #expect(chapter.blockTexts == ["one", "two", "three", "a", "b", "c", "head", "after head"])
        #expect(chapter.blockPaths == [
            "/body/p[1]", "/body/p[2]", "/body/p[3]", "/body/div[1]/p[1]", "/body/div[1]/p[2]",
            "/body", "/body/h2[1]", "/body/p[4]",
        ])
    }

    @Test("a stray close tag is ignored; a close pops to the nearest matching open element")
    func strayAndMisnestedCloses() {
        let chapter = T.convert("<p>a</p></div></span></p><p>b</p><div><p>c</span></p>d</div><div><p>e</div>f")
        #expect(chapter.blockTexts == ["a", "b", "c", "d", "e", "f"])
        #expect(chapter.blockPaths == [
            "/body/p[1]", "/body/p[2]", "/body/div[1]/p[1]", "/body/div[1]", "/body/div[2]/p[1]", "/body",
        ])
        // Inline closes pop through unclosed inline children: </p> ends the open <b>.
        let nested = T.convert("<p>x<b>bold</p><p>y</p>")
        #expect(nested.blockTexts == ["xbold", "y"])
        #expect(nested.blocks[0].runs == [T.run("x"), T.run("bold", .bold)])
        #expect(nested.blocks[1].runs == [T.run("y")])
    }

    @Test("content after </body> is ignored; a document without <body> still converts")
    func bodyBoundaries() {
        #expect(XHTMLConverter().convert("<html><body><p>a</p></body><p>ignored</p></html>").blockTexts == ["a"])
        let fragment = XHTMLConverter().convert("<p>Hi</p><p>there</p>")
        #expect(fragment.blockTexts == ["Hi", "there"])
        #expect(fragment.blockPaths == ["/body/p[1]", "/body/p[2]"])
        let bare = XHTMLConverter().convert("just some text")
        #expect(bare.blockTexts == ["just some text"])
        #expect(bare.blockPaths == ["/body"])
    }

    // MARK: Input encodings and garbage

    @Test("empty and garbage input never fails")
    func garbage() {
        #expect(XHTMLConverter().convert("").blocks.isEmpty)
        #expect(XHTMLConverter().convert(Data()).blocks.isEmpty)
        #expect(XHTMLConverter().convert("").textLength == 0)
        #expect(XHTMLConverter().convert("").plainText == "")
        for junk in [
            "<<<>>> &&& </ <!-- unterminated", "<p", "<p class=\"x", "<![CDATA[ never closed",
            "</p></p></p>", "<body><body><body>", "&#99999999999999999999;&#x;&#;", "<html><head><title>t",
            "<a><b><i><u><s><q><sup>deep", "\u{0}\u{1}\u{2}<p>\u{FEFF}x\u{0}</p>",
        ] {
            let chapter = XHTMLConverter().convert(junk)
            #expect(chapter.textLength == chapter.blocks.reduce(0) { $0 + $1.textLength + 1 }, "\(junk.debugDescription)")
        }
        let bytes = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 3)) })
        let chapter = XHTMLConverter().convert(bytes)
        #expect(chapter.textLength == chapter.blocks.reduce(0) { $0 + $1.textLength + 1 })
    }

    @Test("text decoding: UTF-8, UTF-8 with BOM, UTF-16 with BOM, and Latin 1 bytes")
    func decoding() throws {
        let html = "<html><body><p>caf\u{E9} \u{2014} \u{1F600}</p></body></html>"
        let expected = ["caf\u{E9} \u{2014} \u{1F600}"]
        #expect(XHTMLConverter().convert(Data(html.utf8)).blockTexts == expected)
        #expect(XHTMLConverter().convert(Data([0xEF, 0xBB, 0xBF] + Array(html.utf8))).blockTexts == expected)
        let utf16 = try #require(html.data(using: .utf16))  // little-endian with BOM
        #expect(XHTMLConverter().convert(utf16).blockTexts == expected)
        let utf16BE = try #require(html.data(using: .utf16BigEndian))
        #expect(XHTMLConverter().convert(Data([0xFE, 0xFF]) + utf16BE).blockTexts == expected)

        // "caf\xE9 \x92" is not valid UTF-8: read as Latin 1, with 0x92 as the Windows-1252 apostrophe.
        let latin1 = Data(Array("<p>caf".utf8) + [0xE9, 0x20, 0x92] + Array("</p>".utf8))
        #expect(XHTMLConverter().convert(latin1).blockTexts == ["caf\u{E9} \u{2019}"])
    }
}

private extension Array where Element == InlineRun {
    /// Merges adjacent runs with the same style and link, as the converter does.
    func mergingNeighbours() -> [InlineRun] {
        var merged: [InlineRun] = []
        for run in self {
            if let last = merged.last, last.style == run.style, last.link == run.link {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
