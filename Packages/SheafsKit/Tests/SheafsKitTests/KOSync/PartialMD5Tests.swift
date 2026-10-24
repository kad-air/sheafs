import Foundation
import Testing

import SheafsKit

@Suite("PartialMD5")
struct PartialMD5Tests {
    static let epubFixtures = ["alice-epub3.epub", "hub-fixture.epub", "pride-epub2.epub"]
    static let syntheticSizes = [0, 1, 1023, 1024, 1025, 2047, 4096, 5000, 70000, 1_100_000]

    @Test("the hub fixture hashes to the known-good key")
    func hubFixtureLiteral() throws {
        let expected = "2d54ce2c70a99dc5b63e58ebfe69bf51"
        let url = try SyncFixture.url("hub-fixture.epub")
        #expect(try PartialMD5.digest(fileAt: url) == expected)
        #expect(PartialMD5.digest(data: try Data(contentsOf: url)) == expected)
    }

    @Test("an empty file is the MD5 of nothing")
    func emptyInput() throws {
        let md5OfNothing = "d41d8cd98f00b204e9800998ecf8427e"
        #expect(PartialMD5.digest(data: Data()) == md5OfNothing)
        try withTemporaryFile(Data()) { url in
            let digest = try PartialMD5.digest(fileAt: url)
            #expect(digest == md5OfNothing)
        }
    }

    @Test("every EPUB fixture matches the reference, from data and from a file", arguments: epubFixtures)
    func fixtureMatchesReference(name: String) throws {
        let reference = try SyncReference.load()
        let expected = try #require(reference.partialMd5.fixtures[name])
        #expect(try PartialMD5.digest(fileAt: SyncFixture.url(name)) == expected)
        #expect(PartialMD5.digest(data: try SyncFixture.data(name)) == expected)
    }

    @Test("synthetic inputs match the reference, from data and from a file", arguments: syntheticSizes)
    func syntheticMatchesReference(size: Int) throws {
        let reference = try SyncReference.load()
        let expected = try #require(reference.partialMd5.synthetic[String(size)])
        let bytes = SyncFixture.syntheticBytes(count: size)
        #expect(PartialMD5.digest(data: bytes) == expected)
        try withTemporaryFile(bytes) { url in
            let digest = try PartialMD5.digest(fileAt: url)
            #expect(digest == expected)
        }
    }

    @Test("the reference covers exactly the sizes tested here")
    func referenceCoversTestedSizes() throws {
        let reference = try SyncReference.load()
        #expect(Set(reference.partialMd5.synthetic.keys) == Set(Self.syntheticSizes.map(String.init)))
        #expect(Set(reference.partialMd5.fixtures.keys) == Set(Self.epubFixtures))
    }

    @Test("only the sampled windows matter")
    func unsampledBytesAreIgnored() throws {
        // Offsets read: 0, 1024, 4096, 16384. Bytes 2048..<4096 and 5120..<16384 are never read.
        var bytes = SyncFixture.syntheticBytes(count: 20000)
        let before = PartialMD5.digest(data: bytes)
        for index in [2048, 3000, 4095, 5120, 9999, 16383] { bytes[index] ^= 0xFF }
        #expect(PartialMD5.digest(data: bytes) == before)
        bytes[0] ^= 0xFF
        #expect(PartialMD5.digest(data: bytes) != before)
        bytes[0] ^= 0xFF
        bytes[16384 + 1023] ^= 0xFF  // last byte of the window at 16 KiB
        #expect(PartialMD5.digest(data: bytes) != before)
    }

    @Test("a slice with a non-zero start index hashes like a copy")
    func dataSlice() {
        let bytes = SyncFixture.syntheticBytes(count: 9000)
        let padded = Data(repeating: 0xAB, count: 100) + bytes
        #expect(PartialMD5.digest(data: padded[100...]) == PartialMD5.digest(data: bytes))
    }

    @Test("a missing file throws")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try PartialMD5.digest(fileAt: url) }
    }

    private func withTemporaryFile(_ bytes: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partialmd5-\(UUID().uuidString)")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
