import Foundation

/// Parses OPDS 1.2 (Atom) feeds and OpenSearch descriptions, and expands search templates.
public enum OPDSParser {
    /// Parses an Atom feed. Relative hrefs are resolved against `baseURL` (the URL the feed was
    /// fetched from), after applying an `xml:base` on `<feed>` when there is one.
    ///
    /// - Throws: ``OPDSError/notAFeed`` when the root element is not `<feed>`,
    ///   ``OPDSError/malformed(_:)`` when the XML cannot be parsed.
    public static func parseFeed(_ data: Data, baseURL: URL) throws -> OPDSFeed {
        let delegate = FeedDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let succeeded = parser.parse()
        if delegate.notAFeed { throw OPDSError.notAFeed }
        guard succeeded else {
            let detail = parser.parserError?.localizedDescription ?? "unparseable XML"
            throw OPDSError.malformed("line \(parser.lineNumber): \(detail)")
        }
        guard delegate.sawFeed else { throw OPDSError.notAFeed }
        return delegate.makeFeed()
    }

    /// Extracts the search URL template from an OpenSearch description: the `<Url template>` whose
    /// type is Atom/OPDS (preferring `kind=acquisition`), else the first `<Url>`. A relative
    /// template is resolved against `baseURL`; the `{...}` placeholders are left intact.
    public static func parseOpenSearchTemplate(_ data: Data, baseURL: URL) throws -> String {
        let delegate = OpenSearchDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let succeeded = parser.parse()
        if delegate.rejectedRoot { throw OPDSError.malformed("not an OpenSearch description") }
        guard succeeded else {
            let detail = parser.parserError?.localizedDescription ?? "unparseable XML"
            throw OPDSError.malformed("OpenSearch description, line \(parser.lineNumber): \(detail)")
        }

        func isAtom(_ endpoint: OpenSearchDelegate.Endpoint) -> Bool {
            let type = endpoint.type.lowercased()
            return type.contains("atom") || type.contains("opds")
        }
        let chosen = delegate.endpoints.first { isAtom($0) && $0.type.lowercased().contains("kind=acquisition") }
            ?? delegate.endpoints.first(where: isAtom)
            ?? delegate.endpoints.first
        guard let chosen else { throw OPDSError.malformed("OpenSearch description has no <Url template>") }
        return resolve(template: chosen.template, against: baseURL)
    }

    /// Expands an OpenSearch URL template for `query`.
    ///
    /// `{searchTerms}` and `{searchTerms?}` become the percent-encoded query (a space is `%20`,
    /// `&` is `%26`). Every other placeholder is dropped, together with the `name=` it was the
    /// value of, so `?q={searchTerms}&page={startPage?}` becomes `?q=...`. A template whose braces
    /// were already percent-encoded by a URL parser (`%7BsearchTerms%7D`) works too.
    public static func searchURL(template: String, query: String) -> URL? {
        let normalized = template
            .replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive)
            .replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? query

        var path = normalized
        var queryPart: String?
        if let split = firstQuestionMark(in: normalized) {
            path = String(normalized[..<split])
            queryPart = String(normalized[normalized.index(after: split)...])
        }

        var result = expand(path, query: encoded).text
        if let queryPart {
            let kept = queryPart.split(separator: "&", omittingEmptySubsequences: false).compactMap { piece -> String? in
                let expansion = expand(String(piece), query: encoded)
                if expansion.droppedOther && !expansion.usedSearchTerms {
                    // `name={startPage?}` expanded to `name=`; the parameter is meaningless without a value.
                    return expansion.text.isEmpty || expansion.text.hasSuffix("=") ? nil : expansion.text
                }
                return expansion.text
            }
            if !kept.isEmpty { result += "?" + kept.joined(separator: "&") }
        }
        return URL(string: result)
    }

    // MARK: - Template helpers

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// The first `?` that is not inside `{...}` (an optional placeholder looks like `{x?}`).
    private static func firstQuestionMark(in text: String) -> String.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "?" where depth == 0: return index
            default: break
            }
        }
        return nil
    }

    private static func expand(_ text: String, query: String) -> (text: String, usedSearchTerms: Bool, droppedOther: Bool) {
        var output = ""
        var usedSearchTerms = false
        var droppedOther = false
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "{", let close = text[index...].firstIndex(of: "}") {
                var name = text[text.index(after: index)..<close]
                if name.hasSuffix("?") { name = name.dropLast() }
                if name == "searchTerms" {
                    output += query
                    usedSearchTerms = true
                } else {
                    droppedOther = true
                }
                index = text.index(after: close)
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return (output, usedSearchTerms, droppedOther)
    }

    /// Resolves a possibly relative template against `base` without disturbing the braces.
    private static func resolve(template: String, against base: URL) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
        let protected = trimmed
            .replacingOccurrences(of: "{", with: "%7B")
            .replacingOccurrences(of: "}", with: "%7D")
        guard let resolved = URL(string: protected, relativeTo: base)?.absoluteString else { return trimmed }
        return resolved
            .replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive)
            .replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
    }
}

