import Foundation
import Testing

import SheafsKit

private let uuid = "6F1C2B0E-3A4D-4E5F-8A9B-0C1D2E3F4A5B"
private let other = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
private let added = Date(timeIntervalSince1970: 1_800_000_000)

private func entry(id: String = "urn:uuid:\(uuid)",
                   href: String = "https://books.example.org/opds/books/\(uuid)/file/New%20Title.epub",
                   updated: Date? = nil) -> OPDSEntry {
    guard let url = URL(string: href) else { preconditionFailure("bad URL in test: \(href)") }
    return OPDSEntry(id: id, title: "New Title", updated: updated,
                     links: [OPDSLink(rel: "http://opds-spec.org/acquisition", type: "application/epub+zip", href: url)])
}

private func copy(entryID: String? = nil, sourceURL: String?, updated: Date? = nil) -> CatalogCopy {
    CatalogCopy(entryID: entryID, sourceURL: sourceURL, updated: updated, addedAt: added)
}

@Suite("Catalog copies: finding a downloaded book's entry and whether it changed")
struct CatalogCopyTests {
    @Test("the entry id is the identity, whatever the URL says now")
    func byEntryID() {
        let renamed = copy(entryID: "urn:uuid:\(uuid)",
                           sourceURL: "https://books.example.org/opds/books/\(uuid)/file/Old%20Title.epub")
        #expect(entry().matches(renamed))
        // Same id on another server is another book.
        let elsewhere = copy(entryID: "urn:uuid:\(uuid)", sourceURL: "https://other.example.net/get/1.epub")
        #expect(!entry().matches(elsewhere))
        // A recorded id that differs is never overruled by a matching URL.
        let differentID = copy(entryID: "urn:uuid:\(other)",
                               sourceURL: "https://books.example.org/opds/books/\(uuid)/file/New%20Title.epub")
        #expect(!entry().matches(differentID))
        // A numbered id is fine within its own host.
        let numbered = entry(id: "42", href: "https://books.example.org/get/42/book.epub")
        #expect(numbered.matches(copy(entryID: "42", sourceURL: "https://books.example.org/get/42/book.epub")))
        #expect(!numbered.matches(copy(entryID: "42", sourceURL: "https://other.example.net/get/42/book.epub")))
    }

    @Test("a copy from before the id was kept matches by URL")
    func byURL() {
        let href = "https://books.example.org/opds/books/\(uuid)/file/New%20Title.epub"
        #expect(entry().matches(copy(sourceURL: href)))
        let numbered = entry(id: "tag:example,2024:book-7", href: "https://books.example.org/fetch?id=7")
        #expect(numbered.matches(copy(sourceURL: "https://books.example.org/fetch?id=7")))
        #expect(!numbered.matches(copy(sourceURL: "https://books.example.org/fetch?id=8")))
        #expect(!entry().matches(copy(sourceURL: nil)))
    }

    @Test("a renamed file is still found through the entry's UUID in both paths")
    func byUUIDInPath() {
        let old = copy(sourceURL: "https://books.example.org/opds/books/\(uuid.lowercased())/file/Weird%20Name.epub")
        #expect(entry().matches(old))
        // Another book in the same folder is not this one.
        #expect(!entry().matches(copy(sourceURL: "https://books.example.org/opds/books/\(other)/file/New%20Title.epub")))
        // The UUID must be a whole segment, on the same host.
        #expect(!entry().matches(copy(sourceURL: "https://books.example.org/opds/books/x\(uuid)/file/a.epub")))
        #expect(!entry().matches(copy(sourceURL: "https://mirror.example.net/opds/books/\(uuid)/file/a.epub")))
        // Without a urn:uuid id, a renamed file is a different URL and nothing more.
        let plain = entry(id: "https://books.example.org/ebooks/a/b",
                          href: "https://books.example.org/ebooks/a/b/downloads/new.epub")
        #expect(!plain.matches(copy(sourceURL: "https://books.example.org/ebooks/a/b/downloads/old.epub")))
        // Nor when the entry's own URL doesn't carry its UUID.
        let elsewhere = entry(href: "https://books.example.org/get/epub/9")
        #expect(!elsewhere.matches(copy(sourceURL: "https://books.example.org/opds/books/\(uuid)/file/a.epub")))
    }

