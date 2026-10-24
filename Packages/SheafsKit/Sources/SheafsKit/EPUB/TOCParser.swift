import Foundation

/// One entry of an EPUB's table of contents.
public struct TOCEntry: Hashable, Sendable, Identifiable {
    /// Preorder index across the whole tree (0 for the first entry, children before later siblings).
    public let id: Int
    public let title: String
    /// Zip path of the target document, percent-decoded; nil when the entry has no link
    /// (a pure heading) or links outside the book.
    public let path: String?
    /// Percent-decoded fragment identifier (`#chapter2` -> "chapter2"), if any.
    public let fragment: String?
    /// Nesting level; 0 for top-level entries.
    public let depth: Int
    public let children: [TOCEntry]

    public init(id: Int, title: String, path: String?, fragment: String?, depth: Int, children: [TOCEntry]) {
        self.id = id
        self.title = title
        self.path = path
        self.fragment = fragment
        self.depth = depth
        self.children = children
    }
}

/// An unresolved TOC node: what the file said, before paths are resolved and ids assigned.
struct RawTOCNode {
    var title: String
    var href: String?
    var children: [RawTOCNode]
}

/// Table-of-contents parsing for both EPUB 3 navigation documents and EPUB 2 NCX files.
/// Both return nil when the file cannot be parsed at all, so the caller can fall back.
enum TOCParser {
    // MARK: EPUB 3 navigation document

    /// Parses `<nav epub:type="toc">` (the first nav that is not landmarks/page-list when no nav
    /// is typed "toc") out of an XHTML navigation document.
    static func parseNavDocument(_ data: Data, path: String) -> [TOCEntry]? {
        guard let root = XMLTreeNode.parse(data, mode: .xhtml) else { return nil }
        let navs = root.descendants { $0.name == "nav" }

        func types(_ nav: XMLTreeNode) -> Set<String> {
            Set((nav.attribute("type") ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        }
        let chosen = navs.first { types($0).contains("toc") }
            ?? navs.first { types($0).isDisjoint(with: ["landmarks", "page-list"]) }
        guard let nav = chosen else { return nil }

        let nodes = lists(in: nav).flatMap(parseList)
        return build(nodes, basePath: path)
    }

    /// The outermost `ol`/`ul` elements below `node`, not looking inside them or inside links.
    private static func lists(in node: XMLTreeNode) -> [XMLTreeNode] {
        node.elements.flatMap { child -> [XMLTreeNode] in
            switch child.name {
            case "ol", "ul": return [child]
            case "a", "span": return []
            default: return lists(in: child)
            }
        }
    }

    /// The first link or span of a list item, looking through wrapper elements but not into
    /// nested lists.
    private static func label(of li: XMLTreeNode) -> XMLTreeNode? {
        for child in li.elements {
            switch child.name {
            case "a", "span": return child
            case "ol", "ul": continue
            default: if let found = label(of: child) { return found }
            }
        }
        return nil
    }

    private static func parseList(_ list: XMLTreeNode) -> [RawTOCNode] {
        var nodes: [RawTOCNode] = []
        for li in list.elements where li.name == "li" {
            let link = label(of: li)
            let title = link?.collapsedText ?? ""
            let href = link?.name == "a" ? link?.attribute("href") : nil
            let children = lists(in: li).flatMap(parseList)
            if title.isEmpty {
                nodes.append(contentsOf: children)   // nothing to show: lift the children up
            } else {
                nodes.append(RawTOCNode(title: title, href: href, children: children))
            }
        }
        return nodes
    }

    // MARK: EPUB 2 NCX

    /// Parses `navMap > navPoint` (nested), `navLabel > text`, `content@src`.
    static func parseNCX(_ data: Data, path: String) -> [TOCEntry]? {
        guard let root = XMLTreeNode.parseLeniently(data), root.name == "ncx",
              let navMap = root.firstElement(named: "navMap") else { return nil }
        return build(parseNavPoints(in: navMap), basePath: path)
    }

    private static func parseNavPoints(in parent: XMLTreeNode) -> [RawTOCNode] {
        var nodes: [RawTOCNode] = []
        for point in parent.elements(named: "navPoint") {
            let title = point.firstElement(named: "navLabel")?
                .firstDescendant { $0.name == "text" }?.collapsedText ?? ""
            let href = point.firstElement(named: "content")?.attribute("src")
            let children = parseNavPoints(in: point)
            if title.isEmpty {
                nodes.append(contentsOf: children)
            } else {
                nodes.append(RawTOCNode(title: title, href: href, children: children))
            }
        }
        return nodes
    }

    // MARK: Shared

    /// Resolves hrefs against the TOC file's own path, splits fragments, and numbers the
    /// entries in preorder.
    static func build(_ nodes: [RawTOCNode], basePath: String) -> [TOCEntry] {
        var counter = 0

        func make(_ nodes: [RawTOCNode], depth: Int) -> [TOCEntry] {
            var entries: [TOCEntry] = []
            for node in nodes {
                let id = counter
                counter += 1
                let (path, fragment) = resolve(node.href, basePath: basePath)
                let children = make(node.children, depth: depth + 1)
                entries.append(TOCEntry(id: id, title: node.title, path: path, fragment: fragment,
                                        depth: depth, children: children))
            }
            return entries
        }
        return make(nodes, depth: 0)
    }

    private static func resolve(_ href: String?, basePath: String) -> (path: String?, fragment: String?) {
        guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty,
              !EPUBPath.isExternal(href) else { return (nil, nil) }
        let (rawPath, rawFragment) = EPUBPath.split(href)
        let fragment = rawFragment.map { $0.removingPercentEncoding ?? $0 }
        return (EPUBPath.resolve(rawPath, relativeTo: basePath), fragment)
    }
}
