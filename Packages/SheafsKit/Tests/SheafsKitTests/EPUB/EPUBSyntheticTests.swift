import Foundation
import Testing
@testable import SheafsKit

/// Small hand-built EPUBs for the cases the three fixtures do not exercise: nested tables of
/// contents, HTML entities in XHTML, EPUB 3 series metadata, odd covers, error paths.
@Suite("EPUB parsing, synthetic books")
struct EPUBSyntheticTests {
    private static let opfHead = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        """

    private func book(opf: String, opfPath: String = "OEBPS/content.opf",
                      files: [(String, String)] = []) throws -> EPUBBook {
        try EPUBBook(data: TestZipBuilder.epub(opf: opf, opfPath: opfPath, files: files))
    }

    // MARK: Table of contents

    private static let navDocument = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body>
        <nav epub:type="landmarks"><ol><li><a epub:type="cover" href="cover.xhtml">Cover</a></li></ol></nav>
        <nav epub:type="toc" id="toc"><h1>Contents</h1>
          <ol>
            <li><a href="ch1.xhtml">One&nbsp;&mdash; Beginnings</a></li>
            <li><span>Part Two</span>
              <ol>
                <li><a href="ch2.xhtml#start">Two <i>(a)</i></a>
                  <ol><li><a href="../Other/ch%203.xhtml#frag%20x">Three &amp; Co&hellip; AT&T &bogus;</a></li></ol>
                </li>
                <li><a href="https://example.com/elsewhere">External</a></li>
              </ol>
            </li>
            <li><a href="#top">Self</a></li>
            <li><a href="ch9.xhtml"> </a></li>
          </ol>
        </nav>
        </body></html>
        """

    @Test func nestedNavigationDocumentWithHTMLEntities() throws {
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>
              <item id="nav" href="Text/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              <item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c1"/></spine></package>
            """
        let epub = try book(opf: opf, files: [("OEBPS/Text/nav.xhtml", Self.navDocument), ("OEBPS/Text/ch1.xhtml", "<p/>")])

        let flat = epub.flattenedTOC.map { ($0.depth, $0.title, $0.path, $0.fragment) }
        #expect(flat.count == 6)
        #expect(flat[0] == (0, "One \u{2014} Beginnings", "OEBPS/Text/ch1.xhtml", nil))
        #expect(flat[1] == (0, "Part Two", nil, nil))
        #expect(flat[2] == (1, "Two (a)", "OEBPS/Text/ch2.xhtml", "start"))
        #expect(flat[3] == (2, "Three & Co\u{2026} AT&T &bogus;", "OEBPS/Other/ch 3.xhtml", "frag x"))
        #expect(flat[4] == (1, "External", nil, nil))
        #expect(flat[5] == (0, "Self", "OEBPS/Text/nav.xhtml", "top"))   // the untitled last entry is dropped

        #expect(epub.flattenedTOC.map(\.id) == Array(0 ..< 6))
        #expect(epub.toc.count == 3)
        #expect(epub.toc[1].children.map(\.title) == ["Two (a)", "External"])
        #expect(epub.toc[1].children[0].children.map(\.title) == ["Three & Co\u{2026} AT&T &bogus;"])
    }

    @Test func ncxIsUsedWhenThereIsNoNavDocumentAndNestsNavPoints() throws {
        let ncx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <navMap>
                <navPoint id="a" playOrder="1"><navLabel><text>  Part
                  One </text></navLabel><content src="Text/p1.xhtml"/>
                  <navPoint id="a1" playOrder="2"><navLabel><text>Chapter 1</text></navLabel><content src="Text/c%201.xhtml#top"/></navPoint>
                  <navPoint id="a2" playOrder="3"><navLabel><text>Chapter 2</text></navLabel><content src="Text/c2.xhtml"/></navPoint>
                </navPoint>
                <navPoint id="b" playOrder="4"><navLabel><text>Epilogue</text></navLabel><content src="Text/e.xhtml"/></navPoint>
              </navMap>
            </ncx>
            """
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>
              <item id="a-ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
              <item id="p1" href="Text/p1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine toc="a-ncx"><itemref idref="p1"/></spine></package>
            """
        let epub = try book(opf: opf, files: [("OEBPS/toc.ncx", ncx)])

        let flat = epub.flattenedTOC
        #expect(flat.map(\.title) == ["Part One", "Chapter 1", "Chapter 2", "Epilogue"])
        #expect(flat.map(\.depth) == [0, 1, 1, 0])
        #expect(flat.map(\.id) == [0, 1, 2, 3])
        #expect(flat.map(\.path) == ["OEBPS/Text/p1.xhtml", "OEBPS/Text/c 1.xhtml", "OEBPS/Text/c2.xhtml", "OEBPS/Text/e.xhtml"])
        #expect(flat.map(\.fragment) == [nil, "top", nil, nil])
        #expect(epub.toc.count == 2)
        #expect(epub.toc[0].children.count == 2)
    }

    @Test func brokenNavDocumentFallsBackToTheNCX() throws {
        let ncx = """
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
              <navPoint><navLabel><text>From NCX</text></navLabel><content src="c.xhtml"/></navPoint>
            </navMap></ncx>
            """
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>
              <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            </manifest>
            <spine><itemref idref="nav"/></spine></package>
            """
        // Not well-formed: the <li> is never closed.
        let brokenNav = #"<html><body><nav epub:type="toc"><ol><li><a href="c.xhtml">Broken</a></ol></nav></body></html>"#
        let epub = try book(opf: opf, files: [("OEBPS/nav.xhtml", brokenNav), ("OEBPS/toc.ncx", ncx)])
        #expect(epub.flattenedTOC.map(\.title) == ["From NCX"])
    }

