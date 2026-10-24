import Foundation
import Testing

import SheafsKit

private func link(_ rel: String?, _ type: String? = nil, _ href: String = "https://example.com/x") -> OPDSLink {
    guard let url = URL(string: href) else { preconditionFailure("bad URL in test: \(href)") }
    return OPDSLink(rel: rel, type: type, href: url)
}

@Suite("OPDSLink and OPDSEntry")
struct OPDSModelsTests {
    @Test(
        "acquisition relations and their kinds",
        arguments: [
            ("http://opds-spec.org/acquisition", OPDSAcquisitionKind.generic),
            ("http://opds-spec.org/acquisition/open-access", .openAccess),
            ("http://opds-spec.org/acquisition/borrow", .borrow),
            ("http://opds-spec.org/acquisition/buy", .buy),
            ("http://opds-spec.org/acquisition/sample", .sample),
            ("http://opds-spec.org/acquisition/subscribe", .subscribe),
            ("HTTP://OPDS-SPEC.ORG/Acquisition/Open-Access", .openAccess),
        ]
    )
    func acquisitionKinds(rel: String, kind: OPDSAcquisitionKind) {
        let candidate = link(rel)
        #expect(candidate.isAcquisition)
        #expect(candidate.acquisitionKind == kind)
        #expect(!candidate.isNavigation && !candidate.isImage && !candidate.isThumbnail)
    }

    @Test("other relations are not acquisitions", arguments: [nil, "alternate", "self", "http://opds-spec.org/image", "subsection"])
    func notAcquisition(rel: String?) {
        #expect(!link(rel).isAcquisition)
        #expect(link(rel).acquisitionKind == nil)
    }

    @Test(
        "EPUB detection ignores case and parameters",
        arguments: [
            ("application/epub+zip", true),
            ("Application/EPUB+zip", true),
            ("application/epub+zip; charset=binary", true),
            ("  application/epub+zip ;x=y", true),
            ("application/pdf", false),
            ("application/x-mobipocket-ebook", false),
            ("application/epub", false),
            ("", false),
        ] as [(String, Bool)]
    )
    func epubDetection(type: String, expected: Bool) {
        #expect(link("http://opds-spec.org/acquisition", type).isEPUB == expected)
    }

    @Test("a missing type is not an EPUB and has no media type")
    func noType() {
        let untyped = link("http://opds-spec.org/acquisition")
        #expect(!untyped.isEPUB)
        #expect(untyped.mediaType == nil)
        #expect(link("x", "Image/PNG;q=1").mediaType == "image/png")
    }

    @Test("image and thumbnail relations are distinct")
    func images() {
        #expect(link("http://opds-spec.org/image").isImage)
        #expect(!link("http://opds-spec.org/image").isThumbnail)
        #expect(link("http://opds-spec.org/image/thumbnail").isThumbnail)
        #expect(!link("http://opds-spec.org/image/thumbnail").isImage)
        #expect(link("x-stanza-cover-image").isImage)
        #expect(link("x-stanza-cover-image-thumbnail").isThumbnail)
        #expect(!link("http://opds-spec.org/acquisition").isImage)
    }

    @Test(
        "which links lead to another feed",
        arguments: [
            ("subsection", "application/atom+xml;profile=opds-catalog;kind=navigation", true),
            ("subsection", "application/atom+xml;profile=opds-catalog;kind=acquisition", true),
            ("subsection", nil, true),
            ("collection", nil, true),
            ("start", "application/atom+xml;profile=opds-catalog", true),
            ("http://opds-spec.org/sort/popular", "application/atom+xml;profile=opds-catalog;kind=acquisition", true),
            ("http://opds-spec.org/featured", nil, true),
            (nil, "application/atom+xml;profile=opds-catalog", true),
            (nil, "application/atom+xml", true),
            ("related", "application/atom+xml;profile=opds-catalog", true),
            ("self", "application/atom+xml", false),
            ("alternate", "text/html", false),
            ("alternate", "application/atom+xml;type=entry;profile=opds-catalog", false),
            ("search", "application/atom+xml;profile=opds-catalog", false),
            ("http://opds-spec.org/acquisition", "application/atom+xml;profile=opds-catalog", false),
            ("http://opds-spec.org/image", "image/jpeg", false),
            (nil, nil, false),
            (nil, "text/html", false),
        ] as [(String?, String?, Bool)]
    )
    func navigation(rel: String?, type: String?, expected: Bool) {
        #expect(link(rel, type).isNavigation == expected)
    }

