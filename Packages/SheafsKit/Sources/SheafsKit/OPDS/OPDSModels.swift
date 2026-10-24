import Foundation

/// The flavour of an OPDS acquisition link, taken from the suffix of its `rel`.
public enum OPDSAcquisitionKind: String, Hashable, Sendable {
    /// `http://opds-spec.org/acquisition`: no statement about how the book is obtained.
    case generic
    /// `.../acquisition/open-access`: free to download.
    case openAccess
    /// `.../acquisition/borrow`.
    case borrow
    /// `.../acquisition/buy`.
    case buy
    /// `.../acquisition/sample`.
    case sample
    /// `.../acquisition/subscribe`.
    case subscribe
}

/// A `<link>` in an OPDS feed or entry. `href` is always absolute once a feed has been parsed.
public struct OPDSLink: Hashable, Sendable {
    public var rel: String?
    public var type: String?
    public var href: URL
    public var title: String?

    public init(rel: String? = nil, type: String? = nil, href: URL, title: String? = nil) {
        self.rel = rel
        self.type = type
        self.href = href
        self.title = title
    }

    /// `type` lowercased with any parameters (`;profile=...`) removed.
    public var mediaType: String? {
        guard let type else { return nil }
        let base = type.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when `rel` names `opds-spec.org/acquisition` or one of its sub-relations
    /// (open-access, buy, borrow, sample, subscribe).
    public var isAcquisition: Bool {
        relLowercased?.contains("opds-spec.org/acquisition") ?? false
    }

    /// The acquisition flavour, or `nil` when this is not an acquisition link.
    public var acquisitionKind: OPDSAcquisitionKind? {
        guard let rel = relLowercased, let range = rel.range(of: "opds-spec.org/acquisition") else { return nil }
        let suffix = rel[range.upperBound...]
        if suffix.hasPrefix("/open-access") { return .openAccess }
        if suffix.hasPrefix("/borrow") { return .borrow }
        if suffix.hasPrefix("/buy") { return .buy }
        if suffix.hasPrefix("/sample") { return .sample }
        if suffix.hasPrefix("/subscribe") { return .subscribe }
        return .generic
    }

    /// True when the target is an EPUB (`application/epub+zip`).
    public var isEPUB: Bool { mediaType == "application/epub+zip" }

    /// True for a cover image link (`opds-spec.org/image`, not the thumbnail variant).
    public var isImage: Bool {
        guard let rel = relLowercased, !isThumbnail else { return false }
        return rel.contains("opds-spec.org/image") || rel == "http://opds-spec.org/cover"
            || rel == "x-stanza-cover-image"
    }

    /// True for a thumbnail link (`opds-spec.org/image/thumbnail`).
    public var isThumbnail: Bool {
        guard let rel = relLowercased else { return false }
        return rel.contains("opds-spec.org/image/thumbnail") || rel == "http://opds-spec.org/thumbnail"
            || rel == "x-stanza-cover-image-thumbnail"
    }

    /// True when the link leads to another OPDS feed: a navigation or acquisition catalog
    /// (`profile=opds-catalog`), or one of the structural relations such as `subsection`.
    public var isNavigation: Bool {
        if isAcquisition || isImage || isThumbnail || hasRel("search") { return false }
        let lowerType = type?.lowercased() ?? ""
        // `type=entry` is a link to a single complete entry document, not a feed.
        if lowerType.contains("type=entry") { return false }
        if lowerType.contains("profile=opds-catalog") { return true }
        guard let rel = relLowercased else { return mediaType == "application/atom+xml" }
        let structural = ["subsection", "collection", "start", "up", "next", "previous", "prev", "first", "last"]
        if structural.contains(where: hasRel) { return true }
        let opdsListings = ["sort/", "featured", "recommended", "shelf", "subscriptions", "crawlable"]
        if opdsListings.contains(where: { rel.hasPrefix("http://opds-spec.org/" + $0) }) { return true }
        // Some servers type a sub-catalog link as plain Atom with no profile.
        return mediaType == "application/atom+xml" && !hasRel("self") && !hasRel("alternate")
    }

    /// True when this is an OpenSearch description document rather than a URL template.
    public var isOpenSearchDescription: Bool {
        type?.lowercased().contains("opensearchdescription") ?? false
    }

    /// True when `href` is itself a search URL template containing `{searchTerms}`.
    public var isSearchTemplate: Bool {
        let text = href.absoluteString
        return text.contains("{searchTerms") || text.localizedCaseInsensitiveContains("%7BsearchTerms")
    }

    /// Whether the (possibly space separated) `rel` contains `name`, ignoring case.
    func hasRel(_ name: String) -> Bool {
        guard let rel = relLowercased else { return false }
        return rel.split(whereSeparator: \.isWhitespace).contains { $0 == name }
    }

    private var relLowercased: String? { rel?.lowercased() }
}

/// One `<entry>`: a book in an acquisition feed, or a sub-catalog in a navigation feed.
public struct OPDSEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var authors: [String]
    /// Plain text: tags are stripped from `html` / `xhtml` content and entities decoded.
    public var summary: String?
    public var updated: Date?
    public var published: Date?
    public var language: String?
    public var categories: [String]
    public var links: [OPDSLink]

