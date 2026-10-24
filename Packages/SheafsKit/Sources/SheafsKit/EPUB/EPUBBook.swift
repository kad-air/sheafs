import Foundation

/// A file listed in the package manifest.
public struct EPUBManifestItem: Hashable, Sendable, Identifiable {
    /// The manifest id, which spine entries and `<meta name="cover">` refer to.
    public let id: String
    /// Zip path of the file: resolved against the OPF, percent-decoded, `./` and `../` folded.
    public let path: String
    public let mediaType: String
    /// Space-separated `properties` split into a set (`nav`, `cover-image`, `svg`, ...).
    public let properties: Set<String>

    public init(id: String, path: String, mediaType: String, properties: Set<String> = []) {
        self.id = id
        self.path = path
        self.mediaType = mediaType
        self.properties = properties
    }
}

/// One entry of the reading order.
public struct EPUBSpineItem: Hashable, Sendable {
    public let idref: String
    /// False for `linear="no"` items, which sit outside the main reading flow.
    public let linear: Bool
    public let item: EPUBManifestItem

    public init(idref: String, linear: Bool, item: EPUBManifestItem) {
        self.idref = idref
        self.linear = linear
        self.item = item
    }
}

public enum EPUBError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The archive has no `META-INF/container.xml`.
    case missingContainer
    /// `container.xml` names no package document.
    case missingRootfile
    /// `container.xml` points at a package document that is not in the archive.
    case missingOPF(String)
    /// The package document cannot be used; the string says why.
    case malformedOPF(String)
    /// No manifest item has this id.
    case missingManifestItem(String)

    public var description: String {
        switch self {
        case .missingContainer:
            return "The EPUB has no META-INF/container.xml."
        case .missingRootfile:
            return "The EPUB's container.xml does not name a package document."
        case let .missingOPF(path):
            return "The EPUB's package document \"\(path)\" is missing."
        case let .malformedOPF(reason):
            return "The EPUB's package document is malformed. \(reason)"
        case let .missingManifestItem(id):
            return "The EPUB has no manifest item with id \"\(id)\"."
        }
    }

    public var errorDescription: String? { description }
}

/// An opened EPUB: package metadata, manifest, reading order, table of contents and cover,
/// plus access to the bytes of every file.
///
/// Everything is parsed once in `init` and immutable afterwards, and the archive is immutable
/// (memory-mapped) data, so one `EPUBBook` can be read from many threads at once.
public final class EPUBBook: Sendable {
    /// Where the book was opened from; nil when opened from in-memory data.
    public let url: URL?
    public let archive: ZipArchive
    /// Zip path of the package document.
    public let opfPath: String
    /// The package `version` attribute ("2.0", "3.0").
    public let version: String?
    public let metadata: EPUBMetadata
    /// Manifest items by id.
    public let manifest: [String: EPUBManifestItem]
    /// The whole spine, non-linear items included, in OPF order.
    public let spine: [EPUBSpineItem]
    /// Nested table of contents; empty when the book has none or it cannot be read.
    public let toc: [TOCEntry]
    /// The cover image, if one could be identified.
    public let coverItem: EPUBManifestItem?

    private let manifestByPath: [String: EPUBManifestItem]
    private let spineIndexByPath: [String: Int]
    private let flatTOC: [TOCEntry]

    /// Opens the EPUB at `url` (memory-mapped).
    public convenience init(url: URL) throws {
        try self.init(archive: ZipArchive(url: url), url: url)
    }

    /// Opens an EPUB held in memory.
    public convenience init(data: Data) throws {
        try self.init(archive: ZipArchive(data: data), url: nil)
    }

