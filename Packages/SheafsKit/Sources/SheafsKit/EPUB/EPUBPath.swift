import Foundation

/// Path arithmetic for hrefs inside an EPUB.
///
/// EPUB hrefs are URLs relative to the file that contains them. The archive stores plain
/// forward-slash paths, so everything here converts to that form: percent-decoded, with `.`
/// and `..` folded away, no leading slash, case preserved.
public enum EPUBPath {
    /// Resolves `href` against the zip path of the file it appears in and returns the zip path
    /// of the target, without any fragment or query.
    ///
    ///     resolve("../Images/a.png", relativeTo: "OEBPS/Text/ch1.xhtml")  // "OEBPS/Images/a.png"
    ///     resolve("ch%201.xhtml",    relativeTo: "OEBPS/content.opf")      // "OEBPS/ch 1.xhtml"
    ///     resolve("#note3",          relativeTo: "OEBPS/Text/ch1.xhtml")   // "OEBPS/Text/ch1.xhtml"
    ///     resolve("/OEBPS/a.css",    relativeTo: "OEBPS/Text/ch1.xhtml")   // "OEBPS/a.css"
    ///
    /// `..` never climbs above the archive root. An external href (`http:`, `mailto:`, ...)
    /// has no zip path and is returned unchanged; check with ``isExternal(_:)`` first.
    public static func resolve(_ href: String, relativeTo basePath: String) -> String {
        if isExternal(href) { return href }

        var path = split(href).path
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        // Decode after splitting off '#' and '?', so an encoded "%23" stays part of the name.
        path = path.removingPercentEncoding ?? path

        var components: [Substring] = []
        if path.hasPrefix("/") {
            // Absolute from the archive root.
        } else if path.isEmpty {
            // "#fragment" or "": the same document.
            return normalize(basePath)
        } else {
            var base = basePath.split(separator: "/", omittingEmptySubsequences: true)
            if !basePath.hasSuffix("/") { _ = base.popLast() }   // drop the file name
            components = base
        }
        components.append(contentsOf: path.split(separator: "/", omittingEmptySubsequences: true))
        return fold(components)
    }

    /// Splits an href at its first `#`. Nothing is decoded. An empty fragment ("a.xhtml#")
    /// comes back as nil.
    public static func split(_ href: String) -> (path: String, fragment: String?) {
        guard let hash = href.firstIndex(of: "#") else { return (href, nil) }
        let fragment = String(href[href.index(after: hash)...])
        return (String(href[..<hash]), fragment.isEmpty ? nil : fragment)
    }

    /// Whether `href` starts with a URL scheme (`http:`, `https:`, `mailto:`, `data:`, ...) and
    /// so does not point into the archive.
    public static func isExternal(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":"), colon != href.startIndex else { return false }
        let scheme = href[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    /// Folds `.`, `..` and repeated slashes out of an already-decoded path.
    static func normalize(_ path: String) -> String {
        fold(path.split(separator: "/", omittingEmptySubsequences: true))
    }

    private static func fold(_ components: [Substring]) -> String {
        var result: [Substring] = []
        for component in components {
            switch component {
            case ".": continue
            case "..": _ = result.popLast()
            default: result.append(component)
            }
        }
        return result.joined(separator: "/")
    }
}