    @Test("rel values are matched whole words, ignoring case")
    func relWords() {
        let feed = OPDSFeed(title: "t", links: [
            link("SELF", "application/atom+xml;profile=opds-catalog;kind=acquisition", "https://example.com/self"),
            link("Next", nil, "https://example.com/next"),
            link("previous prev", nil, "https://example.com/prev"),
            link("start", nil, "https://example.com/start"),
            link("research", nil, "https://example.com/research"),
        ])
        #expect(feed.nextURL?.absoluteString == "https://example.com/next")
        #expect(feed.previousURL?.absoluteString == "https://example.com/prev")
        #expect(feed.startURL?.absoluteString == "https://example.com/start")
        #expect(feed.searchLink == nil, "\"research\" is not \"search\"")
        #expect(feed.kind == .acquisition)
    }

    @Test("an entry picks its EPUB, thumbnail and navigation link")
    func entryAccessors() {
        let entry = OPDSEntry(
            id: "e", title: "T",
            links: [
                link("http://opds-spec.org/image", "image/png", "https://example.com/cover.png"),
                link("http://opds-spec.org/acquisition/buy", "application/pdf", "https://example.com/book.pdf"),
                link("http://opds-spec.org/acquisition/open-access", "application/epub+zip", "https://example.com/book.epub"),
                link("http://opds-spec.org/acquisition/open-access", "application/epub+zip", "https://example.com/second.epub"),
            ]
        )
        #expect(entry.acquisitionLinks.count == 3)
        #expect(entry.epubLink?.href.absoluteString == "https://example.com/book.epub")
        #expect(entry.thumbnailURL?.absoluteString == "https://example.com/cover.png", "falls back to the cover image")
        #expect(!entry.isNavigation)

        var withThumbnail = entry
        withThumbnail.links.append(link("http://opds-spec.org/image/thumbnail", "image/png", "https://example.com/thumb.png"))
        #expect(withThumbnail.thumbnailURL?.absoluteString == "https://example.com/thumb.png")

        let pdfOnly = OPDSEntry(id: "p", title: "P", links: [link("http://opds-spec.org/acquisition", "application/pdf")])
        #expect(pdfOnly.epubLink == nil)
        #expect(pdfOnly.acquisitionLinks.count == 1)
    }

    @Test("a section entry exposes its first feed link")
    func sectionEntry() {
        let section = OPDSEntry(
            id: "s", title: "Authors",
            links: [
                link("alternate", "text/html", "https://example.com/web"),
                link("subsection", "application/atom+xml;profile=opds-catalog", "https://example.com/authors"),
                link("subsection", "application/atom+xml;profile=opds-catalog", "https://example.com/other"),
            ]
        )
        #expect(section.isNavigation)
        #expect(section.navigationLink?.href.absoluteString == "https://example.com/authors")
        #expect(section.epubLink == nil && section.thumbnailURL == nil)
    }

    @Test("errors describe themselves for a person")
    func errorDescriptions() throws {
        let target = try #require(URL(string: "https://example.com/opds"))
        let samples: [OPDSError] = [
            .notAFeed, .malformed("line 3"), .httpStatus(503, url: target), .unauthorized(url: target),
            .notEPUB(contentType: "text/html"), .notEPUB(contentType: nil), .network(underlying: URLError(.timedOut)),
        ]
        for sample in samples { #expect(!sample.description.isEmpty) }
        #expect(OPDSError.httpStatus(503, url: target).description.contains("503"))
        #expect(OPDSError.notEPUB(contentType: "text/html").description.contains("text/html"))
        #expect(OPDSError.malformed("line 3").description.contains("line 3"))
    }
}
