import Foundation

/// A tiny namespace-agnostic XML tree built on Foundation's `XMLParser`.
///
/// EPUB packages use `dc:`/`opf:`/`epub:` prefixes and default namespaces inconsistently, so the
/// tree throws namespaces away: element names are local names ("dc:title" -> "title") and
/// attributes are looked up by local name. Internal to the EPUB parsers; never escapes them.
final class XMLTreeNode {
    /// Local element name, or "#text" for character data.
    let name: String
    /// Attributes keyed by their qualified name as written ("epub:type", "id").
    let attributes: [String: String]
    private(set) var children: [XMLTreeNode] = []
    /// Character data, for "#text" nodes.
    private(set) var text: String = ""

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    fileprivate init(text: String) {
        self.name = "#text"
        self.attributes = [:]
        self.text = text
    }

    fileprivate func append(_ child: XMLTreeNode) { children.append(child) }
    fileprivate func appendText(_ string: String) {
        if let last = children.last, last.name == "#text" {
            last.text += string
        } else {
            children.append(XMLTreeNode(text: string))
        }
    }

    /// Child elements (no text nodes), in document order.
    var elements: [XMLTreeNode] { children.filter { $0.name != "#text" } }

    func elements(named name: String) -> [XMLTreeNode] { children.filter { $0.name == name } }
    func firstElement(named name: String) -> XMLTreeNode? { children.first { $0.name == name } }

    /// The attribute with local name `local`; an unprefixed attribute wins over a prefixed one
    /// ("type" matches "type" first, then "epub:type").
    func attribute(_ local: String) -> String? {
        if let exact = attributes[local] { return exact }
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) where XMLTreeNode.localName(key) == local {
            return value
        }
        return nil
    }

    /// All character data below this node, in document order.
    var textContent: String {
        if name == "#text" { return text }
        return children.map(\.textContent).joined()
    }

    /// `textContent` with whitespace runs collapsed to single spaces.
    var collapsedText: String { XHTMLEntities.collapseWhitespace(textContent) }

    /// Depth-first search, document order, for the first descendant satisfying `predicate`
    /// (not including self).
    func firstDescendant(where predicate: (XMLTreeNode) -> Bool) -> XMLTreeNode? {
        for child in children where child.name != "#text" {
            if predicate(child) { return child }
            if let found = child.firstDescendant(where: predicate) { return found }
        }
        return nil
    }

    /// Every descendant element satisfying `predicate`, document order.
    func descendants(where predicate: (XMLTreeNode) -> Bool) -> [XMLTreeNode] {
        var result: [XMLTreeNode] = []
        for child in children where child.name != "#text" {
            if predicate(child) { result.append(child) }
            result.append(contentsOf: child.descendants(where: predicate))
        }
        return result
    }

    static func localName(_ qualified: String) -> String {
        if let colon = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: colon)...]) }
        return qualified
    }

    // MARK: Parsing

    enum Mode {
        /// Parse the bytes as they are. For files that are well-formed XML.
        case strict
        /// Pre-process as XHTML: no DOCTYPE, HTML entities replaced.
        case xhtml
    }

    /// Parses `data` and returns the root element, or nil if it is not well-formed.
    static func parse(_ data: Data, mode: Mode = .strict) -> XMLTreeNode? {
        let input = mode == .xhtml ? XHTMLEntities.sanitizeXHTML(data) : data
        let builder = Builder()
        let parser = XMLParser(data: input)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), builder.stack.isEmpty else { return nil }
        return builder.root
    }

    /// Strict first, then the lenient XHTML treatment, for XML files that are supposed to be
    /// well-formed but sometimes are not (stray HTML entities in an OPF description).
    static func parseLeniently(_ data: Data) -> XMLTreeNode? {
        parse(data, mode: .strict) ?? parse(data, mode: .xhtml)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTreeNode?
        var stack: [XMLTreeNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLTreeNode(name: XMLTreeNode.localName(elementName), attributes: attributeDict)
            if let parent = stack.last { parent.append(node) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.appendText(String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}