    @Test func navWithOnlyLandmarksFallsBackToTheNCX() throws {
        let nav = """
            <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="landmarks"><ol><li><a href="c.xhtml">Start</a></li></ol></nav>
            </body></html>
            """
        let ncx = """
            <ncx><navMap><navPoint><navLabel><text>Real TOC</text></navLabel><content src="c.xhtml"/></navPoint></navMap></ncx>
            """
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>
              <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            </manifest>
            <spine><itemref idref="nav"/></spine></package>
            """
        let epub = try book(opf: opf, files: [("OEBPS/nav.xhtml", nav), ("OEBPS/toc.ncx", ncx)])
        #expect(epub.flattenedTOC.map(\.title) == ["Real TOC"])
    }

    @Test func untypedNavIsUsedAndEmptyTitlesLiftTheirChildren() throws {
        let nav = """
            <html><body><nav><ol>
              <li><a href="a.xhtml">A</a></li>
              <li><a href="skip.xhtml"></a><ol><li><a href="b.xhtml">B</a></li></ol></li>
            </ol></nav></body></html>
            """
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>
            <spine><itemref idref="nav"/></spine></package>
            """
        let epub = try book(opf: opf, files: [("OEBPS/nav.xhtml", nav)])
        #expect(epub.toc.map(\.title) == ["A", "B"])
        #expect(epub.toc.map(\.depth) == [0, 0])
    }

    // MARK: Metadata

    @Test func epub3MetadataWithRefinementsAndSeries() throws {
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
              <dc:identifier id="other">urn:other</dc:identifier>
              <dc:identifier id="bookid">urn:uuid:abc-123</dc:identifier>
              <dc:title id="t1">  A   Tale\n   of Things </dc:title>
              <dc:title id="t2">The Subtitle</dc:title>
              <meta refines="#t1" property="title-type">main</meta>
              <meta refines="#t2" property="title-type">subtitle</meta>
              <dc:creator id="c1" opf:file-as="Doe, Jane">Jane Doe</dc:creator>
              <dc:creator id="c2">  John   Roe </dc:creator>
              <dc:language>en-GB</dc:language>
              <dc:publisher>Small Press</dc:publisher>
              <dc:description>&lt;div&gt;&lt;p&gt;Tom &amp;amp; Jerry&lt;/p&gt;&lt;p&gt;Second&amp;nbsp;line&lt;/p&gt;&lt;/div&gt;</dc:description>
              <dc:date>2020-05-04</dc:date>
              <meta property="dcterms:modified">2021-01-02T03:04:05Z</meta>
              <meta property="belongs-to-collection" id="set1">Not A Series</meta>
              <meta refines="#set1" property="collection-type">set</meta>
              <meta property="belongs-to-collection" id="ser1">The Big Series</meta>
              <meta refines="#ser1" property="collection-type">series</meta>
              <meta refines="#ser1" property="group-position">2.5</meta>
            </metadata>
            <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c"/></spine></package>
            """
        let metadata = try book(opf: opf).metadata
        #expect(metadata.title == "A Tale of Things")
        #expect(metadata.authors == ["Jane Doe", "John Roe"])
        #expect(metadata.language == "en-GB")
        #expect(metadata.identifier == "urn:uuid:abc-123")
        #expect(metadata.publisher == "Small Press")
        #expect(metadata.description == "Tom & Jerry Second line")
        #expect(metadata.published == "2020-05-04")
        #expect(metadata.modified == "2021-01-02T03:04:05Z")
        #expect(metadata.series == "The Big Series")
        #expect(metadata.seriesIndex == 2.5)
    }

    @Test func calibreSeriesAndHTMLDescriptionAsChildElements() throws {
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:identifier id="bookid">id-1</dc:identifier>
              <dc:title>Calibre Book</dc:title>
              <dc:description><p xmlns="http://www.w3.org/1999/xhtml">Real <b>child</b> elements</p></dc:description>
              <meta name="calibre:series" content=" Some   Series "/>
              <meta name="calibre:series_index" content="1.50"/>
            </metadata>
            <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c"/></spine></package>
            """
        let metadata = try book(opf: opf).metadata
        #expect(metadata.series == "Some Series")
        #expect(metadata.seriesIndex == 1.5)
        #expect(metadata.description == "Real child elements")
        #expect(metadata.language == nil)
        #expect(metadata.publisher == nil)
        #expect(metadata.authors.isEmpty)
    }

