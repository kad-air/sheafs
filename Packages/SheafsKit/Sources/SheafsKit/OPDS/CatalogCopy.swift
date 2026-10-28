import Foundation

/// What the library remembers about a book it downloaded from an OPDS catalog: enough to find
/// the book's entry again in a later feed and to tell whether the catalog's file has changed.
///
/// A catalog can change a book's file after it was downloaded (a new cover, a corrected title, a
/// revised edition). The entry's Atom `id` stays the same while its acquisition URL may not (many
/// servers name the file after the title), so the id is the identity and the URL is the fallback;
/// the entry's `updated` is the only standard signal that the file changed.
public struct CatalogCopy: Hashable, Sendable {
    /// The entry's Atom `id` when the book was downloaded. `nil` for books downloaded before
    /// Sheafs kept it.
    public var entryID: String?
    /// The acquisition URL the book was downloaded from.
    public var sourceURL: String?
    /// The entry's `updated` when the book was downloaded (or last updated from it). `nil` for
    /// books downloaded before Sheafs kept it, or from an entry that had none.
    public var updated: Date?
    /// When the book was added to the library: stands in for `updated` when that is `nil`.
    public var addedAt: Date

    public init(entryID: String?, sourceURL: String?, updated: Date?, addedAt: Date) {
        self.entryID = entryID
        self.sourceURL = sourceURL
        self.updated = updated
        self.addedAt = addedAt
    }
}

extension OPDSEntry {
    /// True when `copy` was downloaded from this entry:
    ///
    /// 1. the same entry `id`, from the same host (Atom ids should be unique everywhere, but a
    ///    careless server may number its entries, and two such catalogs must not claim each
    ///    other's books);
    /// 2. else the same acquisition URL (how Sheafs matched before it kept the id);
    /// 3. else, for a copy with no recorded id, a URL on the same host whose path holds this
    ///    entry's `urn:uuid:` as a whole segment, as the entry's own URL does. That finds a book
    ///    downloaded before Sheafs kept the id after the server renamed its file
    ///    (`/books/<uuid>/file/Old Title.epub` → `/books/<uuid>/file/New Title.epub`), and can't
    ///    claim another book's copy: a UUID names one book.
    public func matches(_ copy: CatalogCopy) -> Bool {
        guard let link = epubLink else { return false }
        let href = link.href
        let copyURL = copy.sourceURL.flatMap(URL.init(string:))
        if let entryID = copy.entryID {
            guard entryID == id else { return false }
            guard let copyURL else { return true }
            return Self.sameHost(copyURL, href)
        }
        guard let copyURL else { return false }
        if copyURL == href || copy.sourceURL == href.absoluteString { return true }
        guard let uuid = uuidID, Self.sameHost(copyURL, href) else { return false }
        return Self.pathHolds(uuid, href) && Self.pathHolds(uuid, copyURL)
    }

    /// True when the catalog's file is newer than `copy`: the entry's `updated` is more than a
    /// second after the copy's (or, for a copy that never recorded one, after it was added). An
    /// entry with no `updated` never offers an update.
    public func isNewer(than copy: CatalogCopy) -> Bool {
        guard let updated else { return false }
        return updated.timeIntervalSince(copy.updated ?? copy.addedAt) > 1
    }

    /// The UUID in a `urn:uuid:` id, lowercased; `nil` for any other kind of id.
    public var uuidID: String? {
        let prefix = "urn:uuid:"
        guard id.lowercased().hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: rest) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func sameHost(_ a: URL, _ b: URL) -> Bool {
        a.host()?.lowercased() == b.host()?.lowercased() && a.port == b.port
    }

    private static func pathHolds(_ uuid: String, _ url: URL) -> Bool {
        url.pathComponents.contains { $0.lowercased() == uuid }
    }
}

/// The library's catalog copies, indexed so a feed page can find each entry's book without
/// trying every book: by entry id, by URL, and by the UUID segments in a URL's path, each
/// candidate confirmed with `OPDSEntry.matches`.
public struct CatalogShelf<Item> {
    private let items: [(item: Item, copy: CatalogCopy)]
    private var byEntryID: [String: [Int]] = [:]
    private var byURL: [String: [Int]] = [:]
    private var byUUID: [String: [Int]] = [:]

    public init(_ items: [Item], copy: (Item) -> CatalogCopy) {
        self.items = items.map { ($0, copy($0)) }
        for (index, entry) in self.items.enumerated() {
            if let id = entry.copy.entryID { byEntryID[id, default: []].append(index) }
            guard let source = entry.copy.sourceURL else { continue }
            byURL[source, default: []].append(index)
            for segment in URL(string: source)?.pathComponents ?? [] {
                if let uuid = UUID(uuidString: segment) {
                    byUUID[uuid.uuidString.lowercased(), default: []].append(index)
                }
            }
        }
    }

    /// The item downloaded from `entry`, preferring one tied to it by id, then by URL, then by
    /// the UUID in its path; `nil` when none is.
    public func item(for entry: OPDSEntry) -> (item: Item, copy: CatalogCopy)? {
        var candidates = byEntryID[entry.id] ?? []
        if let href = entry.epubLink?.href.absoluteString { candidates += byURL[href] ?? [] }
        if let uuid = entry.uuidID { candidates += byUUID[uuid] ?? [] }
        for index in candidates where entry.matches(items[index].copy) {
            return items[index]
        }
        return nil
    }
}