    private init(archive: ZipArchive, url: URL?) throws {
        // META-INF/container.xml -> package document path.
        guard let containerEntry = archive.entry(at: "META-INF/container.xml") else { throw EPUBError.missingContainer }
        let containerData = try archive.data(for: containerEntry)
        guard let container = XMLTreeNode.parseLeniently(containerData),
              let rootfile = container.firstDescendant(where: {
                  $0.name == "rootfile" && !($0.attribute("full-path") ?? "").isEmpty
              }),
              let fullPath = rootfile.attribute("full-path") else { throw EPUBError.missingRootfile }
        guard let opfEntry = archive.entry(at: fullPath) else { throw EPUBError.missingOPF(fullPath) }

        let package = try OPFParser.parse(try archive.data(for: opfEntry), opfPath: opfEntry.path)

        var manifest: [String: EPUBManifestItem] = [:]
        var manifestByPath: [String: EPUBManifestItem] = [:]
        for item in package.manifest {
            manifest[item.id] = item
            if manifestByPath[item.path] == nil { manifestByPath[item.path] = item }
        }
        var spineIndexByPath: [String: Int] = [:]
        for (index, entry) in package.spine.enumerated() where spineIndexByPath[entry.item.path] == nil {
            spineIndexByPath[entry.item.path] = index
        }

        let toc = EPUBBook.loadTOC(package: package, archive: archive)

        self.url = url
        self.archive = archive
        self.opfPath = opfEntry.path
        self.version = package.version
        self.metadata = package.metadata
        self.manifest = manifest
        self.spine = package.spine
        self.toc = toc
        self.coverItem = package.findCover { try? archive.data(at: $0.path) }
        self.manifestByPath = manifestByPath
        self.spineIndexByPath = spineIndexByPath
        self.flatTOC = EPUBBook.flatten(toc)
    }

    // MARK: Reading

    /// The bytes of a manifest item.
    public func data(for item: EPUBManifestItem) throws -> Data {
        try archive.data(at: item.path)
    }

    /// The bytes of the file at a zip path (also accepts the percent-encoded form).
    public func data(at path: String) throws -> Data {
        try archive.data(at: path)
    }

    /// The bytes of the manifest item with this id; throws `EPUBError.missingManifestItem` if none.
    public func data(forManifestID id: String) throws -> Data {
        guard let item = manifest[id] else { throw EPUBError.missingManifestItem(id) }
        return try data(for: item)
    }

    /// The cover image file's bytes, or nil if the book has no identifiable cover.
    public func coverImageData() throws -> Data? {
        guard let coverItem else { return nil }
        return try data(for: coverItem)
    }

    // MARK: Lookup

    /// The position in ``spine`` of the item at this exact normalized zip path. (When an item
    /// appears more than once, the first position.)
    public func spineIndex(forPath path: String) -> Int? {
        spineIndexByPath[path]
    }

    /// The manifest item at this exact normalized zip path.
    public func manifestItem(atPath path: String) -> EPUBManifestItem? {
        manifestByPath[path]
    }

    /// The table of contents flattened in preorder (parents before their children).
    public var flattenedTOC: [TOCEntry] { flatTOC }

    // MARK: Table of contents

    /// EPUB 3 navigation document first, then the NCX. A table of contents that cannot be found
    /// or read is never an error: the book just has none.
    private static func loadTOC(package: OPFPackage, archive: ZipArchive) -> [TOCEntry] {
        if let nav = package.manifest.first(where: { $0.properties.contains("nav") }),
           let data = try? archive.data(at: nav.path),
           let entries = TOCParser.parseNavDocument(data, path: nav.path), !entries.isEmpty {
            return entries
        }

        // spine@toc names the NCX; otherwise take whatever is typed as one.
        var candidates: [EPUBManifestItem] = []
        if let id = package.spineTocID, let item = package.manifest.first(where: { $0.id == id }) {
            candidates.append(item)
        }
        candidates.append(contentsOf: package.manifest.filter { $0.mediaType == "application/x-dtbncx+xml" })
        for ncx in candidates {
            if let data = try? archive.data(at: ncx.path),
               let entries = TOCParser.parseNCX(data, path: ncx.path), !entries.isEmpty {
                return entries
            }
        }
        return []
    }

    private static func flatten(_ entries: [TOCEntry]) -> [TOCEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }
}