    @Test func prefixedPackageElementsAndMissingMetadataFields() throws {
        let opf = """
            <?xml version="1.0"?>
            <opf:package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="uid">
              <opf:metadata>
                <dc:title>Prefixed</dc:title>
                <dc:identifier id="uid" opf:scheme="UUID">uuid-1</dc:identifier>
                <opf:meta name="cover" content="img"/>
              </opf:metadata>
              <opf:manifest>
                <opf:item id="img" href="pic.jpg" media-type="image/jpeg"/>
                <opf:item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
              </opf:manifest>
              <opf:spine><opf:itemref idref="c"/></opf:spine>
            </opf:package>
            """
        let epub = try book(opf: opf)
        #expect(epub.version == "2.0")
        #expect(epub.metadata.title == "Prefixed")
        #expect(epub.metadata.identifier == "uuid-1")
        #expect(epub.coverItem?.path == "OEBPS/pic.jpg")
        #expect(epub.spine.map(\.idref) == ["c"])
        #expect(epub.toc.isEmpty)
    }

    @Test func opfWithStrayHTMLEntitiesStillOpens() throws {
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:title>Fish&nbsp;&amp;&nbsp;Chips</dc:title>
            </metadata>
            <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c"/></spine></package>
            """
        #expect(try book(opf: opf).metadata.title == "Fish & Chips")
    }

    // MARK: Manifest, spine, paths

    @Test func manifestPathsAreResolvedDecodedAndNormalized() throws {
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>
              <item id="c1" href="Text/ch%201.xhtml" media-type="application/xhtml+xml"/>
              <item id="c2" href="./Text/../Text/ch2.xhtml" media-type="application/xhtml+xml" properties="  scripted   svg "/>
              <item id="css" href="../Shared/style.css" media-type="text/css"/>
              <item id="remote" href="https://example.com/font.woff" media-type="font/woff"/>
              <item id="c1" href="Text/duplicate.xhtml" media-type="application/xhtml+xml"/>
              <item href="Text/no-id.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
              <itemref idref="c1"/>
              <itemref idref="c2" linear="no"/>
              <itemref idref="ghost"/>
              <itemref idref="remote"/>
            </spine></package>
            """
        let epub = try book(opf: opf, files: [("OEBPS/Text/ch 1.xhtml", "one"), ("OEBPS/Text/ch2.xhtml", "two")])

        #expect(epub.manifest["c1"]?.path == "OEBPS/Text/ch 1.xhtml")
        #expect(epub.manifest["c2"]?.path == "OEBPS/Text/ch2.xhtml")
        #expect(epub.manifest["c2"]?.properties == ["scripted", "svg"])
        #expect(epub.manifest["css"]?.path == "Shared/style.css")
        #expect(epub.manifest["remote"] == nil)
        #expect(epub.manifest.count == 3)

        // Unknown and remote idrefs are dropped; non-linear items stay, flagged.
        #expect(epub.spine.map(\.idref) == ["c1", "c2"])
        #expect(epub.spine.map(\.linear) == [true, false])

        #expect(epub.spineIndex(forPath: "OEBPS/Text/ch 1.xhtml") == 0)
        #expect(epub.spineIndex(forPath: "OEBPS/Text/ch2.xhtml") == 1)
        #expect(epub.spineIndex(forPath: "OEBPS/Text/CH2.xhtml") == nil)
        #expect(String(decoding: try epub.data(for: #require(epub.manifest["c1"])), as: UTF8.self) == "one")
        #expect(String(decoding: try epub.data(at: "OEBPS/Text/ch%201.xhtml"), as: UTF8.self) == "one")   // percent-encoded form
        #expect(String(decoding: try epub.data(at: "OEBPS/Text/ch2.xhtml"), as: UTF8.self) == "two")
        #expect(String(decoding: try epub.data(forManifestID: "c2"), as: UTF8.self) == "two")
    }