// MARK: - Atom feed delegate

private struct EntryBuilder {
    var id: String?
    var title: String?
    var authors: [String] = []
    var creators: [String] = []
    var summary: String?
    var content: String?
    var updated: Date?
    var published: Date?
    var issued: Date?
    var language: String?
    var categories: [String] = []
    var links: [OPDSLink] = []

    func build() -> OPDSEntry {
        let title = title ?? ""
        return OPDSEntry(
            id: id ?? links.first?.href.absoluteString ?? title,
            title: title,
            authors: authors.isEmpty ? creators : authors,
            summary: summary ?? content,
            updated: updated,
            published: published ?? issued,
            language: language,
            categories: categories,
            links: links
        )
    }
}

/// Collects a feed in one pass. Elements are identified by local name; the Atom namespace (or
/// none) is plain, Dublin Core is prefixed `dc:` and anything else `ext:`, so an extension
/// element such as `<dc:title>` can never be mistaken for Atom's `<title>`.
private final class FeedDelegate: NSObject, XMLParserDelegate {
    private static let atomNamespace = "http://www.w3.org/2005/Atom"
    private static let dublinCore: Set<String> = ["http://purl.org/dc/elements/1.1/", "http://purl.org/dc/terms/"]

    /// Atom text that may contain markup: `<summary>` and `<content>`.
    private struct RichText {
        var depth: Int
        var type: String
        var isSummary: Bool
        var text = ""
    }

    private let documentBase: URL
    private var base: URL
    private var stack: [String] = []
    private var capture: (depth: Int, text: String)?
    private var rich: RichText?

    private(set) var sawFeed = false
    private(set) var notAFeed = false

    private var feedID: String?
    private var feedTitle: String?
    private var feedUpdated: Date?
    private var feedLinks: [OPDSLink] = []
    private var entries: [OPDSEntry] = []
    private var entry: EntryBuilder?

    init(baseURL: URL) {
        documentBase = baseURL
        base = baseURL
    }

    func makeFeed() -> OPDSFeed {
        OPDSFeed(id: feedID, title: feedTitle ?? "", updated: feedUpdated, links: feedLinks, entries: entries)
    }

    private static func key(_ local: String, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty, namespace != atomNamespace else { return local }
        return dublinCore.contains(namespace) ? "dc:" + local : "ext:" + local
    }

    private func makeLink(_ attributes: [String: String]) -> OPDSLink? {
        guard let raw = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw, relativeTo: base)?.absoluteURL
        else { return nil }
        func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        return OPDSLink(
            rel: nonEmpty(attributes["rel"]),
            type: nonEmpty(attributes["type"]),
            href: url,
            title: nonEmpty(attributes["title"])
        )
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        stack.append(Self.key(elementName, namespace: namespaceURI))

        if rich != nil {
            if breaksLine(elementName) { rich?.text += "\n" }
            return
        }
        if stack.count == 1 {
            guard stack[0] == "feed" else {
                notAFeed = true
                parser.abortParsing()
                return
            }
            sawFeed = true
            if let declared = attributeDict["xml:base"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: declared, relativeTo: documentBase)?.absoluteURL {
                base = url
            }
            return
        }

