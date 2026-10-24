import Testing
@testable import SheafsKit

@Suite("EPUBPath")
struct EPUBPathTests {
    @Test func resolvesParentReferencesAgainstTheContainingFile() {
        #expect(EPUBPath.resolve("../Images/a.png", relativeTo: "OEBPS/Text/ch1.xhtml") == "OEBPS/Images/a.png")
        #expect(EPUBPath.resolve("../../a.png", relativeTo: "OEBPS/Text/ch1.xhtml") == "a.png")
        #expect(EPUBPath.resolve("sub/b.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/sub/b.xhtml")
        #expect(EPUBPath.resolve("./b.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/b.xhtml")
        #expect(EPUBPath.resolve("a/./b/../c.css", relativeTo: "OEBPS/content.opf") == "OEBPS/a/c.css")
        #expect(EPUBPath.resolve("a//b.css", relativeTo: "OEBPS/content.opf") == "OEBPS/a/b.css")
    }

    @Test func baseFileInTheArchiveRootHasNoDirectory() {
        #expect(EPUBPath.resolve("ch1.xhtml", relativeTo: "content.opf") == "ch1.xhtml")
        #expect(EPUBPath.resolve("Text/ch1.xhtml", relativeTo: "content.opf") == "Text/ch1.xhtml")
        #expect(EPUBPath.resolve("ch1.xhtml", relativeTo: "") == "ch1.xhtml")
    }

    @Test func parentReferencesNeverClimbAboveTheRoot() {
        #expect(EPUBPath.resolve("../../../../x.png", relativeTo: "OEBPS/Text/ch1.xhtml") == "x.png")
        #expect(EPUBPath.resolve("../x.png", relativeTo: "content.opf") == "x.png")
    }

    @Test func decodesPercentEscapes() {
        #expect(EPUBPath.resolve("ch%201.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/ch 1.xhtml")
        #expect(EPUBPath.resolve("Text/caf%C3%A9.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/Text/café.xhtml")
        #expect(EPUBPath.resolve("a%2Fb.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/a/b.xhtml")
        // A literal "%" that is not an escape stays as it is.
        #expect(EPUBPath.resolve("100%.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/100%.xhtml")
        // %23 is a "#" in the file name, not a fragment separator.
        #expect(EPUBPath.resolve("C%23.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/C#.xhtml")
    }

    @Test func fragmentOnlyHrefMeansTheSameDocument() {
        #expect(EPUBPath.resolve("#frag", relativeTo: "OEBPS/Text/ch1.xhtml") == "OEBPS/Text/ch1.xhtml")
        #expect(EPUBPath.resolve("", relativeTo: "OEBPS/Text/ch1.xhtml") == "OEBPS/Text/ch1.xhtml")
        #expect(EPUBPath.resolve("#frag", relativeTo: "./OEBPS//Text/ch1.xhtml") == "OEBPS/Text/ch1.xhtml")
    }

    @Test func fragmentsAndQueriesAreDroppedFromThePath() {
        #expect(EPUBPath.resolve("ch2.xhtml#sec-3", relativeTo: "OEBPS/Text/ch1.xhtml") == "OEBPS/Text/ch2.xhtml")
        #expect(EPUBPath.resolve("ch2.xhtml?v=2#x", relativeTo: "OEBPS/Text/ch1.xhtml") == "OEBPS/Text/ch2.xhtml")
    }

    @Test func absoluteFromRootFormsAreRootRelative() {
        #expect(EPUBPath.resolve("/OEBPS/a.css", relativeTo: "OEBPS/Text/ch1.xhtml") == "OEBPS/a.css")
        #expect(EPUBPath.resolve("/a.css", relativeTo: "OEBPS/Text/ch1.xhtml") == "a.css")
        #expect(EPUBPath.resolve("/../a.css", relativeTo: "OEBPS/Text/ch1.xhtml") == "a.css")
    }

    @Test func externalHrefsAreRecognisedAndReturnedUntouched() {
        for href in ["http://example.com/a", "https://example.com/a#b", "mailto:someone@example.com", "data:image/png;base64,AAAA", "urn:isbn:123"] {
            #expect(EPUBPath.isExternal(href), "\(href)")
            #expect(EPUBPath.resolve(href, relativeTo: "OEBPS/Text/ch1.xhtml") == href)
        }
        for href in ["ch1.xhtml", "../a.png", "#top", "/abs/path", "", "a b.xhtml", ":odd", "1http://x"] {
            #expect(!EPUBPath.isExternal(href), "\(href)")
        }
    }

    @Test func splitsAtTheFirstHash() {
        let plain = EPUBPath.split("ch1.xhtml")
        #expect(plain.path == "ch1.xhtml" && plain.fragment == nil)

        let withFragment = EPUBPath.split("Text/ch1.xhtml#sec-2")
        #expect(withFragment.path == "Text/ch1.xhtml" && withFragment.fragment == "sec-2")

        let onlyFragment = EPUBPath.split("#top")
        #expect(onlyFragment.path == "" && onlyFragment.fragment == "top")

        let doubleHash = EPUBPath.split("a.xhtml#b#c")
        #expect(doubleHash.path == "a.xhtml" && doubleHash.fragment == "b#c")

        // Nothing is decoded, and an empty fragment is no fragment.
        let encoded = EPUBPath.split("a%20b.xhtml#x%20y")
        #expect(encoded.path == "a%20b.xhtml" && encoded.fragment == "x%20y")
        let empty = EPUBPath.split("a.xhtml#")
        #expect(empty.path == "a.xhtml" && empty.fragment == nil)
    }
}
