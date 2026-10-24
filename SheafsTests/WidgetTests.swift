import Testing
import Foundation
import SwiftData
@testable import Sheafs

/// The "Continue Reading" widget: the app and widget share an app group, the app embeds the
/// extension and answers the widget's `sheafs://` link, and the snapshot is the right book.
struct WidgetTests {
    @Test func linkRoundTripsAndIgnoresOtherURLs() throws {
        let id = UUID()
        let link = SheafsLink.open(id)
        #expect(link.absoluteString == "sheafs://open?book=\(id.uuidString)")
        #expect(SheafsLink.bookID(in: link) == id)
        #expect(SheafsLink.bookID(in: try #require(URL(string: "SHEAFS://OPEN?book=\(id.uuidString)"))) == id)
        // A file handed to the app is an import, never a link.
        #expect(SheafsLink.bookID(in: URL(filePath: "/tmp/\(id.uuidString).epub")) == nil)
        #expect(SheafsLink.bookID(in: try #require(URL(string: "sheafs://open?book=nope"))) == nil)
        #expect(SheafsLink.bookID(in: try #require(URL(string: "https://open?book=\(id.uuidString)"))) == nil)
    }

    /// Without the URL type the tap only launches the app; without the embedded extension there's
    /// no widget to add; without the app group the widget reads nothing and says "No books yet".
    @Test func appDeclaresSchemeEmbedsWidgetAndHasAppGroup() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(SheafsLink.scheme))

        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let widget = try #require(Bundle(url: plugins.appending(path: "SheafsWidget.appex")))
        let ext = try #require(widget.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        #expect(ext["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
        #expect(widget.bundleIdentifier == "io.sheafs.reader.widget")

        #expect(RecentBookShelf.shared != nil, "app group \(RecentBookShelf.appGroup) not in the app's entitlements")
    }

    @Test func shelfWritesReadsAndClears() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = RecentBookShelf(directory: dir)
        #expect(shelf.read() == nil)
        let book = RecentBook(id: UUID(), title: "Alice", author: "Lewis Carroll", progress: 0.42, hasCover: true)
        try shelf.write(book, cover: Data([0xFF, 0xD8, 0xFF]))
        #expect(shelf.read() == book)
        #expect(shelf.coverData() == Data([0xFF, 0xD8, 0xFF]))
        // Same book, no new cover: the old cover stays (the app only re-sends it on a new book).
        try shelf.write(RecentBook(id: book.id, title: "Alice", author: nil, progress: 0.5, hasCover: true), cover: nil)
        #expect(shelf.read()?.progress == 0.5)
        #expect(shelf.coverData() != nil)
        // A book without a cover never shows the previous one's.
        try shelf.write(RecentBook(id: UUID(), title: "Plain", author: nil, progress: 0, hasCover: false), cover: nil)
        #expect(shelf.coverData() == nil)
        try shelf.write(nil, cover: nil)
        #expect(shelf.read() == nil)
    }

    @Test func mostRecentIsLastOpenedElseLastAdded() {
        let library = LibraryStore(inMemory: true)
        #expect(library.mostRecentBook() == nil)
        let read = Book(title: "Read last week", author: nil, language: nil, fileSize: 1, partialMD5: "a", hasCover: false)
        read.addedAt = .now.addingTimeInterval(-30 * 86_400)
        read.lastOpenedAt = .now.addingTimeInterval(-7 * 86_400)
        let added = Book(title: "Added yesterday", author: nil, language: nil, fileSize: 1, partialMD5: "b", hasCover: false)
        added.addedAt = .now.addingTimeInterval(-86_400)
        let old = Book(title: "Old", author: nil, language: nil, fileSize: 1, partialMD5: "c", hasCover: false)
        old.addedAt = .now.addingTimeInterval(-60 * 86_400)
        for book in [read, added, old] { library.context.insert(book) }
        // Never opened but added after the last read counts as newer, like the library grid.
        #expect(library.mostRecentBook()?.title == "Added yesterday")
        read.lastOpenedAt = .now
        #expect(library.mostRecentBook()?.title == "Read last week")
    }

    /// A snapshot that went missing (or was never written) comes back on the next foreground,
    /// even though the book itself didn't change.
    @Test func forcedPublishRepairsAMissingSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = LibraryStore(inMemory: true)
        let shelf = RecentBookShelf(directory: dir)
        library.shelf = shelf
        let book = Book(title: "The Return of the King", author: nil, language: nil, fileSize: 1, partialMD5: "k", hasCover: false)
        book.lastOpenedAt = .now
        library.context.insert(book)

        library.publishRecentBook()
        #expect(shelf.read()?.title == "The Return of the King")
        try FileManager.default.removeItem(at: shelf.bookURL)
        library.publishRecentBook()   // a page turn with no visible change: skipped
        #expect(shelf.read() == nil)
        library.publishRecentBook(force: true)
        #expect(shelf.read()?.id == book.id)
        // A real change still goes through without force.
        book.progress = 0.5
        library.publishRecentBook()
        #expect(shelf.read()?.progress == 0.5)
    }
}
