import Foundation

/// One entry of an EPUB's page list: where a page of the print edition begins
/// (`<nav epub:type="page-list">` in an EPUB 3 navigation document, `<pageList>` in an NCX).
public struct PageListEntry: Hashable, Sendable {
    /// The page's label as the book gives it ("12", "xiv", "{475}"), whitespace collapsed.
    public let label: String
    /// Zip path of the target document, percent-decoded; nil when the entry has no link or links
    /// outside the book.
    public let path: String?
    /// Percent-decoded fragment identifier, if any.
    public let fragment: String?

    public init(label: String, path: String?, fragment: String?) {
        self.label = label
        self.path = path
        self.fragment = fragment
    }
}

/// Page-list parsing for both EPUB 3 navigation documents and EPUB 2 NCX files. Both return nil
/// when the file cannot be parsed at all or has no page list, so the caller can fall back.
enum PageListParser {
    /// The links of `<nav epub:type="page-list">`, in document order (nested lists flattened).
    static func parseNavDocument(_ data: Data, path: String) -> [PageListEntry]? {
        guard let root = XMLTreeNode.parse(data, mode: .xhtml) else { return nil }
        let nav = root.descendants { $0.name == "nav" }.first {
            Set(($0.attribute("type") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)).contains("page-list")
        }
        guard let nav else { return nil }
        let entries = nav.descendants { $0.name == "a" }.map { link in
            entry(label: link.collapsedText, href: link.attribute("href"), basePath: path)
        }
        return entries.isEmpty ? nil : entries
    }

    /// `pageList > pageTarget` with `navLabel > text` and `content@src`, in document order.
    static func parseNCX(_ data: Data, path: String) -> [PageListEntry]? {
        guard let root = XMLTreeNode.parseLeniently(data), root.name == "ncx",
              let pageList = root.firstElement(named: "pageList") else { return nil }
        let entries = pageList.descendants { $0.name == "pageTarget" }.map { target in
            let label = target.firstElement(named: "navLabel")?.firstDescendant { $0.name == "text" }?.collapsedText
            return entry(label: label ?? target.attribute("value") ?? "",
                         href: target.firstElement(named: "content")?.attribute("src"), basePath: path)
        }
        return entries.isEmpty ? nil : entries
    }

    private static func entry(label: String, href: String?, basePath: String) -> PageListEntry {
        guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty,
              !EPUBPath.isExternal(href) else { return PageListEntry(label: label, path: nil, fragment: nil) }
        let (rawPath, rawFragment) = EPUBPath.split(href)
        let fragment = rawFragment.map { $0.removingPercentEncoding ?? $0 }
        return PageListEntry(label: label, path: EPUBPath.resolve(rawPath, relativeTo: basePath), fragment: fragment)
    }
}
