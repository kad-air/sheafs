import Foundation

/// Descriptive metadata from the package document's `<metadata>` block.
/// All text has whitespace collapsed to single spaces.
public struct EPUBMetadata: Hashable, Sendable {
    /// The main title; empty if the package has none.
    public var title: String
    /// `dc:creator` values in document order, as displayed (not the `file-as` sort form).
    public var authors: [String]
    public var language: String?
    /// The identifier named by `package@unique-identifier`, else the first `dc:identifier`.
    public var identifier: String?
    public var publisher: String?
    /// Plain text; any HTML in `dc:description` is stripped.
    public var description: String?
    /// The raw `dc:date` string (publication date when the package distinguishes several).
    public var published: String?
    /// Series name, from EPUB 3 `belongs-to-collection` or calibre's `calibre:series`.
    public var series: String?
    /// Position in the series (may be fractional, e.g. 1.5).
    public var seriesIndex: Double?
    /// The raw `dcterms:modified` value.
    public var modified: String?

    public init(title: String = "", authors: [String] = [], language: String? = nil, identifier: String? = nil,
                publisher: String? = nil, description: String? = nil, published: String? = nil,
                series: String? = nil, seriesIndex: Double? = nil, modified: String? = nil) {
        self.title = title
        self.authors = authors
        self.language = language
        self.identifier = identifier
        self.publisher = publisher
        self.description = description
        self.published = published
        self.series = series
        self.seriesIndex = seriesIndex
        self.modified = modified
    }
}