    @Test func packageDocumentAtTheArchiveRoot() throws {
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Flat</dc:title></metadata>
            <manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c"/></spine></package>
            """
        let epub = try book(opf: opf, opfPath: "package.opf", files: [("chapter.xhtml", "<p/>")])
        #expect(epub.opfPath == "package.opf")
        #expect(epub.spine.first?.item.path == "chapter.xhtml")
        #expect(epub.spineIndex(forPath: "chapter.xhtml") == 0)
    }

    // MARK: Cover

    @Test func coverPropertyBeatsMetaAndMustBeAnImage() throws {
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title><meta name="cover" content="other"/></metadata>
            <manifest>
              <item id="other" href="other.jpg" media-type="image/jpeg"/>
              <item id="wrongtype" href="notimage.xhtml" media-type="application/xhtml+xml" properties="cover-image"/>
              <item id="real" href="images/front.png" media-type="image/png" properties="cover-image"/>
            </manifest>
            <spine><itemref idref="wrongtype"/></spine></package>
            """
        #expect(try book(opf: opf).coverItem?.id == "real")
    }

    @Test func coverNamedByAnXHTMLPageResolvesTheImageItShows() throws {
        let page = """
            <?xml version="1.0"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover&nbsp;page</title></head>
            <body><p>&nbsp;</p><div><img src="../Images/front%20cover.jpg" alt=""/></div></body></html>
            """
        let opf = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title><meta name="cover" content="coverpage"/></metadata>
            <manifest>
              <item id="coverpage" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
              <item id="decoy" href="Images/decoy.jpg" media-type="image/jpeg"/>
              <item id="front" href="Images/front%20cover.jpg" media-type="image/jpeg"/>
            </manifest>
            <spine><itemref idref="coverpage"/></spine></package>
            """
        let epub = try book(opf: opf, files: [("OEBPS/Text/cover.xhtml", page), ("OEBPS/Images/front cover.jpg", "jpeg bytes")])
        #expect(epub.coverItem?.id == "front")
        #expect(String(decoding: try #require(try epub.coverImageData()), as: UTF8.self) == "jpeg bytes")
    }

    @Test func coverFallsBackToAnImageNamedCoverAndCanBeAbsent() throws {
        let named = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>
              <item id="i1" href="Images/page1.png" media-type="image/png"/>
              <item id="i2" href="Images/Cover.PNG" media-type="image/png"/>
              <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c"/></spine></package>
            """
        #expect(try book(opf: named).coverItem?.id == "i2")

        let none = Self.opfHead + """
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
            <manifest>
              <item id="i1" href="Images/page1.png" media-type="image/png"/>
              <item id="cover-text" href="cover.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="cover-text"/></spine></package>
            """
        let epub = try book(opf: none)
        #expect(epub.coverItem == nil)
        #expect(try epub.coverImageData() == nil)
    }

    // MARK: Errors

    @Test func missingContainerRootfileAndOPFAreReported() throws {
        var noContainer = TestZipBuilder()
        noContainer.add("mimetype", "application/epub+zip")
        #expect(throws: EPUBError.missingContainer) { try EPUBBook(data: noContainer.build()) }

        let emptyContainer = TestZipBuilder.epub(opf: "", container: "<container><rootfiles/></container>")
        #expect(throws: EPUBError.missingRootfile) { try EPUBBook(data: emptyContainer) }

        var noOPF = TestZipBuilder()
        noOPF.add("META-INF/container.xml", """
            <container><rootfiles><rootfile full-path="OEBPS/gone.opf"/></rootfiles></container>
            """)
        #expect(throws: EPUBError.missingOPF("OEBPS/gone.opf")) { try EPUBBook(data: noOPF.build()) }
    }

