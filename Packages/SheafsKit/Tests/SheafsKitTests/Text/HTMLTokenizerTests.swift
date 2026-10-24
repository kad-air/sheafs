import Foundation
import Testing
import SheafsKit

@Suite("HTMLTokenizer and entities")
struct HTMLTokenizerTests {
    private func tokens(_ html: String) -> [HTMLToken] {
        HTMLTokenizer(html).tokens()
    }

    private func start(_ name: String, _ attributes: [String: String] = [:], selfClosing: Bool = false) -> HTMLToken {
        .start(name: name, attributes: attributes, selfClosing: selfClosing)
    }

    @Test("start tags: names lowercased, prefixes dropped, attributes decoded")
    func startTags() {
        #expect(tokens("<P CLASS='a b' ID=x data-k=\"1&amp;2\" hidden>") == [
            start("p", ["class": "a b", "id": "x", "data-k": "1&2", "hidden": ""]),
        ])
        #expect(tokens("<epub:switch/><svg:image xlink:href=\"c.jpg\" XLINK:Title = 't' />") == [
            start("switch", selfClosing: true),
            start("image", ["xlink:href": "c.jpg", "xlink:title": "t"], selfClosing: true),
        ])
        // The first of duplicate attributes wins; a quoted value may contain ">".
        #expect(tokens("<a href=\"x>y\" href=\"z\">") == [start("a", ["href": "x>y"])])
    }

    @Test("end tags and text")
    func endTagsAndText() {
        #expect(tokens("<p>a &lt; b</P ><br/>") == [
            start("p"), .text("a < b"), .end(name: "p"), start("br", selfClosing: true),
        ])
        #expect(HTMLTokenizer.isVoid(name: "br", selfClosing: false))
        #expect(HTMLTokenizer.isVoid(name: "div", selfClosing: true))
        #expect(!HTMLTokenizer.isVoid(name: "div", selfClosing: false))
        for name in ["br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source", "track", "wbr", "param"] {
            #expect(HTMLTokenizer.voidElements.contains(name))
        }
    }

    @Test("comments, doctype and processing instructions are skipped; CDATA becomes text")
    func skippedMarkup() {
        let html = "<?xml version=\"1.0\"?><!DOCTYPE html><!-- c --><p>a<!--x-->b<![CDATA[<z> &amp;]]></p><?pi >?>"
        #expect(tokens(html) == [
            start("p"), .text("a"), .text("b"), .text("<z> &amp;"), .end(name: "p"),
        ])
    }

    @Test("script and style content is raw text up to the matching end tag")
    func rawText() {
        #expect(tokens("<script>if (a<b && c>d) {}</script><STYLE>p>b{}</style>x") == [
            start("script"), .text("if (a<b && c>d) {}"), .end(name: "script"),
            start("style"), .text("p>b{}"), .end(name: "style"), .text("x"),
        ])
        #expect(tokens("<script/>after") == [start("script", selfClosing: true), .text("after")])
        #expect(tokens("<script>never closed <p>") == [start("script"), .text("never closed <p>")])
    }

    @Test("sloppy input: stray angle brackets stay text, unterminated tags are dropped")
    func sloppy() {
        // "</>" is dropped, which splits the surrounding text in two.
        #expect(tokens("a < b <3 c </ d </>e") == [.text("a < b <3 c </ d "), .text("e")])
        #expect(tokens("<p>x<a href=\"y") == [start("p"), .text("x")])
        #expect(tokens("<p>x</p") == [start("p"), .text("x"), .end(name: "p")])
        #expect(tokens("<!-- never closed <p>").isEmpty)
        #expect(tokens("").isEmpty)
        #expect(tokens("plain") == [.text("plain")])
        #expect(tokens("<p a=\"unterminated>text</p>") == [start("p", ["a": "unterminated"]), .text("text"), .end(name: "p")])
    }

    // MARK: Entities

    @Test("numeric references")
    func numericReferences() {
        #expect(HTMLEntities.decode("&#65;&#x41;&#X1f600;&#8217;") == "AA\u{1F600}\u{2019}")
        #expect(HTMLEntities.decode("&#65") == "A")  // no semicolon
        #expect(HTMLEntities.decode("&#0;&#xD800;&#1114112;&#99999999999999;") == "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}")
        #expect(HTMLEntities.decode("&#150;&#146;&#128;") == "\u{2013}\u{2019}\u{20AC}")  // Windows-1252
        #expect(HTMLEntities.decode("&#;&#x;&#xZ;") == "&#;&#x;&#xZ;")
    }

    @Test("the five XML entities and the HTML 4 set")
    func namedReferences() {
        #expect(HTMLEntities.decode("&amp;&lt;&gt;&quot;&apos;") == "&<>\"'")
        let samples: [(String, String)] = [
            ("nbsp", "\u{A0}"), ("iexcl", "\u{A1}"), ("cent", "\u{A2}"), ("copy", "\u{A9}"), ("laquo", "\u{AB}"),
            ("yuml", "\u{FF}"), ("OElig", "\u{152}"), ("fnof", "\u{192}"), ("Alpha", "\u{391}"),
            ("omega", "\u{3C9}"), ("thetasym", "\u{3D1}"), ("bull", "\u{2022}"), ("hellip", "\u{2026}"),
            ("prime", "\u{2032}"), ("ndash", "\u{2013}"), ("mdash", "\u{2014}"), ("lsquo", "\u{2018}"),
            ("rsquo", "\u{2019}"), ("sbquo", "\u{201A}"), ("ldquo", "\u{201C}"), ("rdquo", "\u{201D}"),
            ("bdquo", "\u{201E}"), ("dagger", "\u{2020}"), ("Dagger", "\u{2021}"), ("permil", "\u{2030}"),
            ("lsaquo", "\u{2039}"), ("rsaquo", "\u{203A}"), ("euro", "\u{20AC}"), ("trade", "\u{2122}"),
            ("larr", "\u{2190}"), ("rarr", "\u{2192}"), ("hearts", "\u{2665}"), ("diams", "\u{2666}"),
            ("forall", "\u{2200}"), ("infin", "\u{221E}"), ("lang", "\u{2329}"), ("loz", "\u{25CA}"),
            ("emsp", "\u{2003}"), ("zwj", "\u{200D}"), ("thinsp", "\u{2009}"),
        ]
        for (name, expected) in samples {
            #expect(HTMLEntities.decode("&\(name);") == expected, "&\(name);")
        }
        // The complete HTML 4.01 table: 252 entities plus apos.
        #expect(HTMLEntities.named.count == 253)
        #expect(HTMLEntities.named["nbsp"] == 0xA0)
        #expect(HTMLEntities.named["yuml"] == 0xFF)
    }

    @Test("unknown, malformed and case-mismatched references pass through literally")
    func passthrough() {
        #expect(HTMLEntities.decode("&bogus; &amp &AMP; &Eacute;x &; & a&b") == "&bogus; &amp &AMP; \u{C9}x &; & a&b")
        #expect(HTMLEntities.decode("AT&T; ?a=1&b=2") == "AT&T; ?a=1&b=2")
        #expect(HTMLEntities.decode("no references") == "no references")
        #expect(HTMLEntities.decode("trailing &") == "trailing &")
    }
}