    public init(
        id: String,
        title: String,
        authors: [String] = [],
        summary: String? = nil,
        updated: Date? = nil,
        published: Date? = nil,
        language: String? = nil,
        categories: [String] = [],
        links: [OPDSLink] = []
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.summary = summary
        self.updated = updated
        self.published = published
        self.language = language
        self.categories = categories
        self.links = links
    }

    /// Every acquisition link (open-access, buy, borrow, ...).
    public var acquisitionLinks: [OPDSLink] { links.filter(\.isAcquisition) }

    /// The first acquisition link that delivers an EPUB.
    public var epubLink: OPDSLink? { links.first { $0.isAcquisition && $0.isEPUB } }

    /// The thumbnail image, else the full cover image.
    public var thumbnailURL: URL? {
        (links.first(where: \.isThumbnail) ?? links.first(where: \.isImage))?.href
    }

    /// The first link to another feed, when this entry has no acquisition links.
    public var navigationLink: OPDSLink? {
        guard acquisitionLinks.isEmpty else { return nil }
        return links.first(where: \.isNavigation)
    }

    /// True when the entry opens another feed rather than offering a book.
    public var isNavigation: Bool { navigationLink != nil }
}

/// A parsed OPDS 1.2 Atom feed.
public struct OPDSFeed: Hashable, Sendable {
    /// Whether a feed lists sub-catalogs or books.
    public enum Kind: Hashable, Sendable {
        case navigation
        case acquisition
    }

    public var id: String?
    public var title: String
    public var updated: Date?
    public var links: [OPDSLink]
    public var entries: [OPDSEntry]

    public init(
        id: String? = nil,
        title: String,
        updated: Date? = nil,
        links: [OPDSLink] = [],
        entries: [OPDSEntry] = []
    ) {
        self.id = id
        self.title = title
        self.updated = updated
        self.links = links
        self.entries = entries
    }

    /// Acquisition if any entry offers a book, whatever the self link claims (some servers
    /// label every feed `kind=navigation`); otherwise the self link's `kind=` parameter;
    /// otherwise navigation.
    public var kind: Kind {
        if entries.contains(where: { !$0.acquisitionLinks.isEmpty }) { return .acquisition }
        let selfType = links.first(where: { $0.hasRel("self") })?.type?.lowercased() ?? ""
        return selfType.contains("kind=acquisition") ? .acquisition : .navigation
    }

    /// The next page of a paginated feed (`rel="next"`).
    public var nextURL: URL? { url(forAnyRel: ["next"]) }

    /// The previous page of a paginated feed (`rel="previous"` or `"prev"`).
    public var previousURL: URL? { url(forAnyRel: ["previous", "prev"]) }

    /// The feed's search entry point: an OpenSearch description document or a direct URL template.
    public var searchLink: OPDSLink? {
        links.first { $0.hasRel("search") && ($0.isOpenSearchDescription || $0.isSearchTemplate) }
    }

    /// The catalog root (`rel="start"`).
    public var startURL: URL? { url(forAnyRel: ["start"]) }

    private func url(forAnyRel names: [String]) -> URL? {
        links.first { link in names.contains(where: link.hasRel) }?.href
    }
}

/// Errors thrown by the OPDS parser and client.
public enum OPDSError: Error, CustomStringConvertible {
    /// The document is well-formed XML but not an Atom feed.
    case notAFeed
    /// The document could not be parsed.
    case malformed(String)
    /// The server answered with a non-2xx status other than 401.
    case httpStatus(Int, url: URL)
    /// The server answered 401: credentials are missing or wrong.
    case unauthorized(url: URL)
    /// A download was not an EPUB (callers decide when to raise this; the client does not).
    case notEPUB(contentType: String?)
    /// The request failed before a response arrived.
    case network(underlying: Error)

    public var description: String {
        switch self {
        case .notAFeed:
            return "The response is not an OPDS feed. The URL may point at a web page instead of a catalog."
        case .malformed(let detail):
            return "The OPDS document could not be read: \(detail)"
        case .httpStatus(let status, let url):
            return "The catalog answered HTTP \(status) for \(url.absoluteString)."
        case .unauthorized(let url):
            return "The catalog rejected the username or password for \(url.absoluteString)."
        case .notEPUB(let contentType):
            return "The download is not an EPUB (content type: \(contentType ?? "unknown"))."
        case .network(let underlying):
            return "The catalog could not be reached: \(underlying.localizedDescription)"
        }
    }
}

/// A username and password for HTTP Basic authentication against a catalog.
public struct OPDSCredentials: Hashable, Sendable, CustomStringConvertible {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Never includes the password, so credentials are safe to log.
    public var description: String { "OPDSCredentials(username: \(username), password: <redacted>)" }
}
