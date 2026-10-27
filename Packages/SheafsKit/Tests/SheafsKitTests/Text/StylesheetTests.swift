import Foundation
import Synchronization
import Testing
@testable import SheafsKit

/// The publisher's CSS: the parser's subset, the cascade, and what it may and may not change in a
/// chapter (styles, alignment and hidden text yes; element paths never).
@Suite("Stylesheets")
struct StylesheetTests {
    typealias T = TextTesting

    // MARK: Parsing

    @Test("selectors outside the subset are dropped whole; the rest of the list stays")
    func selectorSubset() {
        let sheet = Stylesheet(css: """
            P, .a, #b, div.c > span.d, ul  li, *, *.e { font-style: italic }
            p::first-letter, a:hover, a[href], h1 + p, h1 ~ p, svg|a, .x\\:y, > p, p >, p > > a, #a#b { font-weight: bold }
            """)
        #expect(sheet.ruleCount == 7)
        #expect(sheet.rules.map(\.specificity) == [1, 1_000, 1_000_000, 2_002, 2, 0, 1_000])
        #expect(sheet.rules[0].selector.compounds == [CSSCompound(tag: "p")])
        #expect(sheet.rules[3].selector.combinators == [.child])
        #expect(sheet.rules[4].selector.combinators == [.descendant])
    }

    @Test("at-rules are skipped, nested blocks included; @import targets are recorded")
    func atRules() {
        let sheet = Stylesheet(css: """
            @charset "utf-8";
            @import url("base.css") screen;
            @import 'more.css';
            @import url(bare.css);
            @namespace epub "http://www.idpf.org/2007/ops";
            @font-face { font-family: X; src: url(x.otf) }
            @media amzn-kf8 { .k { display: none } @supports (x: y) { .k2 { display: none } } }
            .kept { font-variant: small-caps }
            """)
        #expect(sheet.imports == ["base.css", "more.css", "bare.css"])
        #expect(sheet.ruleCount == 1)
        #expect(sheet.rules.first?.selector.compounds.first?.classes == ["kept"])
    }

    @Test("comments, braces inside strings and <!-- --> wrappers do not derail the parser")
    func robustness() {
        let sheet = Stylesheet(css: """
            <!-- /* { */ p::before { content: "}{;" } .q { quotes: "{" "}"; font-style: italic }
            /* .gone { font-weight: bold } */ .bold { font-weight: 700 } -->
            } .after-stray { text-align: center }
            .unterminated { font-style: italic
            """)
        #expect(sheet.rules.map { $0.selector.compounds.first?.classes ?? [] } == [["q"], ["bold"], ["after-stray"], ["unterminated"]])
        #expect(sheet.rules[0].declarations.normal.italic == true)
        #expect(sheet.rules[1].declarations.normal.bold == true)
    }

