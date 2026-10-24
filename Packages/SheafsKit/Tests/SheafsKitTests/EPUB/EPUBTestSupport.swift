import Foundation
@testable import SheafsKit

/// Fixture loading, the Python reference model, and a tiny ZIP writer for building
/// synthetic archives, shared by the ZIP and EPUB tests.
enum EPUBTestSupport {
    /// The EPUB fixtures that have an entry in epub-reference.json (without extension).
    static let fixtureNames = ["alice-epub3", "pride-epub2", "hub-fixture"]

    struct MissingFixture: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixture \(name) is missing from the test bundle." }
    }

    static func fixtureURL(_ name: String, extension ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw MissingFixture(name: "\(name).\(ext)")
        }
        return url
    }

    static func epubURL(_ name: String) throws -> URL { try fixtureURL(name, extension: "epub") }

    static func epubData(_ name: String) throws -> Data { try Data(contentsOf: epubURL(name)) }

    static func reference(_ name: String) throws -> EPUBReference {
        let data = try Data(contentsOf: fixtureURL("epub-reference", extension: "json"))
        let all = try JSONDecoder().decode([String: EPUBReference].self, from: data)
        guard let reference = all["\(name).epub"] else { throw MissingFixture(name: "reference for \(name)") }
        return reference
    }
}

/// One fixture's facts as computed by scripts/gen_epub_reference.py (zipfile + ElementTree).
struct EPUBReference: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let path: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let crc32: UInt32
        let isDirectory: Bool
        let head4096Crc32: UInt32
    }

    struct SpineRow: Decodable, Sendable {
        let path: String
        let linear: Bool
        let size: Int
        let crc32: UInt32
        let head4096Crc32: UInt32
    }

    struct TOCRow: Decodable, Sendable {
        let depth: Int
        let title: String
        let path: String?
        let fragment: String?
    }

    let entries: [Entry]
    let opfPath: String
    let version: String?
    let title: String
    let authors: [String]
    let language: String?
    let identifier: String?
    let publisher: String?
    let published: String?
    let modified: String?
    let series: String?
    let seriesIndex: Double?
    let manifestCount: Int
    let spine: [SpineRow]
    let coverPath: String?
    let toc: [TOCRow]
}

// MARK: - Synthetic archives

/// Writes ZIP files, including the awkward variants real readers meet: data descriptors,
/// differing local/central extra fields, ZIP64 records, comments, odd name encodings.
struct TestZipBuilder {
    struct File {
        var name: String
        var data: Data
        /// Compress with deflate (method 8) instead of storing.
        var deflate = false
        var flags: UInt16 = 0
        /// Overrides the method written in both headers (the payload is still `data` as is).
        var methodOverride: UInt16?
        /// Bytes appended to the local header's extra field only.
        var localExtra = Data()
        /// Writes sizes/offset into a ZIP64 extra field and saturates the 32-bit fields.
        var zip64 = false
        /// Sets bit 3: local header carries zeros, sizes follow the data.
        var dataDescriptor = false
        /// Raw name bytes, for names that are not valid UTF-8.
        var rawName: [UInt8]?
    }

    var files: [File] = []
    var comment = Data()
    /// Writes a ZIP64 end-of-central-directory record and locator.
    var zip64End = false

    mutating func add(_ name: String, _ data: Data, deflate: Bool = false) {
        files.append(File(name: name, data: data, deflate: deflate))
    }

    mutating func add(_ name: String, _ text: String, deflate: Bool = false) {
        add(name, Data(text.utf8), deflate: deflate)
    }

    /// Raw DEFLATE (no zlib header), which is what ZIP stores.
    static func deflate(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
    }

    func build() -> Data {
        var out = Data()
        var central = Data()

        for file in files {
            let offset = out.count
            let payload = file.deflate ? TestZipBuilder.deflate(file.data) : file.data
            let method = file.methodOverride ?? (file.deflate ? 8 : 0)
            let crc = CRC32.checksum(file.data)
            let flags = file.flags | (file.dataDescriptor ? 0x0008 : 0)
            let name = file.rawName.map { Data($0) } ?? Data(file.name.utf8)

            out.le(UInt32(0x0403_4B50))
            out.le(UInt16(20)); out.le(flags); out.le(method); out.le(UInt16(0)); out.le(UInt16(33))
            out.le(file.dataDescriptor ? 0 : crc)
            out.le(file.dataDescriptor ? 0 : UInt32(payload.count))
            out.le(file.dataDescriptor ? 0 : UInt32(file.data.count))
            out.le(UInt16(name.count)); out.le(UInt16(file.localExtra.count))
            out.append(name); out.append(file.localExtra); out.append(payload)
            if file.dataDescriptor {
                out.le(UInt32(0x0807_4B50)); out.le(crc)
                out.le(UInt32(payload.count)); out.le(UInt32(file.data.count))
            }

            var extra = Data()
            if file.zip64 {
                extra.le(UInt16(1)); extra.le(UInt16(24))
                extra.le(UInt64(file.data.count)); extra.le(UInt64(payload.count)); extra.le(UInt64(offset))
            }
            central.le(UInt32(0x0201_4B50))
            central.le(UInt16(20)); central.le(UInt16(20)); central.le(flags); central.le(method)
            central.le(UInt16(0)); central.le(UInt16(33)); central.le(crc)
            central.le(file.zip64 ? 0xFFFF_FFFF : UInt32(payload.count))
            central.le(file.zip64 ? 0xFFFF_FFFF : UInt32(file.data.count))
            central.le(UInt16(name.count)); central.le(UInt16(extra.count)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0))
            central.le(file.zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.append(name); central.append(extra)
        }

        let centralOffset = out.count
        out.append(central)

        if zip64End {
            let recordOffset = out.count
            out.le(UInt32(0x0606_4B50)); out.le(UInt64(44))
            out.le(UInt16(45)); out.le(UInt16(45)); out.le(UInt32(0)); out.le(UInt32(0))
            out.le(UInt64(files.count)); out.le(UInt64(files.count))
            out.le(UInt64(central.count)); out.le(UInt64(centralOffset))
            out.le(UInt32(0x0706_4B50)); out.le(UInt32(0)); out.le(UInt64(recordOffset)); out.le(UInt32(1))
        }
        out.le(UInt32(0x0605_4B50))
        out.le(UInt16(0)); out.le(UInt16(0))
        out.le(zip64End ? 0xFFFF : UInt16(files.count)); out.le(zip64End ? 0xFFFF : UInt16(files.count))
        out.le(zip64End ? 0xFFFF_FFFF : UInt32(central.count))
        out.le(zip64End ? 0xFFFF_FFFF : UInt32(centralOffset))
        out.le(UInt16(comment.count))
        out.append(comment)
        return out
    }

    // MARK: EPUB convenience

    /// A minimal EPUB: stored `mimetype`, container.xml pointing at `opfPath`, the OPF, and
    /// `files`. Deflates everything except `mimetype`.
    static func epub(opf: String, opfPath: String = "OEBPS/content.opf",
                     files: [(String, String)] = [], container: String? = nil) -> Data {
        var zip = TestZipBuilder()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/container.xml", container ?? """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, deflate: true)
        zip.add(opfPath, opf, deflate: true)
        for (name, text) in files { zip.add(name, text, deflate: true) }
        return zip.build()
    }
}

fileprivate extension Data {
    mutating func le(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
