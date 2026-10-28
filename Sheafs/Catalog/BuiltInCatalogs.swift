import Foundation
import SwiftData

/// A public catalog Sheafs ships ready to browse, so a new library has somewhere to find books.
/// Once added it is an ordinary `Catalog` (rename, reorder, delete); nothing marks it as built in.
nonisolated struct BuiltInCatalog: Hashable, Sendable, Identifiable {
    /// Recorded in `UserDefaults` once the catalog has been added, so it is added only once.
    let id: String
    let name: String
    let urlString: String
    /// How to sign in, when the feed (or part of it) is for members.
    let signInNote: String?

    var url: URL { URL(string: urlString)! }

    static let standardEbooks = BuiltInCatalog(
        id: "standard-ebooks",
        name: "Standard Ebooks",
        urlString: "https://standardebooks.org/feeds/opds",
        signInNote: "The Standard Ebooks catalog is for Patrons Circle members: sign in with your Patrons Circle email address as the username. The password isn’t checked."
    )

    /// Project Gutenberg documents its OPDS feed as starting at the search endpoint.
    static let projectGutenberg = BuiltInCatalog(
        id: "project-gutenberg",
        name: "Project Gutenberg",
        urlString: "https://www.gutenberg.org/ebooks/search.opds/",
        signInNote: nil
    )

    /// In the order they appear on first launch.
    static let all: [BuiltInCatalog] = [.standardEbooks, .projectGutenberg]

    /// The built-in catalog a feed URL belongs to (any page on its host), for its sign-in note.
    static func owning(_ url: URL?) -> BuiltInCatalog? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return all.first { $0.url.host()?.lowercased() == host }
    }

    /// True when `urlString` is this catalog's feed, ignoring scheme and host case and a trailing
    /// slash, so a feed the user added by hand counts.
    func isSameFeed(as urlString: String) -> Bool {
        Self.feedKey(urlString) == Self.feedKey(self.urlString)
    }

    /// The built-ins still to add: not added before (`seeded`), and not already among `existing`
    /// feed URLs.
    static func toSeed(existing: [String], seeded: Set<String>) -> [BuiltInCatalog] {
        all.filter { builtIn in
            !seeded.contains(builtIn.id) && !existing.contains(where: builtIn.isSameFeed)
        }
    }

    private static func feedKey(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return host + path + query
    }
}

extension BuiltInCatalog {
    /// `UserDefaults` key: the ids of the built-ins already added (or found already present).
    static let seededKey = "SheafsSeededCatalogs"

    /// Adds each built-in catalog the first time Sheafs runs with it, after any catalogs already
    /// there. One the user deletes stays deleted; one shipped in a later version is added once
    /// then. A feed the user already has is recorded without adding a second copy.
    @MainActor
    static func seed(into context: ModelContext, defaults: UserDefaults = .standard) {
        let seeded = Set(defaults.stringArray(forKey: seededKey) ?? [])
        let unrecorded = all.filter { !seeded.contains($0.id) }
        guard !unrecorded.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<Catalog>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        var sortOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        for builtIn in toSeed(existing: existing.map(\.urlString), seeded: seeded) {
            context.insert(Catalog(name: builtIn.name, urlString: builtIn.urlString, username: nil,
                                   sortOrder: sortOrder))
            sortOrder += 1
        }
        try? context.save()
        defaults.set(Array(seeded.union(unrecorded.map(\.id))).sorted(), forKey: seededKey)
    }
}
