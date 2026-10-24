import Foundation

// Compiled into BOTH the app and the widget extension (see project.yml). The app writes the most
// recently read book into the shared app group container; the widget only reads it. The widget
// cannot open the app's SwiftData store or its Application Support folder, hence this snapshot.

/// What the "Continue Reading" widget shows: the library's most recently read book.
nonisolated struct RecentBook: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var author: String?
    /// 0...1 over the whole book.
    var progress: Double
    var hasCover: Bool
}

/// The app group folder both processes share: `recent-book.json` plus `recent-cover.jpg`.
nonisolated struct RecentBookShelf: Sendable {
    static let appGroup = "group.io.sheafs.reader"
    /// The widget kind, for `WidgetCenter.reloadTimelines(ofKind:)`.
    static let widgetKind = "ContinueReading"

    let directory: URL

    /// The shared container, or nil when the app group isn't provisioned (then there's no widget).
    static var shared: RecentBookShelf? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { RecentBookShelf(directory: $0) }
    }

    var bookURL: URL { directory.appending(path: "recent-book.json") }
    var coverURL: URL { directory.appending(path: "recent-cover.jpg") }

    func read() -> RecentBook? {
        guard let data = try? Data(contentsOf: bookURL) else { return nil }
        return try? JSONDecoder().decode(RecentBook.self, from: data)
    }

    func coverData() -> Data? { try? Data(contentsOf: coverURL) }

    /// Writes the snapshot (and the cover, when given). Nil clears the shelf (empty library).
    func write(_ book: RecentBook?, cover: Data?) throws {
        guard let book else {
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: coverURL)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let cover { try cover.write(to: coverURL, options: .atomic) }
        else if !book.hasCover { try? FileManager.default.removeItem(at: coverURL) }
        try JSONEncoder().encode(book).write(to: bookURL, options: .atomic)
    }
}

/// `sheafs://open?book=<uuid>`: the widget's tap target. The scheme is declared in the app's
/// Info.plist (`CFBundleURLTypes` in project.yml).
nonisolated enum SheafsLink {
    static let scheme = "sheafs"

    static func open(_ id: UUID) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "book", value: id.uuidString)]
        return parts.url!
    }

    /// The book a link opens, or nil when it isn't one of ours (e.g. a file URL to import).
    static func bookID(in url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "open",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "book" })?.value else { return nil }
        return UUID(uuidString: value)
    }
}
