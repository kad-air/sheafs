import Foundation
import Testing

import SheafsKit

extension OPDSError {
    /// A short name for the case, so failures read clearly in test output.
    var kind: String {
        switch self {
        case .notAFeed: "notAFeed"
        case .malformed: "malformed"
        case .httpStatus(let status, _): "httpStatus(\(status))"
        case .unauthorized: "unauthorized"
        case .notEPUB: "notEPUB"
        case .network: "network"
        }
    }
}

private func url(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("bad URL in test: \(string)") }
    return url
}

private let catalogBase = url("https://catalog.example.com/opds/REDACTED_KEY/v1.2/books?page=1")

private func parse(_ xml: String, base: URL = url("https://example.com/opds/shelf/index.xml")) throws -> OPDSFeed {
    try OPDSParser.parseFeed(Data(xml.utf8), baseURL: base)
}

/// An Atom feed wrapping `entries`, with a handful of fixed header elements.
private func feedXML(_ body: String, attributes: String = "") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" \(attributes)>
    <id>urn:uuid:feed</id><title>Test Feed</title>
    \(body)
    </feed>
    """
}

private func entryXML(_ body: String) -> String {
    "<entry><id>urn:uuid:entry</id><title>Entry</title>\(body)</entry>"
}

private func epoch(_ date: Date?) -> Double? { date?.timeIntervalSince1970 }

@Suite("OPDSParser: the fixture feed")
struct OPDSFixtureParserTests {
    private func parseFixture() throws -> OPDSFeed {
        try OPDSParser.parseFeed(SyncFixture.data("opds-feed.xml"), baseURL: catalogBase)
    }

    private func resolved(_ href: String?) -> URL? {
        href.flatMap { URL(string: $0, relativeTo: catalogBase)?.absoluteURL }
    }

    @Test("every fact in the independent reference matches")
    func matchesReference() throws {
        let facts = try SyncReference.load().opds
        let feed = try parseFixture()

        #expect(feed.title == facts.feedTitle)
        #expect(feed.entries.count == facts.entryCount)
        #expect(feed.entries.count == 13)
        #expect(feed.entries.map(\.title) == facts.entries.map(\.title))
        #expect(feed.entries.map(\.id) == facts.entries.map(\.id))
        let feedUpdated = try #require(epoch(feed.updated))
        #expect(abs(feedUpdated - facts.feedUpdatedEpoch) < 0.001)

        for (entry, expected) in zip(feed.entries, facts.entries) {
            #expect(entry.epubLink?.href == resolved(expected.epubHref), "epub of \(expected.title)")
            #expect(entry.thumbnailURL == resolved(expected.thumbnailHref), "thumbnail of \(expected.title)")
            let updated = epoch(entry.updated) ?? .nan
            #expect(abs(updated - expected.updatedEpoch) < 0.001, "updated of \(expected.title)")
        }

        #expect(facts.hasNext == (feed.nextURL != nil))
        #expect(feed.nextURL == resolved(facts.nextHref))
        #expect(facts.hasPrevious == (feed.previousURL != nil))
        #expect(feed.previousURL == resolved(facts.previousHref))
        #expect(feed.startURL == resolved(facts.startHref))
        #expect(feed.searchLink?.href == resolved(facts.searchHref))
        #expect(feed.searchLink?.type == facts.searchType)
    }

    @Test("the first entry's links are the absolute URLs the server meant")
    func absoluteLiterals() throws {
        let feed = try parseFixture()
        let first = try #require(feed.entries.first)
        #expect(
            first.epubLink?.href.absoluteString
                == "https://catalog.example.com/opds/REDACTED_KEY/v1.2/books/8d290ec1-5166-4b88-93e1-e62d1263499e/file/01%20-%20Call%20for%20the%20Dead.epub"
        )
        #expect(
            first.thumbnailURL?.absoluteString
                == "https://catalog.example.com/opds/REDACTED_KEY/v1.2/books/8d290ec1-5166-4b88-93e1-e62d1263499e/thumbnail"
        )
        #expect(feed.previousURL?.absoluteString == "https://catalog.example.com/opds/REDACTED_KEY/v1.2/books?page=0")
        #expect(feed.startURL?.absoluteString == "https://catalog.example.com/opds/REDACTED_KEY/v1.2/catalog")
        #expect(feed.nextURL == nil)
    }

    @Test("all links are absolute and none was dropped")
    func linksAreAbsolute() throws {
        let feed = try parseFixture()
        #expect(feed.links.count == 3)
        for link in feed.links + feed.entries.flatMap(\.links) {
            #expect(link.href.scheme == "https", "\(link.href)")
            #expect(link.href.host == "catalog.example.com", "\(link.href)")
        }
        for entry in feed.entries {
            // thumbnail, cover, EPUB and a page-streaming link (whose template braces get encoded)
            #expect(entry.links.count == 4, "\(entry.title)")
            #expect(entry.acquisitionLinks.count == 1)
            #expect(entry.acquisitionLinks.first?.acquisitionKind == .generic)
            #expect(entry.epubLink != nil)
            #expect(!entry.isNavigation)
        }
    }

    @Test("the feed is an acquisition feed even though its self link claims kind=navigation")
    func kindIsAcquisition() throws {
        let feed = try parseFixture()
        #expect(feed.links.first { $0.rel == "self" }?.type?.contains("kind=navigation") == true)
        #expect(feed.kind == .acquisition)
        #expect(feed.id == "allBooks")
    }

    @Test("titles lose their embedded line breaks and authors are kept as the server wrote them")
    func titlesAndAuthors() throws {
        let feed = try parseFixture()
        #expect(feed.entries[0].title == "Call for the Dead A George Smiley Novel")
        #expect(feed.entries[0].authors == ["John le Carré"])
        #expect(feed.entries[2].authors == ["J.R.R. Tolkien;"])
    }

    @Test("html summaries become plain text")
    func summariesArePlain() throws {
        let feed = try parseFixture()
        let summary = try #require(feed.entries[0].summary)
        #expect(summary.hasPrefix("From the New York Times bestselling author of A Legacy of Spies."))
        #expect(summary.contains("John le Carré's new novel, Agent Running in the Field, is coming October 2019."))
        #expect(summary.contains("no one's idea of a spy—which is perhaps why"))
        for entry in feed.entries {
            let text = entry.summary ?? ""
            #expect(!text.contains("<") && !text.contains(">"), "tags left in \(entry.title)")
            #expect(!text.contains("&"), "entities left in \(entry.title)")
        }
        // No <summary>, only <content type="html">0.8 MiB - epub</content>.
        #expect(feed.entries[1].summary == "0.8 MiB - epub")
    }

    @Test("the redacted catalog key never appears in a title or summary")
    func noKeyInText() throws {
        for entry in try parseFixture().entries {
            #expect(!entry.title.contains("REDACTED"))
            #expect(!(entry.summary ?? "").contains("REDACTED"))
        }
    }
}

@Suite("OPDSParser: hand-written feeds")
struct OPDSParserTests {
    // MARK: - URL resolution

    @Test("relative hrefs resolve against the base URL")
    func relativeAgainstBase() throws {
        let feed = try parse(feedXML("""
            <link rel="self" type="application/atom+xml;profile=opds-catalog;kind=acquisition" href="catalog.xml"/>
            <link rel="next" type="application/atom+xml;profile=opds-catalog" href="?page=2"/>
            \(entryXML("""
            <link rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip" href="books/1.epub"/>
            <link rel="http://opds-spec.org/image/thumbnail" type="image/png" href="../img/1t.png"/>
            <link rel="http://opds-spec.org/image" type="image/png" href="/abs/1.png"/>
            """))
            """))
        let entry = try #require(feed.entries.first)
        #expect(entry.epubLink?.href.absoluteString == "https://example.com/opds/shelf/books/1.epub")
        #expect(entry.thumbnailURL?.absoluteString == "https://example.com/opds/img/1t.png")
        #expect(entry.links.last?.href.absoluteString == "https://example.com/abs/1.png")
        #expect(feed.nextURL?.absoluteString == "https://example.com/opds/shelf/index.xml?page=2")
    }

    @Test("xml:base on the feed wins over the request URL, and may itself be relative")
    func xmlBase() throws {
        let link = #"<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="books/1.epub"/>"#
        let absolute = try parse(feedXML(entryXML(link), attributes: #"xml:base="https://cdn.example.com/lib/""#))
        #expect(absolute.entries.first?.epubLink?.href.absoluteString == "https://cdn.example.com/lib/books/1.epub")

        let relative = try parse(feedXML(entryXML(link), attributes: #"xml:base="sub/""#))
        #expect(relative.entries.first?.epubLink?.href.absoluteString == "https://example.com/opds/shelf/sub/books/1.epub")
    }

    @Test("a link without a usable href is skipped, not fatal")
    func linkWithoutHref() throws {
        let feed = try parse(feedXML(entryXML("""
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip"/>
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href=""/>
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="ok.epub"/>
            """)))
        #expect(feed.entries.first?.links.count == 1)
    }

    // MARK: - Kinds and navigation

    @Test("a navigation feed has navigation entries with links to other feeds")
    func navigationFeed() throws {
        let feed = try parse(feedXML("""
            <updated>2024-05-01T10:00:00Z</updated>
            <link rel="self" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
            <link rel="start" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
            <entry><id>nav:new</id><title>New books</title>
              <content type="text">Newest first</content>
              <link rel="http://opds-spec.org/sort/new" href="/opds/new"
                    type="application/atom+xml;profile=opds-catalog;kind=acquisition"/></entry>
            <entry><id>nav:authors</id><title>Authors</title>
              <link rel="subsection" href="authors" type="application/atom+xml;profile=opds-catalog;kind=navigation"/></entry>
            <entry><id>nav:plain</id><title>Series</title>
              <link href="/opds/series" type="application/atom+xml"/></entry>
            """))
        #expect(feed.kind == .navigation)
        #expect(feed.entries.count == 3)
        #expect(feed.entries.allSatisfy { $0.isNavigation })
        #expect(feed.entries.allSatisfy { $0.epubLink == nil && $0.acquisitionLinks.isEmpty })
        #expect(feed.entries.map { $0.navigationLink?.href.absoluteString } == [
            "https://example.com/opds/new",
            "https://example.com/opds/shelf/authors",
            "https://example.com/opds/series",
        ])
        #expect(feed.startURL?.absoluteString == "https://example.com/opds")
        #expect(feed.entries[0].summary == "Newest first")
        #expect(epoch(feed.updated) == 1_714_557_600)
    }

    @Test("an entry that offers a book is not navigation even if it also links to a feed")
    func acquisitionBeatsNavigation() throws {
        let feed = try parse(feedXML(entryXML("""
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="b.epub"/>
            <link rel="subsection" href="more" type="application/atom+xml;profile=opds-catalog"/>
            """)))
        let entry = try #require(feed.entries.first)
        #expect(!entry.isNavigation)
        #expect(entry.navigationLink == nil)
    }

    @Test("a link to a single entry document is not a feed link")
    func entryDocumentLink() throws {
        let feed = try parse(feedXML(entryXML("""
            <link rel="alternate" href="full" type="application/atom+xml;type=entry;profile=opds-catalog"/>
            """)))
        #expect(feed.entries.first?.isNavigation == false)
    }

    @Test("feed kind: acquisition entries win, else the self link's kind, else navigation")
    func kindRules() throws {
        let selfAcquisition = #"<link rel="self" href="/f" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>"#
        let selfNavigation = #"<link rel="self" href="/f" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>"#
        let book = entryXML(#"<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="b.epub"/>"#)
        let section = entryXML(#"<link rel="subsection" href="s" type="application/atom+xml;profile=opds-catalog"/>"#)

        #expect(try parse(feedXML(selfAcquisition)).kind == .acquisition, "an empty result page keeps its declared kind")
        #expect(try parse(feedXML(selfNavigation)).kind == .navigation)
        #expect(try parse(feedXML("")).kind == .navigation)
        #expect(try parse(feedXML(selfNavigation + book)).kind == .acquisition)
        #expect(try parse(feedXML(selfAcquisition + section)).kind == .acquisition)
        #expect(try parse(feedXML(section)).kind == .navigation)
    }

    // MARK: - Pagination

    @Test("both previous and prev are accepted, next is next")
    func pagination() throws {
        let previous = try parse(feedXML(#"<link rel="previous" href="p1"/><link rel="next" href="p3"/>"#))
        #expect(previous.previousURL?.absoluteString == "https://example.com/opds/shelf/p1")
        #expect(previous.nextURL?.absoluteString == "https://example.com/opds/shelf/p3")

        let prev = try parse(feedXML(#"<link rel="prev" href="p1"/>"#))
        #expect(prev.previousURL?.absoluteString == "https://example.com/opds/shelf/p1")
        #expect(prev.nextURL == nil)

        let none = try parse(feedXML(""))
        #expect(none.previousURL == nil && none.nextURL == nil && none.startURL == nil && none.searchLink == nil)
    }

    // MARK: - Metadata

    @Test("authors, language, categories, dates and ids are collected")
    func metadata() throws {
        let feed = try parse(feedXML("""
            <entry>
              <id>urn:uuid:0b4f2c1e-0000-4000-8000-000000000001</id>
              <title>  A   Title
                 Split  </title>
              <author><name>First Author</name><uri>https://example.com/a</uri></author>
              <author><name> Second  Author </name></author>
              <dc:language>en-GB</dc:language>
              <dc:issued>2008-05-01</dc:issued>
              <updated>2024-05-01T10:00:00Z</updated>
              <category term="sci-fi" label="Science Fiction"/>
              <category term="classic"/>
              <category label=""/>
            </entry>
            """))
        let entry = try #require(feed.entries.first)
        #expect(entry.id == "urn:uuid:0b4f2c1e-0000-4000-8000-000000000001")
        #expect(entry.title == "A Title Split")
        #expect(entry.authors == ["First Author", "Second Author"])
        #expect(entry.language == "en-GB")
        #expect(entry.categories == ["Science Fiction", "classic"])
        #expect(epoch(entry.published) == 1_209_600_000, "dc:issued stands in for a missing <published>")
        #expect(epoch(entry.updated) == 1_714_557_600)
        #expect(entry.summary == nil)
    }

    @Test("<published> wins over dc:issued, and dc:creator stands in for missing authors")
    func publishedAndCreator() throws {
        let feed = try parse(feedXML("""
            <entry><id>x</id><title>T</title>
              <published>2024-05-01T10:00:00Z</published><dc:issued>2008-05-01</dc:issued>
              <dc:creator>Creator Name</dc:creator>
              <dc:title>Not The Title</dc:title></entry>
            """))
        let entry = try #require(feed.entries.first)
        #expect(epoch(entry.published) == 1_714_557_600)
        #expect(entry.authors == ["Creator Name"])
        #expect(entry.title == "T", "an extension element named title must not replace Atom's")
    }

    @Test("an entry without an id falls back to its first link")
    func missingID() throws {
        let feed = try parse(feedXML(#"<entry><title>T</title><link rel="x" href="/where"/></entry>"#))
        #expect(feed.entries.first?.id == "https://example.com/where")
    }

    @Test(
        "RFC 3339 timestamps parse with and without fractions, offsets, or a time",
        arguments: [
            ("2024-05-01T10:00:00Z", 1_714_557_600.0),
            ("2024-05-01T10:00:00.250Z", 1_714_557_600.25),
            ("2024-05-01T10:00:00.123456+00:00", 1_714_557_600.123456),
            ("2024-05-01T12:00:00+02:00", 1_714_557_600.0),
            ("2024-05-01T05:30:00-04:30", 1_714_557_600.0),
            ("2024-05-01t10:00:00z", 1_714_557_600.0),
            ("2024-05-01 10:00:00 +00:00", 1_714_557_600.0),
            ("2024-05-01", 1_714_521_600.0),
            ("2008", 1_199_145_600.0),
        ]
    )
    func dates(text: String, expected: Double) throws {
        let feed = try parse(feedXML("<updated>\(text)</updated>"))
        let parsed = try #require(epoch(feed.updated), "\(text) should parse")
        #expect(abs(parsed - expected) < 0.000_01)
    }

    @Test("nonsense dates leave the date nil instead of failing the feed", arguments: ["", "yesterday", "2024-13-01T00:00:00Z", "2024-05-01T25:00:00Z", "2024-05-01T10:00"])
    func badDates(text: String) throws {
        let feed = try parse(feedXML("<updated>\(text)</updated>"))
        // "2024-05-01T10:00" is a valid local time without seconds; everything else is rejected.
        if text == "2024-05-01T10:00" {
            #expect(epoch(feed.updated) == 1_714_557_600)
        } else {
            #expect(feed.updated == nil)
        }
    }

    // MARK: - Summaries

    @Test("html content is stripped to text with entities decoded, paragraphs separated by a blank line")
    func htmlSummary() throws {
        let feed = try parse(feedXML(entryXML("""
            <summary type="html">&lt;p&gt;Hello &lt;b&gt;bold&lt;/b&gt; &amp;amp; &amp;eacute;&amp;#8212;x &amp;#x41;&amp;nbsp;B &amp;bogus;&lt;/p&gt;&lt;p&gt;Second&lt;br/&gt;line&lt;/p&gt;</summary>
            """)))
        #expect(feed.entries.first?.summary == "Hello bold & é—x A B &bogus;\n\nSecond\nline")
    }

    @Test("xhtml content is flattened to text with paragraph breaks")
    func xhtmlSummary() throws {
        let feed = try parse(feedXML(entryXML("""
            <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>One <em>two</em></p><p>Three &amp; four</p></div></content>
            """)))
        #expect(feed.entries.first?.summary == "One two\n\nThree & four")
    }

    @Test("a CDATA summary is read like any other, and a literal less-than survives")
    func cdataAndLessThan() throws {
        let cdata = try parse(feedXML(entryXML("<summary><![CDATA[<p>cdata <i>text</i></p>]]></summary>")))
        #expect(cdata.entries.first?.summary == "cdata text")

        let text = try parse(feedXML(entryXML(#"<summary type="text">a &lt; b and 2 &lt;3 and c &gt; d</summary>"#)))
        #expect(text.entries.first?.summary == "a < b and 2 <3 and c > d")
    }

    @Test("summary is preferred over content, and an empty summary falls back to content")
    func summaryOrder() throws {
        let both = try parse(feedXML(entryXML("<content>Content</content><summary>Summary</summary>")))
        #expect(both.entries.first?.summary == "Summary")
        let empty = try parse(feedXML(entryXML("<summary>   </summary><content>Content</content>")))
        #expect(empty.entries.first?.summary == "Content")
    }

    // MARK: - Search

    @Test("a search link is either an OpenSearch description or a {searchTerms} template")
    func searchLinks() throws {
        let description = try parse(feedXML(#"<link rel="search" href="/os.xml" type="application/opensearchdescription+xml"/>"#))
        let link = try #require(description.searchLink)
        #expect(link.isOpenSearchDescription && !link.isSearchTemplate)
        #expect(link.href.absoluteString == "https://example.com/os.xml")

        let direct = try parse(feedXML(#"<link rel="search" href="/s?q={searchTerms}" type="application/atom+xml"/>"#))
        let template = try #require(direct.searchLink)
        #expect(template.isSearchTemplate && !template.isOpenSearchDescription)
        let expanded = OPDSParser.searchURL(template: template.href.absoluteString, query: "dune messiah")
        #expect(expanded?.absoluteString == "https://example.com/s?q=dune%20messiah")

        let useless = try parse(feedXML(#"<link rel="search" href="/s" type="text/html"/>"#))
        #expect(useless.searchLink == nil)
        let notSearch = try parse(feedXML(#"<link rel="alternate" href="/os.xml" type="application/opensearchdescription+xml"/>"#))
        #expect(notSearch.searchLink == nil)
    }

    private static let openSearchDescription = """
        <?xml version="1.0" encoding="UTF-8"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>Library</ShortName>
          <Url type="text/html" template="/web/search?q={searchTerms}"/>
          <Url type="application/atom+xml" template="/opds/search?q={searchTerms}&amp;page={startPage?}"/>
          <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="/opds/acq?query={searchTerms}"/>
        </OpenSearchDescription>
        """

    @Test("the OpenSearch template prefers kind=acquisition, then any Atom type, then the first URL")
    func openSearchTemplateChoice() throws {
        let base = url("https://example.com/opds/os.xml")
        func template(_ xml: String) throws -> String {
            try OPDSParser.parseOpenSearchTemplate(Data(xml.utf8), baseURL: base)
        }
        #expect(try template(Self.openSearchDescription) == "https://example.com/opds/acq?query={searchTerms}")

        let atomOnly = """
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="text/html" template="/web?q={searchTerms}"/>
              <Url type="application/atom+xml" template="/opds?q={searchTerms}"/>
            </OpenSearchDescription>
            """
        #expect(try template(atomOnly) == "https://example.com/opds?q={searchTerms}")

        let htmlOnly = """
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="text/html" template="https://other.example.org/web?q={searchTerms}"/>
            </OpenSearchDescription>
            """
        #expect(try template(htmlOnly) == "https://other.example.org/web?q={searchTerms}")
    }

    @Test("a relative OpenSearch template resolves against the description's URL, keeping its braces")
    func openSearchTemplateResolution() throws {
        let xml = #"<OpenSearchDescription><Url type="application/atom+xml" template="search/{searchTerms}?lang={language?}"/></OpenSearchDescription>"#
        let template = try OPDSParser.parseOpenSearchTemplate(Data(xml.utf8), baseURL: url("https://example.com/opds/os.xml"))
        #expect(template == "https://example.com/opds/search/{searchTerms}?lang={language?}")
    }

    @Test("bad OpenSearch descriptions are malformed")
    func openSearchErrors() {
        let base = url("https://example.com/")
        for xml in ["<feed xmlns=\"http://www.w3.org/2005/Atom\"/>", "<OpenSearchDescription/>", "nope", ""] {
            do {
                _ = try OPDSParser.parseOpenSearchTemplate(Data(xml.utf8), baseURL: base)
                Issue.record("expected an error for \(xml.debugDescription)")
            } catch let error as OPDSError {
                #expect(error.kind == "malformed", "\(xml.debugDescription)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test(
        "search URL templates expand with a percent-encoded query",
        arguments: [
            ("https://example.com/s?q={searchTerms}", "dune & sand", "https://example.com/s?q=dune%20%26%20sand"),
            ("https://example.com/s?q={searchTerms?}", "a b", "https://example.com/s?q=a%20b"),
            ("https://example.com/s?q={searchTerms}&page={startPage?}&n={count}", "x", "https://example.com/s?q=x"),
            ("https://example.com/s?page={startPage?}&q={searchTerms}", "x", "https://example.com/s?q=x"),
            ("https://example.com/s?q={searchTerms}&lang=en", "x", "https://example.com/s?q=x&lang=en"),
            ("https://example.com/s/{searchTerms}", "a/b c", "https://example.com/s/a%2Fb%20c"),
            ("https://example.com/s/{searchTerms}?page={startPage?}", "x", "https://example.com/s/x"),
            ("https://example.com/s?q=%7BsearchTerms%7D", "a b", "https://example.com/s?q=a%20b"),
            ("https://example.com/s?q=%7bsearchTerms%7d&p=%7BstartPage?%7D", "x", "https://example.com/s?q=x"),
            ("https://example.com/s?q={searchTerms}", "café ☕", "https://example.com/s?q=caf%C3%A9%20%E2%98%95"),
            ("https://example.com/s?q={searchTerms}", "100% +1 =2 #3", "https://example.com/s?q=100%25%20%2B1%20%3D2%20%233"),
            ("https://example.com/s?q={searchTerms}", "", "https://example.com/s?q="),
        ]
    )
    func searchURLs(template: String, query: String, expected: String) {
        #expect(OPDSParser.searchURL(template: template, query: query)?.absoluteString == expected)
    }

    // MARK: - Failures

    @Test("garbage is malformed")
    func garbage() {
        let samples: [Data] = [
            Data(),
            Data("this is not xml".utf8),
            Data([0xFF, 0xFE, 0x00, 0x13, 0x37]),
            Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><title>cut off".utf8),
            Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>x</wrong></feed>".utf8),
        ]
        for (index, sample) in samples.enumerated() {
            do {
                _ = try OPDSParser.parseFeed(sample, baseURL: url("https://example.com/"))
                Issue.record("sample \(index) should not parse")
            } catch let error as OPDSError {
                #expect(error.kind == "malformed", "sample \(index): \(error)")
            } catch {
                Issue.record("sample \(index): unexpected error \(error)")
            }
        }
    }

    @Test("well-formed XML that is not a feed is notAFeed")
    func notAFeed() {
        let samples = [
            "<html><body><p>Please log in</p></body></html>",
            #"<rss version="2.0"><channel><title>x</title></channel></rss>"#,
            #"<entry xmlns="http://www.w3.org/2005/Atom"><id>x</id><title>y</title></entry>"#,
            #"<feed xmlns="http://example.com/not-atom"><title>y</title></feed>"#,
        ]
        for sample in samples {
            do {
                _ = try OPDSParser.parseFeed(Data(sample.utf8), baseURL: url("https://example.com/"))
                Issue.record("\(sample) should not parse")
            } catch let error as OPDSError {
                #expect(error.kind == "notAFeed", "\(sample): \(error)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test("a feed whose Atom elements use a namespace prefix parses the same")
    func prefixedAtom() throws {
        let feed = try parse("""
            <a:feed xmlns:a="http://www.w3.org/2005/Atom"><a:id>x</a:id><a:title>Prefixed</a:title>
            <a:entry><a:id>e</a:id><a:title>Book</a:title><a:author><a:name>Au Thor</a:name></a:author>
            <a:link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="b.epub"/></a:entry></a:feed>
            """)
        #expect(feed.title == "Prefixed")
        #expect(feed.entries.first?.authors == ["Au Thor"])
        #expect(feed.entries.first?.epubLink?.href.absoluteString == "https://example.com/opds/shelf/b.epub")
    }
}
