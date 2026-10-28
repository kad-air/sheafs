import Testing
import Foundation
import SwiftData
@testable import Sheafs

/// Standard Ebooks and Project Gutenberg are in Catalogs on first launch, each added ONCE: a
/// deleted one stays deleted, and a feed the user already added isn't doubled.
struct BuiltInCatalogTests {
    private static func freshDefaults() throws -> UserDefaults {
        let name = "BuiltInCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func catalogs(in store: LibraryStore) throws -> [Catalog] {
        try store.context.fetch(FetchDescriptor<Catalog>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    @Test func firstLaunchAddsBothInOrder() throws {
        let store = LibraryStore(inMemory: true), defaults = try Self.freshDefaults()
        BuiltInCatalog.seed(into: store.context, defaults: defaults)
        let added = try Self.catalogs(in: store)
        #expect(added.map(\.name) == ["Standard Ebooks", "Project Gutenberg"])
        #expect(added.map(\.urlString) == BuiltInCatalog.all.map(\.urlString))
        #expect(added.map(\.sortOrder) == [0, 1])
        #expect(added.allSatisfy { $0.username == nil })
        #expect(Set(defaults.stringArray(forKey: BuiltInCatalog.seededKey) ?? []) == ["standard-ebooks", "project-gutenberg"])
    }

    @Test func aDeletedOneStaysDeleted() throws {
        let store = LibraryStore(inMemory: true), defaults = try Self.freshDefaults()
        BuiltInCatalog.seed(into: store.context, defaults: defaults)
        let gutenberg = try #require(try Self.catalogs(in: store).first { $0.name == "Project Gutenberg" })
        store.context.delete(gutenberg)
        try store.context.save()
        BuiltInCatalog.seed(into: store.context, defaults: defaults)
        BuiltInCatalog.seed(into: store.context, defaults: defaults)
        #expect(try Self.catalogs(in: store).map(\.name) == ["Standard Ebooks"])
    }

    @Test func goesAfterTheUsersOwnAndSkipsAFeedTheyAlreadyHave() throws {
        let store = LibraryStore(inMemory: true), defaults = try Self.freshDefaults()
        store.context.insert(Catalog(name: "Home", urlString: "https://books.example.com/opds", username: nil, sortOrder: 0))
        // Typed by hand: other host case, no trailing slash.
        store.context.insert(Catalog(name: "PG", urlString: "https://WWW.gutenberg.org/ebooks/search.opds",
                                     username: nil, sortOrder: 1))
        try store.context.save()
        BuiltInCatalog.seed(into: store.context, defaults: defaults)
        let all = try Self.catalogs(in: store)
        #expect(all.map(\.name) == ["Home", "PG", "Standard Ebooks"])
        #expect(all.map(\.sortOrder) == [0, 1, 2])
        // Recorded anyway, so deleting the hand-added copy doesn't bring a built-in one back.
        #expect((defaults.stringArray(forKey: BuiltInCatalog.seededKey) ?? []).contains("project-gutenberg"))
    }

    @Test func aBuiltInShippedLaterIsAddedOnce() {
        let toSeed = BuiltInCatalog.toSeed(existing: [], seeded: ["standard-ebooks"])
        #expect(toSeed == [.projectGutenberg])
        #expect(BuiltInCatalog.toSeed(existing: [], seeded: ["standard-ebooks", "project-gutenberg"]).isEmpty)
    }

    @Test func feedMatchingAndOwnership() throws {
        #expect(BuiltInCatalog.standardEbooks.isSameFeed(as: "https://standardebooks.org/feeds/opds/"))
        #expect(BuiltInCatalog.standardEbooks.isSameFeed(as: "http://StandardEbooks.org/feeds/opds"))
        #expect(!BuiltInCatalog.standardEbooks.isSameFeed(as: "https://standardebooks.org/feeds/opds/all"))
        #expect(!BuiltInCatalog.projectGutenberg.isSameFeed(as: "not a url"))
        let page = try #require(URL(string: "https://standardebooks.org/feeds/opds/subjects/fiction"))
        #expect(BuiltInCatalog.owning(page) == .standardEbooks)
        #expect(BuiltInCatalog.owning(page)?.signInNote != nil)
        #expect(BuiltInCatalog.owning(URL(string: "https://www.gutenberg.org/ebooks/1342.opds")) == .projectGutenberg)
        #expect(BuiltInCatalog.owning(URL(string: "https://books.example.com/opds")) == nil)
    }
}