    @Test func malformedPackageDocumentsAreReported() throws {
        func malformed(_ opf: String) -> Bool {
            do {
                _ = try EPUBBook(data: TestZipBuilder.epub(opf: opf))
                return false
            } catch EPUBError.malformedOPF {
                return true
            } catch {
                return false
            }
        }
        #expect(malformed("this is not xml <<<"))
        #expect(malformed("<html><body/></html>"))
        #expect(malformed(Self.opfHead + "<metadata/><spine/></package>"))
        #expect(malformed(Self.opfHead + "<metadata/><manifest/></package>"))
    }

    @Test func nonZipDataAndUnknownManifestIDsThrowTypedErrors() throws {
        #expect(throws: ZipError.notAZipFile) { try EPUBBook(data: Data("plain text".utf8)) }

        let opf = Self.opfHead + """
            <metadata/><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c"/></spine></package>
            """
        let epub = try book(opf: opf, files: [("OEBPS/c.xhtml", "x")])
        #expect(throws: EPUBError.missingManifestItem("nope")) { try epub.data(forManifestID: "nope") }
        #expect(throws: ZipError.entryNotFound("OEBPS/nope.xhtml")) { try epub.data(at: "OEBPS/nope.xhtml") }
        #expect(epub.metadata.title == "")
    }

    @Test func errorsDescribeThemselves() {
        #expect(EPUBError.missingOPF("a/b.opf").description.contains("a/b.opf"))
        #expect(EPUBError.malformedOPF("no spine").description.contains("no spine"))
        #expect(EPUBError.missingManifestItem("zz").description.contains("zz"))
        #expect(!EPUBError.missingContainer.description.isEmpty)
        #expect(!EPUBError.missingRootfile.description.isEmpty)
    }
}

/// The HTML entity table and the XHTML clean-up that lets Foundation's strict parser read
/// navigation documents.
@Suite("XHTMLEntities")
struct XHTMLEntitiesTests {
    @Test func tableCoversAllOfHTML4() {
        #expect(XHTMLEntities.html4.count == 252)
        let expected: [String: UInt32] = [
            "nbsp": 0xA0, "iexcl": 0xA1, "copy": 0xA9, "eacute": 0xE9, "yuml": 0xFF, "times": 0xD7, "divide": 0xF7,
            "OElig": 0x152, "fnof": 0x192, "circ": 0x2C6, "Alpha": 0x391, "Omega": 0x3A9, "alpha": 0x3B1, "omega": 0x3C9,
            "ensp": 0x2002, "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019, "ldquo": 0x201C,
            "rdquo": 0x201D, "bull": 0x2022, "hellip": 0x2026, "euro": 0x20AC, "trade": 0x2122, "rarr": 0x2192,
            "infin": 0x221E, "hearts": 0x2665, "quot": 0x22, "amp": 0x26, "lt": 0x3C, "gt": 0x3E,
        ]
        for (name, code) in expected {
            #expect(XHTMLEntities.html4[name]?.unicodeScalars.first?.value == code, "&\(name);")
        }
    }

    @Test func sanitizingHandlesDoctypeEntitiesAndBareAmpersands() throws {
        let input = """
            <?xml version="1.0" encoding="iso-8859-1"?>
            <!DOCTYPE html [ <!ENTITY local "x"> ]>
            <p a="&copy; 1">&nbsp;&amp;&lt;&#233;&#xE9;&unknown; AT&T &</p>
            """
        let cleaned = String(decoding: XHTMLEntities.sanitizeXHTML(Data(input.utf8)), as: UTF8.self)
        #expect(!cleaned.contains("DOCTYPE"))
        #expect(!cleaned.contains("<?xml"))
        let root = try #require(XMLTreeNode.parse(Data(input.utf8), mode: .xhtml))
        #expect(root.name == "p")
        #expect(root.attribute("a") == "\u{A9} 1")
        #expect(root.textContent == "\u{A0}&<\u{E9}\u{E9}&unknown; AT&T &")
    }

    @Test func plainTextStripsMarkupAndDecodesReferences() {
        #expect(XHTMLEntities.plainText(fromHTML: "<p>One</p><p>Two &amp; <b>three</b></p>") == "One Two & three")
        #expect(XHTMLEntities.plainText(fromHTML: "a &lt; b &#33; &#x41; &nope;") == "a < b ! A &nope;")
        #expect(XHTMLEntities.plainText(fromHTML: "I <3 you") == "I <3 you")
        #expect(XHTMLEntities.collapseWhitespace("  a \n\t b\u{A0}c  ") == "a b c")
    }
}