    @Test("an entry with no EPUB link matches nothing")
    func noEPUB() {
        let navigation = OPDSEntry(id: "urn:uuid:\(uuid)", title: "Shelf")
        #expect(!navigation.matches(copy(entryID: "urn:uuid:\(uuid)", sourceURL: nil)))
    }

    @Test("urn:uuid ids, any case; other ids have none")
    func uuidIDs() {
        #expect(entry().uuidID == uuid.lowercased())
        #expect(entry(id: "URN:UUID:\(uuid.lowercased())").uuidID == uuid.lowercased())
        #expect(entry(id: "urn:uuid:not-a-uuid").uuidID == nil)
        #expect(entry(id: "https://example.org/\(uuid)").uuidID == nil)
    }

    @Test("newer means the entry's updated is past what the copy recorded")
    func newer() {
        let then = Date(timeIntervalSince1970: 1_800_100_000)
        let recorded = copy(entryID: "urn:uuid:\(uuid)", sourceURL: nil, updated: then)
        #expect(!entry(updated: then).isNewer(than: recorded))
        #expect(!entry(updated: then.addingTimeInterval(0.5)).isNewer(than: recorded), "sub-second jitter")
        #expect(entry(updated: then.addingTimeInterval(60)).isNewer(than: recorded))
        #expect(!entry(updated: then.addingTimeInterval(-60)).isNewer(than: recorded))
        #expect(!entry(updated: nil).isNewer(than: recorded), "no date, no claim")
        // A copy that never recorded one is measured from when it was added.
        let legacy = copy(sourceURL: nil)
        #expect(entry(updated: added.addingTimeInterval(3600)).isNewer(than: legacy))
        #expect(!entry(updated: added.addingTimeInterval(-3600)).isNewer(than: legacy))
    }
}

@Suite("CatalogShelf")
struct CatalogShelfTests {
    @Test("finds each entry's copy by id, URL or UUID, and nothing else's")
    func lookups() {
        let shelf = CatalogShelf([
            ("tied", copy(entryID: "urn:uuid:\(other)", sourceURL: "https://books.example.org/opds/books/\(other)/file/A.epub")),
            ("legacy", copy(sourceURL: "https://books.example.org/opds/books/\(uuid)/file/Old.epub")),
            ("plain", copy(sourceURL: "https://books.example.org/fetch?id=7")),
            ("files", copy(sourceURL: nil)),
        ]) { $0.1 }
        #expect(shelf.item(for: entry())?.item.0 == "legacy")
        let renamedTied = entry(id: "urn:uuid:\(other)", href: "https://books.example.org/opds/books/\(other)/file/B.epub")
        #expect(shelf.item(for: renamedTied)?.item.0 == "tied")
        let plain = entry(id: "tag:example,2024:book-7", href: "https://books.example.org/fetch?id=7")
        #expect(shelf.item(for: plain)?.item.0 == "plain")
        let stranger = entry(id: "urn:uuid:\(UUID().uuidString)", href: "https://books.example.org/fetch?id=9")
        #expect(shelf.item(for: stranger) == nil)
    }

    @Test("a copy tied to the entry wins over one that only shares its URL")
    func preference() {
        let href = "https://books.example.org/opds/books/\(uuid)/file/New%20Title.epub"
        let shelf = CatalogShelf([
            ("by url", copy(sourceURL: href)),
            ("by id", copy(entryID: "urn:uuid:\(uuid)", sourceURL: "https://books.example.org/opds/books/\(uuid)/file/Old.epub")),
        ]) { $0.1 }
        #expect(shelf.item(for: entry())?.item.0 == "by id")
    }
}