        switch stack.joined(separator: "/") {
        case "feed/id", "feed/title", "feed/updated",
             "feed/entry/id", "feed/entry/title", "feed/entry/updated", "feed/entry/published",
             "feed/entry/dc:language", "feed/entry/dc:issued",
             "feed/entry/author/name", "feed/entry/dc:creator":
            capture = (stack.count, "")
        case "feed/entry/summary", "feed/entry/content":
            rich = RichText(
                depth: stack.count,
                type: attributeDict["type"] ?? "text",
                isSummary: stack.last == "summary"
            )
        case "feed/link":
            if let link = makeLink(attributeDict) { feedLinks.append(link) }
        case "feed/entry":
            entry = EntryBuilder()
        case "feed/entry/link":
            if let link = makeLink(attributeDict) { entry?.links.append(link) }
        case "feed/entry/category":
            let label = attributeDict["label"]?.collapsingWhitespace ?? ""
            let term = attributeDict["term"]?.collapsingWhitespace ?? ""
            let category = label.isEmpty ? term : label
            if !category.isEmpty { entry?.categories.append(category) }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { stack.removeLast() }

        if let current = rich {
            if current.depth == stack.count {
                finish(current)
                rich = nil
            } else if breaksLine(elementName) {
                rich?.text += "\n"
            }
            return
        }
        if let current = capture, current.depth == stack.count {
            finish(captured: current.text, path: stack.joined(separator: "/"))
            capture = nil
            return
        }
        if stack == ["feed", "entry"], let builder = entry {
            entries.append(builder.build())
            entry = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        append(String(decoding: CDATABlock, as: UTF8.self))
    }

    // MARK: Helpers

    private func append(_ text: String) {
        if rich != nil {
            rich?.text += text
        } else if capture != nil {
            capture?.text += text
        }
    }

    private func breaksLine(_ localName: String) -> Bool {
        HTMLText.breaksLine.contains(localName.lowercased())
    }

    private func finish(_ text: RichText) {
        let plain = text.type.lowercased() == "xhtml"
            ? HTMLText.tidy(text.text)
            : HTMLText.plain(fromHTML: text.text)
        guard !plain.isEmpty else { return }
        if text.isSummary {
            if entry?.summary == nil { entry?.summary = plain }
        } else if entry?.content == nil {
            entry?.content = plain
        }
    }

    private func finish(captured raw: String, path: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = raw.collapsingWhitespace
        switch path {
        case "feed/id": feedID = feedID ?? nonEmpty(text)
        case "feed/title": feedTitle = feedTitle ?? collapsed
        case "feed/updated": feedUpdated = feedUpdated ?? OPDSDate.parse(text)
        default:
            guard var builder = entry else { return }
            switch path {
            case "feed/entry/id": builder.id = builder.id ?? nonEmpty(text)
            case "feed/entry/title": builder.title = builder.title ?? collapsed
            case "feed/entry/updated": builder.updated = builder.updated ?? OPDSDate.parse(text)
            case "feed/entry/published": builder.published = builder.published ?? OPDSDate.parse(text)
            case "feed/entry/dc:issued": builder.issued = builder.issued ?? OPDSDate.parse(text)
            case "feed/entry/dc:language": builder.language = builder.language ?? nonEmpty(text)
            case "feed/entry/author/name": if let name = nonEmpty(collapsed) { builder.authors.append(name) }
            case "feed/entry/dc:creator": if let name = nonEmpty(collapsed) { builder.creators.append(name) }
            default: break
            }
            entry = builder
        }
    }

    private func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }
}

// MARK: - OpenSearch delegate

private final class OpenSearchDelegate: NSObject, XMLParserDelegate {
    struct Endpoint {
        var type: String
        var template: String
    }

    private(set) var rejectedRoot = false
    private(set) var endpoints: [Endpoint] = []
    private var depth = 0

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        depth += 1
        if depth == 1 {
            if elementName.lowercased() != "opensearchdescription" {
                rejectedRoot = true
                parser.abortParsing()
            }
        } else if elementName.lowercased() == "url",
                  let template = attributeDict["template"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !template.isEmpty {
            endpoints.append(Endpoint(type: attributeDict["type"] ?? "", template: template))
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        depth -= 1
    }
}
