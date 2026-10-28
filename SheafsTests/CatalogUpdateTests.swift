import Testing
import Foundation
import SwiftData
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// A catalog changed a book's file after it was downloaded (here: the server's editor gave Alice
/// a new cover and title, chapters untouched; `alice-epub3-edited.epub`). Update swaps the file in
/// under the SAME book, so the place, highlights and bookmarks stay, and the sync key follows the
/// new bytes.
struct CatalogUpdateTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle(for: BundleMarker.self).url(forResource: name, withExtension: "epub"))
    }

    @Test func updateKeepsTheBookAndEverythingOnIt() async throws {
        let store = LibraryStore(inMemory: true)
        let book = try await store.importBook(from: try Self.fixture("alice-epub3"))
        defer { store.delete(book) }
        let id = book.id
        let oldKey = try #require(book.partialMD5)
        let pointer = "/body/DocFragment[4]/body/p[12]/text()[1].5"
        book.spineIndex = 3
        book.textOffset = 1234
        book.xpointer = pointer
        book.progress = 0.25
        store.add(Bookmark(bookID: id, spineIndex: 3, textOffset: 1234, label: "here"))
        store.add(Annotation(bookID: id, spineIndex: 3, startOffset: 1300, endOffset: 1320, text: "curiouser",
                             color: .yellow))
        #expect(book.hasCover)
        let oldCover = try Data(contentsOf: store.coverURL(for: book))

        let outcome = try await store.replaceFile(of: book, with: try Self.fixture("alice-epub3-edited"))
        #expect(outcome == .replaced)
        #expect(book.id == id)
        #expect(book.title == "Alice in Wonderland (Edited)")
        let newKey = try #require(book.partialMD5)
        #expect(newKey != oldKey)
        #expect(newKey == (try PartialMD5.digest(fileAt: store.fileURL(for: book))), "the key is the file's")
        #expect(book.spineIndex == 3 && book.textOffset == 1234 && book.xpointer == pointer && book.progress == 0.25)
        #expect(store.bookmarks(for: book).map(\.label) == ["here"])
        #expect(store.annotations(for: book).map(\.text) == ["curiouser"])
        #expect(book.hasCover)
        #expect(try Data(contentsOf: store.coverURL(for: book)) != oldCover, "the new cover replaced the thumbnail")
        #expect(try store.context.fetch(FetchDescriptor<Book>()).count == 1, "no second book")
        let incoming = store.booksDirectory.appending(path: "\(id.uuidString).incoming.epub")
        #expect(!FileManager.default.fileExists(atPath: incoming.path(percentEncoded: false)))

        // The chapters are the same bytes, so the place opens on the same text.
        let session = BookSession(book: book, fileURL: store.fileURL(for: book))
        await session.load()
        #expect(session.isReady)

        // The same file again: nothing to swap.
        #expect(try await store.replaceFile(of: book, with: try Self.fixture("alice-epub3-edited")) == .unchanged)
        #expect(book.partialMD5 == newKey)
    }

    @Test func refusesAFileThatIsAnotherBook() async throws {
        let store = LibraryStore(inMemory: true)
        let alice = try await store.importBook(from: try Self.fixture("alice-epub3"))
        let edited = try await store.importBook(from: try Self.fixture("alice-epub3-edited"))
        defer {
            store.delete(alice)
            store.delete(edited)
        }
        #expect(alice.id != edited.id)
        let key = alice.partialMD5
        await #expect(throws: LibraryStore.ReplaceError.self) {
            try await store.replaceFile(of: alice, with: try Self.fixture("alice-epub3-edited"))
        }
        #expect(alice.partialMD5 == key)
        #expect(alice.title != edited.title)
    }

    /// A book downloaded before Sheafs kept the entry id, whose file the server since renamed:
    /// found through the UUID in both links, offered an update, and tied to the entry by it.
    @Test func rememberTiesARenamedLegacyCopyToItsEntry() throws {
        let store = LibraryStore(inMemory: true)
        let uuid = UUID().uuidString.lowercased()
        let book = Book(title: "Weird Name", author: nil, language: nil, fileSize: 1, partialMD5: "aaaa", hasCover: false,
                        sourceURL: "https://books.example.org/opds/books/\(uuid)/file/Weird%20Name.epub")
        let unrelated = Book(title: "Other", author: nil, language: nil, fileSize: 1, partialMD5: "bbbb", hasCover: false,
                             sourceURL: "https://elsewhere.example.net/get/1.epub")
        unrelated.sourceEntryID = "urn:example:other"
        store.context.insert(book)
        store.context.insert(unrelated)
        defer {
            store.delete(book)
            store.delete(unrelated)
        }
        let href = try #require(URL(string: "https://books.example.org/opds/books/\(uuid)/file/Better%20Name.epub"))
        let entry = OPDSEntry(id: "urn:uuid:\(uuid)", title: "Better Name", updated: book.addedAt.addingTimeInterval(3600),
                              links: [OPDSLink(rel: "http://opds-spec.org/acquisition", type: "application/epub+zip", href: href)])

        let shelf = CatalogShelf([book, unrelated]) { $0.catalogCopy }
        #expect(shelf.item(for: entry)?.item === book)
        #expect(entry.isNewer(than: book.catalogCopy))

        store.remember(entry, link: href, catalogName: "Hub", on: book)
        #expect(book.sourceEntryID == entry.id)
        #expect(book.sourceURL == href.absoluteString)
        #expect(book.sourceUpdated == entry.updated)
        #expect(!entry.isNewer(than: book.catalogCopy), "remembered: no update on offer")

        // A book tied to another entry is never retied.
        store.remember(entry, link: href, catalogName: "Hub", on: unrelated)
        #expect(unrelated.sourceEntryID == "urn:example:other")
        #expect(unrelated.sourceURL == "https://elsewhere.example.net/get/1.epub")
    }
}
