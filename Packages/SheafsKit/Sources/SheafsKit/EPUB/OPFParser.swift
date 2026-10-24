import Foundation

/// The parsed contents of an OPF package document (before the archive is consulted).
struct OPFPackage {
    var version: String?
    var metadata: EPUBMetadata
    /// Every manifest item, in document order.
    var manifest: [EPUBManifestItem]
    var spine: [EPUBSpineItem]
    /// `spine@toc`: the manifest id of the NCX, if declared.
    var spineTocID: String?
    /// `<meta name="cover" content="ID">`: a manifest id (EPUB 2 convention, still common).
    var coverMetaID: String?
}

enum OPFParser {
    static func parse(_ data: Data, opfPath: String) throws -> OPFPackage {
        guard let root = XMLTreeNode.parseLeniently(data) else {
            throw EPUBError.malformedOPF("The package document is not well-formed XML.")
        }
        guard root.name == "package" else {
            throw EPUBError.malformedOPF("The root element is <\(root.name)>, expected <package>.")
        }
        guard let manifestNode = root.firstElement(named: "manifest") else {
            throw EPUBError.malformedOPF("The package has no <manifest>.")
        }
        guard let spineNode = root.firstElement(named: "spine") else {
            throw EPUBError.malformedOPF("The package has no <spine>.")
        }

        let metadataNodes = root.firstElement(named: "metadata")?.elements ?? []
        let metadata = parseMetadata(metadataNodes, uniqueIdentifierID: root.attribute("unique-identifier"))

        // Manifest. Remote resources (absolute URLs) have no place in the archive.
        var manifest: [EPUBManifestItem] = []
        var itemsByID: [String: EPUBManifestItem] = [:]
        for node in manifestNode.elements(named: "item") {
            guard let id = node.attribute("id"), !id.isEmpty,
                  let href = node.attribute("href"), !href.isEmpty, !EPUBPath.isExternal(href),
                  itemsByID[id] == nil else { continue }
            let properties = Set((node.attribute("properties") ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            let item = EPUBManifestItem(
                id: id,
                path: EPUBPath.resolve(href, relativeTo: opfPath),
                mediaType: node.attribute("media-type") ?? "",
                properties: properties)
            manifest.append(item)
            itemsByID[id] = item
        }

        // Spine: itemrefs that point at something real. `linear="no"` marks auxiliary content.
        var spine: [EPUBSpineItem] = []
        for node in spineNode.elements(named: "itemref") {
            guard let idref = node.attribute("idref"), let item = itemsByID[idref] else { continue }
            let linear = (node.attribute("linear") ?? "yes").trimmingCharacters(in: .whitespaces).lowercased() != "no"
            spine.append(EPUBSpineItem(idref: idref, linear: linear, item: item))
        }

        let coverMetaID = metadataNodes
            .first { $0.name == "meta" && $0.attribute("name") == "cover" }?
            .attribute("content")

        return OPFPackage(
            version: root.attribute("version"),
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            spineTocID: spineNode.attribute("toc"),
            coverMetaID: coverMetaID)
    }

    // MARK: Metadata

    private struct Refinement {
        let property: String
        let value: String
    }

    private static func parseMetadata(_ nodes: [XMLTreeNode], uniqueIdentifierID: String?) -> EPUBMetadata {
        // EPUB 3 refinements: <meta refines="#id" property="...">value</meta>
        var refinements: [String: [Refinement]] = [:]
        for node in nodes where node.name == "meta" {
            if let refines = node.attribute("refines"), refines.hasPrefix("#"), let property = node.attribute("property") {
                refinements[String(refines.dropFirst()), default: []]
                    .append(Refinement(property: property, value: node.collapsedText))
            }
        }
        func refinement(of node: XMLTreeNode, _ property: String) -> String? {
            guard let id = node.attribute("id") else { return nil }
            return refinements[id]?.first { $0.property == property }?.value
        }
        func texts(_ name: String) -> [String] {
            nodes.filter { $0.name == name }.map(\.collapsedText).filter { !$0.isEmpty }
        }

        var metadata = EPUBMetadata()

        let titles = nodes.filter { $0.name == "title" && !$0.collapsedText.isEmpty }
        let mainTitle = titles.first { refinement(of: $0, "title-type") == "main" } ?? titles.first
        metadata.title = mainTitle?.collapsedText ?? ""

        metadata.authors = texts("creator")
        metadata.language = texts("language").first

        let identifiers = nodes.filter { $0.name == "identifier" && !$0.collapsedText.isEmpty }
        let uniqueIdentifier = uniqueIdentifierID.flatMap { id in identifiers.first { $0.attribute("id") == id } }
        metadata.identifier = (uniqueIdentifier ?? identifiers.first)?.collapsedText

        metadata.publisher = texts("publisher").first

        // Descriptions are often HTML, either escaped text or real child elements.
        if let description = nodes.first(where: { $0.name == "description" && !$0.collapsedText.isEmpty }) {
            let raw = description.textContent
            let plain = raw.contains("<") ? XHTMLEntities.plainText(fromHTML: raw) : XHTMLEntities.collapseWhitespace(raw)
            metadata.description = plain.isEmpty ? nil : plain
        }

        // EPUB 2 packages may carry several dates distinguished by opf:event.
        let dates = nodes.filter { $0.name == "date" && !$0.collapsedText.isEmpty }
        let date = dates.first { $0.attribute("event")?.lowercased() == "publication" } ?? dates.first
        metadata.published = date?.collapsedText

        metadata.modified = nodes
            .first { $0.name == "meta" && $0.attribute("property") == "dcterms:modified" && !$0.collapsedText.isEmpty }?
            .collapsedText

        // Series, EPUB 3 form: a collection whose collection-type is "series".
        let collections = nodes.filter {
            $0.name == "meta" && $0.attribute("property") == "belongs-to-collection" && !$0.collapsedText.isEmpty
        }
        let collection = collections.first { refinement(of: $0, "collection-type") == "series" }
            ?? collections.first { refinement(of: $0, "collection-type") == nil }
        if let collection {
            metadata.series = collection.collapsedText
            metadata.seriesIndex = refinement(of: collection, "group-position").flatMap(parseNumber)
        } else if let calibre = nodes.first(where: { $0.name == "meta" && $0.attribute("name") == "calibre:series" }),
                  let name = calibre.attribute("content").map(XHTMLEntities.collapseWhitespace), !name.isEmpty {
            // Series, calibre / EPUB 2 form.
            metadata.series = name
            metadata.seriesIndex = nodes
                .first { $0.name == "meta" && $0.attribute("name") == "calibre:series_index" }?
                .attribute("content").flatMap(parseNumber)
        }

        return metadata
    }

    private static func parseNumber(_ string: String) -> Double? {
        Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Cover

extension OPFPackage {
    /// Finds the cover image among the manifest items. In order:
    /// 1. the item with the EPUB 3 `cover-image` property;
    /// 2. the item named by `<meta name="cover">` (if that is an XHTML page, the first image it shows);
    /// 3. any image whose id or path contains "cover".
    ///
    /// `loadPage` supplies the bytes of a manifest item, for step 2's page lookup.
    func findCover(loadPage: (EPUBManifestItem) -> Data?) -> EPUBManifestItem? {
        func isImage(_ item: EPUBManifestItem) -> Bool { item.mediaType.lowercased().hasPrefix("image/") }

        if let item = manifest.first(where: { $0.properties.contains("cover-image") && isImage($0) }) {
            return item
        }

        if let id = coverMetaID, let item = manifest.first(where: { $0.id == id }) {
            if isImage(item) { return item }
            if let data = loadPage(item),
               let imagePath = OPFPackage.firstImagePath(inPage: data, pagePath: item.path),
               let image = manifest.first(where: { $0.path == imagePath && isImage($0) }) {
                return image
            }
        }

        return manifest.first { item in
            isImage(item) && (item.id.lowercased().contains("cover") || item.path.lowercased().contains("cover"))
        }
    }

    /// The zip path of the first `<img src>` or SVG `<image href>` in an (X)HTML page.
    static func firstImagePath(inPage data: Data, pagePath: String) -> String? {
        guard let root = XMLTreeNode.parse(data, mode: .xhtml) else { return nil }
        var source: String?
        _ = root.firstDescendant { node in
            if node.name == "img", let src = node.attribute("src"), !src.isEmpty { source = src; return true }
            if node.name == "image", let href = node.attribute("href"), !href.isEmpty { source = href; return true }
            return false
        }
        guard let source, !EPUBPath.isExternal(source) else { return nil }
        return EPUBPath.resolve(source, relativeTo: pagePath)
    }
}
