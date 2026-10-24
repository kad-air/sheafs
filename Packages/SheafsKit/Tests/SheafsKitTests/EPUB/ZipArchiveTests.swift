import Foundation
import Testing
@testable import SheafsKit

@Suite("ZipArchive")
struct ZipArchiveTests {
    // MARK: CRC-32

    @Test func crc32MatchesPublishedCheckValues() {
        // The standard CRC-32 check value, and two other well-known vectors.
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)

        var incremental = CRC32()
        incremental.update(Data("1234".utf8))
        incremental.update(Data("56789".utf8))
        #expect(incremental.value == 0xCBF4_3926)
    }

    // MARK: Real EPUBs against Python's zipfile

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func centralDirectoryMatchesPythonZipfile(name: String) throws {
        let reference = try EPUBTestSupport.reference(name)
        let archive = try ZipArchive(url: EPUBTestSupport.epubURL(name))

        #expect(archive.entries.count == reference.entries.count)
        for (entry, expected) in zip(archive.entries, reference.entries) {
            #expect(entry.path == expected.path)
            #expect(Int(entry.method) == expected.method, "method of \(entry.path)")
            #expect(entry.compressedSize == expected.compressedSize, "compressed size of \(entry.path)")
            #expect(entry.uncompressedSize == expected.uncompressedSize, "size of \(entry.path)")
            #expect(entry.crc32 == expected.crc32, "crc32 of \(entry.path)")
            #expect(entry.isDirectory == expected.isDirectory)
        }
    }

    /// Every entry is inflated by SheafsKit and compared with what zlib produced in Python:
    /// the size, the CRC-32 of the whole entry (also checked internally against the directory),
    /// and the CRC-32 of the first 4096 bytes.
    @Test(arguments: EPUBTestSupport.fixtureNames)
    func everyEntryInflatesToTheSameBytesAsPython(name: String) throws {
        let reference = try EPUBTestSupport.reference(name)
        let archive = try ZipArchive(url: EPUBTestSupport.epubURL(name))
        var deflated = 0

        for expected in reference.entries {
            let entry = try #require(archive.entry(at: expected.path))
            let data = try archive.data(for: entry)
            #expect(data.count == expected.uncompressedSize, "size of \(expected.path)")
            #expect(CRC32.checksum(data) == expected.crc32, "crc32 of \(expected.path)")
            #expect(CRC32.checksum(data.prefix(4096)) == expected.head4096Crc32, "head of \(expected.path)")
            if expected.method == 8 { deflated += 1 }
        }
        // The point of the test is the inflater, so make sure there was something to inflate.
        #expect(deflated > 0)
    }

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func mimetypeIsStoredAndReadsAsEPUB(name: String) throws {
        let archive = try ZipArchive(url: EPUBTestSupport.epubURL(name))
        let entry = try #require(archive.entry(at: "mimetype"))
        #expect(entry.method == 0)
        #expect(entry.compressedSize == entry.uncompressedSize)
        #expect(String(decoding: try archive.data(for: entry), as: UTF8.self) == "application/epub+zip")
    }

    @Test func dataInitMatchesMemoryMappedInit() throws {
        let url = try EPUBTestSupport.epubURL("alice-epub3")
        let mapped = try ZipArchive(url: url)
        let copied = try ZipArchive(data: Data(contentsOf: url))
        #expect(mapped.entries == copied.entries)
        #expect(try mapped.data(at: "OEBPS/content.opf") == copied.data(at: "OEBPS/content.opf"))
    }

    @Test func concurrentReadsGiveIdenticalResults() async throws {
        let archive = try ZipArchive(url: EPUBTestSupport.epubURL("alice-epub3"))
        let paths = archive.entries.filter { !$0.isDirectory }.map(\.path)
        let expectedBytes = archive.entries.reduce(0) { $0 + $1.uncompressedSize }

        let totals = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try paths.reduce(0) { $0 + (try archive.data(at: $1)).count } }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(totals == Array(repeating: expectedBytes, count: 8))
    }

    // MARK: Lookup

    @Test func missingPathThrowsEntryNotFound() throws {
        let archive = try ZipArchive(url: EPUBTestSupport.epubURL("alice-epub3"))
        #expect(archive.entry(at: "nope.txt") == nil)
        #expect(!archive.contains("nope.txt"))
        #expect(throws: ZipError.entryNotFound("nope.txt")) { try archive.data(at: "nope.txt") }
    }

    @Test func lookupIsCaseSensitiveButAcceptsPercentEncoding() throws {
        var zip = TestZipBuilder()
        zip.add("OEBPS/ch 1.xhtml", "one")
        let archive = try ZipArchive(data: zip.build())

        #expect(archive.contains("OEBPS/ch 1.xhtml"))
        #expect(archive.contains("OEBPS/ch%201.xhtml"))
        #expect(!archive.contains("oebps/ch 1.xhtml"))
        #expect(String(decoding: try archive.data(at: "OEBPS/ch%201.xhtml"), as: UTF8.self) == "one")
    }

    // MARK: Damage

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func truncatedArchivesThrowInsteadOfCrashing(name: String) throws {
        let full = try EPUBTestSupport.epubData(name)
        for dropped in [1, 22, 23, 100, 500, full.count / 2] {
            let cut = full.prefix(full.count - dropped)
            #expect(throws: ZipError.truncated, "dropping \(dropped) bytes") { try ZipArchive(data: Data(cut)) }
        }
    }

    @Test func nonZipDataIsRejected() {
        #expect(throws: ZipError.notAZipFile) { try ZipArchive(data: Data()) }
        #expect(throws: ZipError.notAZipFile) { try ZipArchive(data: Data("hello, this is not a zip".utf8)) }
        #expect(throws: ZipError.notAZipFile) { try ZipArchive(data: Data(repeating: 0x41, count: 70_000)) }
    }

    /// Flips one byte in the middle of a deflated entry's compressed data. Whether that makes
    /// the stream undecodable or merely decode to different bytes, the entry must be refused.
    @Test func tamperedDeflatedByteIsRejected() throws {
        var bytes = try EPUBTestSupport.epubData("alice-epub3")
        let pristine = try ZipArchive(data: bytes)
        let entry = try #require(pristine.entry(at: "OEBPS/4040227324556390537_11-h-5.htm.xhtml"))
        #expect(entry.method == 8)

        bytes[dataStart(of: entry, in: bytes) + entry.compressedSize / 2] ^= 0xFF
        let tampered = try ZipArchive(data: bytes)   // the directory is intact
        let damaged = try #require(tampered.entry(at: entry.path))
        #expect(throws: ZipError.crcMismatch(path: entry.path)) { try tampered.data(for: damaged) }

        // Neighbouring entries are unaffected.
        #expect(try tampered.data(at: "OEBPS/content.opf") == pristine.data(at: "OEBPS/content.opf"))
    }

    @Test func tamperedStoredByteIsRejected() throws {
        var bytes = try EPUBTestSupport.epubData("alice-epub3")
        let entry = try #require(ZipArchive(data: bytes).entry(at: "OEBPS/7981341119032183217_cover.jpg"))
        #expect(entry.method == 0)

        bytes[dataStart(of: entry, in: bytes) + 1000] ^= 0x01
        let tampered = try ZipArchive(data: bytes)
        #expect(throws: ZipError.crcMismatch(path: entry.path)) { try tampered.data(at: entry.path) }
    }

    @Test func impossibleDeclaredSizeIsRejectedWithoutAllocating() throws {
        var zip = TestZipBuilder()
        zip.add("a.txt", String(repeating: "abc", count: 100), deflate: true)
        var bytes = zip.build()
        // Central header: uncompressed size lives 24 bytes in. Claim ~2 GB from a few dozen bytes.
        let header = try #require(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        bytes.replaceSubrange(header.lowerBound + 24 ..< header.lowerBound + 28, with: [0xFF, 0xFF, 0xFF, 0x7F])

        let archive = try ZipArchive(data: bytes)
        #expect(throws: ZipError.crcMismatch(path: "a.txt")) { try archive.data(at: "a.txt") }
    }

    // MARK: Format variants (synthetic archives)

    @Test func storedDeflatedEmptyAndDirectoryEntries() throws {
        let text = String(repeating: "hello zip ", count: 500)
        let binary = Data((0 ..< 256).map { UInt8($0) })

        var zip = TestZipBuilder()
        zip.add("dir/", Data())
        zip.add("dir/a.txt", text, deflate: true)
        zip.add("b.bin", binary)
        zip.add("empty.txt", Data(), deflate: true)
        let archive = try ZipArchive(data: zip.build())

        #expect(archive.entries.map(\.path) == ["dir/", "dir/a.txt", "b.bin", "empty.txt"])
        #expect(archive.entries.map(\.isDirectory) == [true, false, false, false])
        #expect(archive.entry(at: "dir/a.txt")?.method == 8)
        #expect((archive.entry(at: "dir/a.txt")?.compressedSize ?? .max) < text.utf8.count / 10)
        #expect(try archive.data(at: "dir/a.txt") == Data(text.utf8))
        #expect(try archive.data(at: "b.bin") == binary)
        #expect(try archive.data(at: "empty.txt").isEmpty)
        #expect(try archive.data(at: "dir/").isEmpty)
    }

    @Test func zip64SizesOffsetsAndEndRecord() throws {
        let text = String(repeating: "zip64 ", count: 300)
        var zip = TestZipBuilder()
        zip.zip64End = true
        zip.files.append(.init(name: "one.txt", data: Data(text.utf8), deflate: true, zip64: true))
        zip.files.append(.init(name: "two.bin", data: Data((0 ..< 200).map { UInt8($0) }), zip64: true))
        zip.files.append(.init(name: "three.txt", data: Data("plain".utf8)))   // mixed: no extra field
        let archive = try ZipArchive(data: zip.build())

        #expect(archive.entries.count == 3)
        #expect(try archive.data(at: "one.txt") == Data(text.utf8))
        #expect(try archive.data(at: "two.bin") == Data((0 ..< 200).map { UInt8($0) }))
        #expect(try archive.data(at: "three.txt") == Data("plain".utf8))
        #expect(archive.entry(at: "one.txt")?.uncompressedSize == text.utf8.count)
    }

    @Test func dataDescriptorAndDifferingLocalExtraField() throws {
        // Sizes come from the central directory, and the data start from the *local* header,
        // whose extra field is longer than the central one here.
        let text = String(repeating: "descriptor ", count: 100)
        var zip = TestZipBuilder()
        zip.files.append(.init(name: "d.txt", data: Data(text.utf8), deflate: true,
                               localExtra: Data(repeating: 0xAB, count: 13), dataDescriptor: true))
        zip.files.append(.init(name: "e.txt", data: Data("after".utf8), localExtra: Data([1, 2, 3])))
        let archive = try ZipArchive(data: zip.build())

        #expect(try archive.data(at: "d.txt") == Data(text.utf8))
        #expect(try archive.data(at: "e.txt") == Data("after".utf8))
    }

    @Test func encryptedAndUnsupportedEntriesThrowOnlyWhenRead() throws {
        var zip = TestZipBuilder()
        zip.files.append(.init(name: "secret.txt", data: Data("x".utf8), flags: 0x0001))
        zip.files.append(.init(name: "bzip.txt", data: Data("x".utf8), methodOverride: 12))
        zip.add("fine.txt", "ok")
        let archive = try ZipArchive(data: zip.build())

        #expect(archive.entries.count == 3)
        #expect(archive.entry(at: "secret.txt")?.isEncrypted == true)
        #expect(throws: ZipError.encrypted(path: "secret.txt")) { try archive.data(at: "secret.txt") }
        #expect(throws: ZipError.unsupportedCompressionMethod(12, path: "bzip.txt")) { try archive.data(at: "bzip.txt") }
        #expect(String(decoding: try archive.data(at: "fine.txt"), as: UTF8.self) == "ok")
    }

    @Test func namesDecodeAsUTF8WithLatin1Fallback() throws {
        var zip = TestZipBuilder()
        zip.files.append(.init(name: "ignored", data: Data("a".utf8), flags: 0x0800, rawName: Array("naïve/日本語.txt".utf8)))
        zip.files.append(.init(name: "ignored", data: Data("b".utf8), rawName: Array("utf8-without-flag-é.txt".utf8)))
        zip.files.append(.init(name: "ignored", data: Data("c".utf8), rawName: [0x63, 0x61, 0x66, 0xE9, 0x2E, 0x74, 0x78, 0x74]))
        let archive = try ZipArchive(data: zip.build())

        #expect(archive.entries.map(\.path) == ["naïve/日本語.txt", "utf8-without-flag-é.txt", "café.txt"])
        #expect(try archive.data(at: "café.txt") == Data("c".utf8))
    }

    @Test func endRecordIsFoundBeneathLongOrMisleadingComments() throws {
        var zip = TestZipBuilder()
        zip.add("a.txt", "alpha")

        // A comment that contains something that looks like an end-of-central-directory record.
        zip.comment = Data("note ".utf8) + Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0, count: 18) + Data("tail".utf8)
        #expect(try ZipArchive(data: zip.build()).entries.map(\.path) == ["a.txt"])

        // The longest comment the format allows.
        zip.comment = Data(repeating: 0x20, count: 65_535)
        let archive = try ZipArchive(data: zip.build())
        #expect(String(decoding: try archive.data(at: "a.txt"), as: UTF8.self) == "alpha")
    }

    @Test func dataSlicesAndFilesBothOpen() throws {
        var zip = TestZipBuilder()
        zip.add("a.txt", "alpha", deflate: true)
        let bytes = zip.build()

        // A slice's indices do not start at zero; offsets inside the archive must not care.
        let padded = Data([9, 9, 9]) + bytes
        let slice = padded.dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(String(decoding: try ZipArchive(data: slice).data(at: "a.txt"), as: UTF8.self) == "alpha")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zip-test-\(UUID().uuidString).zip")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(String(decoding: try ZipArchive(url: file).data(at: "a.txt"), as: UTF8.self) == "alpha")
    }

    @Test func errorsDescribeThemselves() {
        #expect(ZipError.entryNotFound("a/b.xhtml").description.contains("a/b.xhtml"))
        #expect(ZipError.crcMismatch(path: "x.css").description.contains("x.css"))
        #expect(ZipError.unsupportedCompressionMethod(12, path: "y").description.contains("12"))
        #expect(ZipError.encrypted(path: "z").description.contains("z"))
        #expect(!ZipError.truncated.description.isEmpty)
        #expect(!ZipError.notAZipFile.description.isEmpty)
        #expect(ZipError.truncated.localizedDescription == ZipError.truncated.description)
    }

    // MARK: Helpers

    /// Offset of an entry's compressed bytes, found the same way the reader does.
    private func dataStart(of entry: ZipEntry, in bytes: Data) -> Int {
        let header = entry.localHeaderOffset
        let nameLength = Int(bytes[header + 26]) | Int(bytes[header + 27]) << 8
        let extraLength = Int(bytes[header + 28]) | Int(bytes[header + 29]) << 8
        return header + 30 + nameLength + extraLength
    }
}