    @Test("a UTF-8 byte order mark and Latin 1 bytes decode")
    func encodings() {
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data(".a { font-style: italic }".utf8))
        #expect(Stylesheet(data: bom).rules.first?.selector.compounds.first?.classes == ["a"])
        let latin1 = Data([0x2E, 0x63, 0x61, 0x66, 0xE9, 0x7B, 0x66, 0x6F, 0x6E, 0x74, 0x2D, 0x77, 0x65, 0x69,
                           0x67, 0x68, 0x74, 0x3A, 0x62, 0x6F, 0x6C, 0x64, 0x7D])   // ".café{font-weight:bold}"
        #expect(Stylesheet(data: latin1).rules.first?.selector.compounds.first?.classes == ["café"])
    }

    @Test("declarations: each property the text model understands, others ignored")
    func declarations() {
        func props(_ text: String) -> CSSProperties { CSSDeclarations(text).normal }
        #expect(props("font-style: oblique").italic == true)
        #expect(props("font-style: normal").italic == false)
        #expect(props("font-weight: 600").bold == true)
        #expect(props("font-weight: 400").bold == false)
        #expect(props("font-weight: bolder").bold == true)
        #expect(props("font-variant: small-caps").smallCaps == true)
        #expect(props("font-variant-caps: all-small-caps").smallCaps == true)
        #expect(props("vertical-align: super").verticalAlign == .superscript)
        #expect(props("vertical-align: top").verticalAlign == nil)
        #expect(props("vertical-align: baseline").verticalAlign == nil)
        #expect(props("text-align: justify").alignment == .natural)
        #expect(props("text-align: end").alignment == .trailing)
        #expect(props("display: none").hidden == true)
        #expect(props("display: block").hidden == false)
        #expect(props("color: red; font-family: serif; font-size: 3em; text-indent: 2em").isEmpty)
        let both = CSSDeclarations("font-style: italic !important; font-weight: bold; text-align: center ! important")
        #expect(both.important.italic == true && both.normal.italic == nil && both.normal.bold == true)
        #expect(both.important.alignment == .center && both.normal.alignment == nil)
    }

    // MARK: The cascade in a chapter

    @Test("a class-only italic span, a hidden div, a centred class, and specificity, from a <style> block")
    func styleBlock() {
        let chapter = T.convert("""
            <div class="front"><p>Hidden front matter</p><p id="gone">More</p></div>
            <p>She wrote: <span class="thought">I must go</span>.</p>
            <p class="verse">A line of verse</p>
            <p class="verse" style="text-align: left">The style attribute wins</p>
            <p id="sign">Yours</p>
            """, head: """
            <style type="text/css">
              p { text-align: right }
              .thought { font-style: italic }
              div.front { display: none }
              p.verse { text-align: center }
              p { text-align: justify }
              #sign { text-align: right }
              p#sign { text-align: center }
            </style>
            """)
        #expect(chapter.blockTexts == ["She wrote: I must go.", "A line of verse", "The style attribute wins", "Yours"])
        #expect(chapter.blocks[0].runs == [T.run("She wrote: "), T.run("I must go", .italic), T.run(".")])
        // Class beats tag whatever the order; the later of two equal tag rules wins (justify →
        // natural); inline beats class; id + tag beats id.
        #expect(chapter.blocks.map(\.alignment) == [.natural, .center, .natural, .center])
        // The hidden div still takes its step: the next div would be div[2], the paragraphs
        // after it are p[1]...
        #expect(chapter.blockPaths == ["/body/p[1]", "/body/p[2]", "/body/p[3]", "/body/p[4]"])
        // An anchor inside hidden content stays, where that content would have been.
        #expect(chapter.anchorOffsets["gone"] == 0)
        #expect(chapter.anchorOffsets["sign"] == chapter.blocks[3].textOffset)
    }

    @Test("normal, bold and the rest switch inherited styles off as well as on")
    func styleOff() {
        let chapter = T.convert("""
            <blockquote class="letter"><p>Dear <em>Jane</em>, <span class="plain">plain</span> \
            <b class="light">light</b> <span class="up">up</span><sub class="flat">flat</sub> \
            <u class="nou">no line</u><span class="sc">Darcy</span></p></blockquote>
            """, head: """
            <style>
              .letter { font-style: italic }
              em { font-style: normal }
              .plain { font-style: normal }
              .light { font-weight: normal }
              .up { vertical-align: super }
              .flat { vertical-align: baseline }
              .nou { text-decoration: none }
              .sc { font-variant: small-caps; text-decoration: underline }
            </style>
            """)
        #expect(chapter.blocks.first?.runs == [
            T.run("Dear ", .italic), T.run("Jane"), T.run(", ", .italic), T.run("plain"),
            T.run(" light ", .italic), T.run("up", [.italic, .superscript]), T.run("flat", [.italic, .subscript]),
            T.run(" no line", .italic),
            T.run("Darcy", [.italic, .smallCaps, .underline]),
        ])
    }

    @Test("descendant and child chains, the html root, and !important")
    func combinators() {
        let chapter = T.convert("""
            <div class="letter"><p>a <span class="name">Jane</span></p><div><p class="sig">b</p></div><p class="sig">c</p></div>
            <p class="sig">d <span class="name">Bingley</span></p>
            <p class="imp" style="font-weight: bold; font-style: normal">e</p>
            """, head: """
            <style>
              .letter .name { font-style: italic }
              .letter > .sig { font-weight: bold }
              html body > p.sig { text-align: center }
              html > body .letter p { text-align: right }
              .imp { font-style: italic !important; font-weight: normal }
              head p { font-weight: bold }
            </style>
            """)
        #expect(chapter.blocks.map(\.runs) == [
            [T.run("a "), T.run("Jane", .italic)],
            [T.run("b")],
            [T.run("c", .bold)],
            [T.run("d Bingley")],
            [T.run("e", [.italic, .bold])],
        ])
        #expect(chapter.blocks.map(\.alignment) == [.trailing, .trailing, .trailing, .center, .natural])
    }

    @Test("linked stylesheets need a library; without one only <style> blocks apply")
    func linkedNeedsLibrary() {
        let html = """
            <html><head><link rel="stylesheet" href="a.css"/><style>.s { font-weight: bold }</style></head>
            <body><p class="i s">x</p></body></html>
            """
        #expect(XHTMLConverter().convert(html).blocks.first?.runs == [T.run("x", .bold)])
        let sheet = Stylesheet(css: ".i { font-style: italic }")
        let linked = XHTMLConverter().convert(html) { href in href == "a.css" ? sheet : nil }
        #expect(linked.blocks.first?.runs == [T.run("x", [.italic, .bold])])
        // Alternate stylesheets and other link types are not applied.
        let alternate = XHTMLConverter().convert("""
            <html><head><link rel="alternate stylesheet" href="a.css"/><link rel="icon" href="a.css"/></head>
            <body><p class="i">x</p></body></html>
            """) { _ in sheet }
        #expect(alternate.blocks.first?.runs == [T.run("x")])
    }

    @Test("Standard Ebooks' title page: hidden for ADE, shown again inside @supports")
    func supportsUnhides() {
        // Standard Ebooks' core.css, verbatim: the hide, then the un-hide in @supports.
        let css = """
            section.epub-type-contains-word-titlepage h1,
            section.epub-type-contains-word-titlepage p,
            section.epub-type-contains-word-colophon h2,
            section.epub-type-contains-word-imprint h2{
            	display: none;
            }

            }

            /* ...but enable them for accessibility in all other ereaders */
            @supports(font-size: 0){
            	section.epub-type-contains-word-titlepage h1,
            	section.epub-type-contains-word-titlepage p,
            	section.epub-type-contains-word-colophon h2,
            	section.epub-type-contains-word-imprint h2{
            		display: block;
            	}
            }
            """
        let chapter = T.convert("""
            <section class="epub-type-contains-word-titlepage"><h1>Frankenstein</h1><p>By Mary Shelley.</p></section>
            <section class="epub-type-contains-word-imprint"><h2>Imprint</h2><p>Text</p></section>
            """, head: "<style>\(css)</style>")
        #expect(chapter.blockTexts == ["Frankenstein", "By Mary Shelley.", "Imprint", "Text"])
        // Without the @supports block the hide alone would apply.
        let hideOnly = T.convert("""
            <section class="epub-type-contains-word-titlepage"><h1>Frankenstein</h1></section><p>Text</p>
            """, head: "<style>section.epub-type-contains-word-titlepage h1 { display: none }</style>")
        #expect(hideOnly.blockTexts == ["Text"])
    }

    @Test("@media applies for no query, all and screen; print, other types and feature queries do not")
    func mediaBlocks() {
        let chapter = T.convert("""
            <p class="a">a</p><p class="b">b</p><p class="c">c</p><p class="d">d</p><p class="e">e</p><p class="f">f</p>
            """, head: """
            <style>
              @media print { .a { display: none } }
              @media screen { .b { font-style: italic } }
              @media all and (prefers-color-scheme: dark) { .c { display: none } }
              @media only screen, print { .d { font-weight: bold } }
              @media amzn-kf8 { .e { display: none } }
              @media { .f { text-align: center } }
              @font-face { .f { display: none } }
            </style>
            """)
        #expect(chapter.blocks.map(\.runs) == [
            [T.run("a")], [T.run("b", .italic)], [T.run("c")], [T.run("d", .bold)], [T.run("e")], [T.run("f")],
        ])
        #expect(chapter.blocks.last?.alignment == .center)
    }

    @Test("media attributes, CDATA wrappers, html declarations and the dt default")
    func headDetails() {
        let sheet = Stylesheet(css: ".l { font-style: italic }")
        let chapter = XHTMLConverter().convert("""
            <html><head>
            <link rel="stylesheet" href="print.css" media="print"/>
            <link rel="stylesheet" href="screen.css" media="screen"/>
            <style media="print">.s { display: none }</style>
            <style type="text/css"><![CDATA[ .c { font-weight: bold } html { text-align: center } dt { font-weight: normal } ]]></style>
            </head><body><p class="l s c">x</p><dl><dt>Term</dt><dd>def</dd></dl></body></html>
            """) { href in href == "screen.css" ? sheet : Stylesheet(css: ".l { display: none }") }
        #expect(chapter.blockTexts == ["x", "Term", "def"])
        #expect(chapter.blocks[0].runs == [T.run("x", [.italic, .bold])])
        #expect(chapter.blocks.map(\.alignment) == [.center, .center, .center])
        #expect(chapter.blocks[1].runs == [T.run("Term")])
        #expect(T.convert("<dl><dt>Term</dt></dl>").blocks.first?.runs == [T.run("Term", .bold)])
    }

    @Test("vertical-align: baseline (normalize.css) keeps sup and sub raised")
    func baselineKeepsSuperscript() {
        let chapter = T.convert("""
            <p>E = mc<sup>2</sup> and note<a href="#n1"><sup>1</sup></a> H<sub>2</sub>O</p>
            """, head: "<style>sub, sup { position: relative; vertical-align: baseline } sup { top: -.5em }</style>")
        #expect(chapter.blocks.first?.runs == [
            T.run("E = mc"), T.run("2", .superscript), T.run(" and note"), T.run("1", .superscript, link: "#n1"),
            T.run(" H"), T.run("2", .subscript), T.run("O"),
        ])
    }

    @Test("a note in a CSS-hidden aside keeps its anchor where the aside stands")
    func hiddenAnchor() {
        let chapter = T.convert("""
            <p>Text<a href="#n1">1</a> more.</p><aside id="n1" class="note"><p id="n1p">The note.</p></aside><p>Next</p>
            """, head: "<style>aside.note { display: none }</style>")
        #expect(chapter.blockTexts == ["Text1 more.", "Next"])
        #expect(chapter.anchorOffsets["n1"] == chapter.blocks[1].textOffset)
        #expect(chapter.anchorOffsets["n1p"] == chapter.blocks[1].textOffset)
        #expect(chapter.anchorOffsets["n1"] != 0)
    }

    @Test("small caps standing in for the markup's bold are marked, so a font without them can draw bold")
    func boldAsSmallCaps() {
        let chapter = T.convert("""
            <p><b>Bold</b> <span class="sc">caps</span> <strong>S<span class="up">t</span></strong> \
            <b class="heavy">heavy</b> <b><span style="font-variant: normal">plain</span></b></p>
            """, head: """
            <style>b, strong { font-variant: small-caps; font-weight: normal } .sc { font-variant: small-caps }
              .heavy { font-weight: bold }</style>
            """)
        #expect(chapter.blocks.first?.runs == [
            T.run("Bold", [.smallCaps, .boldAsSmallCaps]), T.run(" "), T.run("caps", .smallCaps), T.run(" "),
            T.run("St", [.smallCaps, .boldAsSmallCaps]), T.run(" "), T.run("heavy", [.smallCaps, .bold]),
            T.run(" plain"),
        ])
    }

    @Test("concurrent chapters read and parse a shared stylesheet once")
    func singleFlight() {
        let loads = Mutex(0)
        let library = StylesheetLibrary { _ in
            loads.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.05)   // a slow read: every other thread arrives meanwhile
            return Data(".a { font-style: italic }".utf8)
        }
        let found = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            if library.stylesheet(href: "../css/book.css", relativeTo: "OEBPS/text/ch.xhtml")?.ruleCount == 1 {
                found.withLock { $0 += 1 }
            }
        }
        #expect(loads.withLock { $0 } == 1)
        #expect(found.withLock { $0 } == 40)
    }

    // MARK: A book

    private static let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">x</dc:identifier>
            <dc:title>Styled</dc:title><dc:language>en</dc:language></metadata>
          <manifest>
            <item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="Styles/book.css" media-type="text/css"/>
            <item id="base" href="Styles/base.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """

    private static let chapterOne = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title>
        <link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
        <body>
        <div class="front"><p>Hidden front matter</p><p>More of it</p></div>
        <p>She wrote: <span class="thought">I must go</span>.</p>
        <div class="poem"><p class="verse">A line of verse</p></div>
        <p class="end">Mr. <span class="sc">Darcy</span></p>
        </body></html>
        """

    private static let files: [(String, String)] = [
        ("OEBPS/Text/ch1.xhtml", chapterOne),
        ("OEBPS/Text/ch2.xhtml", """
            <html><head><link rel="stylesheet" href="../Styles/book.css"/><link rel="stylesheet" href="../Styles/missing.css"/></head>
            <body><p class="thought">Again</p></body></html>
            """),
        ("OEBPS/Styles/book.css", """
            @import url("base.css");
            p { text-align: justify }
            .thought { font-style: italic }
            div.front { display: none }
            .poem p.verse { text-align: center }
            .end { text-align: right }
            """),
        ("OEBPS/Styles/base.css", "\u{FEFF}.sc { font-variant: small-caps }"),
    ]

    @Test("a book: stylesheets linked from a sibling folder, @import followed, each read once")
    func book() throws {
        let book = try EPUBBook(data: TestZipBuilder.epub(opf: Self.opf, files: Self.files))
        let loads = Mutex<[String]>([])
        let library = StylesheetLibrary { path in
            loads.withLock { $0.append(path) }
            return try? book.data(at: path)
        }
        let chapters = try book.spine.map { item in
            XHTMLConverter().convert(try book.data(for: item.item), documentPath: item.item.path, stylesheets: library)
        }
        let one = chapters[0]
        #expect(one.blockTexts == ["She wrote: I must go.", "A line of verse", "Mr. Darcy"])
        #expect(one.blocks[0].runs == [T.run("She wrote: "), T.run("I must go", .italic), T.run(".")])
        #expect(one.blocks.map(\.alignment) == [.natural, .center, .trailing])
        #expect(one.blocks[2].runs == [T.run("Mr. "), T.run("Darcy", .smallCaps)])
        #expect(chapters[1].blocks.first?.runs == [T.run("Again", .italic)])

        // Paths: the stylesheet removes the hidden div's blocks and changes nothing else.
        let unstyled = XHTMLConverter().convert(try book.data(at: "OEBPS/Text/ch1.xhtml"))
        #expect(unstyled.blockPaths == ["/body/div[1]/p[1]", "/body/div[1]/p[2]"] + one.blockPaths)
        #expect(one.blockPaths == ["/body/p[1]", "/body/div[2]/p[1]", "/body/p[2]"])
        // The offsets contract: block text + "\n" each, consecutive.
        var offset = 0
        for block in one.blocks {
            #expect(block.textOffset == offset)
            offset += block.textLength + 1
        }
        #expect(one.textLength == offset)
        #expect(one.plainText.utf16.count == one.textLength)

        // One read per file across both chapters, the missing one included.
        #expect(loads.withLock { $0.sorted() } == [
            "OEBPS/Styles/base.css", "OEBPS/Styles/book.css", "OEBPS/Styles/missing.css",
        ])
    }

    @Test("an @import cycle ends")
    func importCycle() {
        let sheets = ["a.css": "@import 'b.css'; .a { font-style: italic }", "b.css": "@import 'a.css'; .b { font-weight: bold }"]
        let library = StylesheetLibrary { sheets[$0].map { Data($0.utf8) } }
        #expect(library.stylesheet(at: "a.css")?.ruleCount == 2)
        #expect(library.stylesheet(href: "https://example.com/x.css", relativeTo: "a.xhtml") == nil)
    }

    // MARK: The fixtures (a second source: the raw markup, read with a regular expression)

    @Test("Pride and Prejudice: every span.smcap is small caps with its stylesheet, and only with it")
    func prideSmallCaps() throws {
        let epub = "pride-epub2.epub"
        let css = String(decoding: try TextFixture.entry("OEBPS/0.css", in: epub), as: UTF8.self)
        #expect(css.contains(".smcap {\n    font-variant: small-caps;"), "the fixture's stylesheet declares it")
        let span = #/<span class="smcap">([^<]+)<\/span>/#
        var spans = 0
        for path in try TextFixture.documentPaths(in: epub) {
            let raw = String(decoding: try TextFixture.entry(path, in: epub), as: UTF8.self)
            let expected = raw.matches(of: span).map { T.normalizedWhitespace(String($0.1)) }
            let styled = try T.convert(path, in: epub, stylesheets: true)
            let smallCaps = styled.blocks.flatMap(\.runs).filter { $0.style.contains(.smallCaps) }
                .map { T.normalizedWhitespace($0.text) }.joined(separator: " ")
            for text in expected {
                #expect(smallCaps.contains(text), "\(text) in \(path)")
            }
            spans += expected.count
            let unstyled = try T.convert(path, in: epub, stylesheets: false)
            #expect(!unstyled.blocks.flatMap(\.runs).contains { $0.style.contains(.smallCaps) })
        }
        #expect(spans == 9)
    }

    @Test("text-align: justify leaves justification to the reader; center and right still align")
    func justifyIsTheReaders() {
        let chapter = T.convert("""
            <p>a</p><p class="center">b</p><div class="r"><p>c</p></div><p style="text-align: justify">d</p>
            <p align="justify">e</p>
            """, head: """
            <style>body { text-align: justify } p { text-align: justify } .center { text-align: center }
              .r p { text-align: right }</style>
            """)
        #expect(chapter.blocks.map(\.alignment) == [.natural, .center, .trailing, .natural, .natural])
        #expect(!chapter.blocks.contains { $0.alignment == .justified })
    }
}
