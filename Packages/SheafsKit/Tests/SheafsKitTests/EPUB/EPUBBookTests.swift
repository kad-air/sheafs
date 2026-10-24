import Foundation
import Testing
@testable import SheafsKit

/// The three real/synthetic EPUB fixtures against epub-reference.json, which
/// scripts/gen_epub_reference.py computes with Python's zipfile, ElementTree and html.parser.
@Suite("EPUBBook against the Python reference")
struct EPUBBookTests {
    private func open(_ name: String) throws -> (book: EPUBBook, reference: EPUBReference) {
        (try EPUBBook(url: EPUBTestSupport.epubURL(name)), try EPUBTestSupport.reference(name))
    }

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func packageFieldsMatchTheReference(name: String) throws {
        let (book, reference) = try open(name)
        #expect(book.opfPath == reference.opfPath)
        #expect(book.version == reference.version)
        #expect(book.metadata.title == reference.title)
        #expect(book.metadata.authors == reference.authors)
        #expect(book.metadata.language == reference.language)
        #expect(book.metadata.identifier == reference.identifier)
        #expect(book.metadata.publisher == reference.publisher)
        #expect(book.metadata.published == reference.published)
        #expect(book.metadata.modified == reference.modified)
        #expect(book.metadata.series == reference.series)
        #expect(book.metadata.seriesIndex == reference.seriesIndex)
        #expect(book.manifest.count == reference.manifestCount)
        #expect(book.coverItem?.path == reference.coverPath)
    }

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func spineMatchesTheReference(name: String) throws {
        let (book, reference) = try open(name)
        #expect(book.spine.count == reference.spine.count)
        #expect(book.spine.map(\.item.path) == reference.spine.map(\.path))
        #expect(book.spine.map(\.linear) == reference.spine.map(\.linear))
    }

    /// Every spine document read through the EPUB layer has the size and CRC-32 Python's
    /// zipfile reports, and the same first 4096 bytes as zlib inflated.
    @Test(arguments: EPUBTestSupport.fixtureNames)
    func spineDocumentsHaveTheReferenceBytes(name: String) throws {
        let (book, reference) = try open(name)
        for (item, expected) in zip(book.spine, reference.spine) {
            let data = try book.data(for: item.item)
            #expect(data.count == expected.size, "size of \(expected.path)")
            #expect(CRC32.checksum(data) == expected.crc32, "crc32 of \(expected.path)")
            #expect(CRC32.checksum(data.prefix(4096)) == expected.head4096Crc32, "head of \(expected.path)")

            let entry = try #require(book.archive.entry(at: expected.path))
            #expect(entry.uncompressedSize == expected.size)
            #expect(entry.crc32 == expected.crc32)
        }
    }

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func tableOfContentsMatchesTheReference(name: String) throws {
        let (book, reference) = try open(name)
        let flat = book.flattenedTOC
        #expect(flat.count == reference.toc.count)
        #expect(flat.map(\.depth) == reference.toc.map(\.depth))
        #expect(flat.map(\.title) == reference.toc.map(\.title))
        #expect(flat.map(\.path) == reference.toc.map(\.path))
        #expect(flat.map(\.fragment) == reference.toc.map(\.fragment))
        // Ids are preorder indices, so they are simply 0, 1, 2...
        #expect(flat.map(\.id) == Array(0 ..< flat.count))
    }

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func spineIndexRoundTripsForEveryItem(name: String) throws {
        let (book, _) = try open(name)
        for (index, item) in book.spine.enumerated() {
            #expect(book.spineIndex(forPath: item.item.path) == index)
            #expect(book.manifestItem(atPath: item.item.path) == item.item)
            #expect(book.manifest[item.idref] == item.item)
        }
        #expect(book.spineIndex(forPath: "OEBPS/not-in-the-spine.xhtml") == nil)
        #expect(book.spineIndex(forPath: book.coverItem?.path ?? "") == nil)
    }

    @Test(arguments: EPUBTestSupport.fixtureNames)
    func coverImageIsAnImageFile(name: String) throws {
        let (book, _) = try open(name)
        let item = try #require(book.coverItem)
        #expect(item.mediaType.hasPrefix("image/"))
        let data = try #require(try book.coverImageData())
        #expect(data.count == (book.archive.entry(at: item.path)?.uncompressedSize ?? -1))
        let jpeg = data.starts(with: [0xFF, 0xD8, 0xFF])
        let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        #expect(jpeg || png)
    }

    @Test func openingFromDataGivesTheSameBook() throws {
        let url = try EPUBTestSupport.epubURL("alice-epub3")
        let fromURL = try EPUBBook(url: url)
        let fromData = try EPUBBook(data: Data(contentsOf: url))
        #expect(fromURL.url == url)
        #expect(fromData.url == nil)
        #expect(fromURL.metadata == fromData.metadata)
        #expect(fromURL.manifest == fromData.manifest)
        #expect(fromURL.spine == fromData.spine)
        #expect(fromURL.toc == fromData.toc)
        #expect(fromURL.coverItem == fromData.coverItem)
    }

    // MARK: Fixture-specific facts

    @Test func aliceNavigationDocumentAndNCXAgree() throws {
        // Alice ships both a nav document and an NCX; they are separate files describing the
        // same contents, so two different parsers must produce the same entries.
        let book = try EPUBBook(url: EPUBTestSupport.epubURL("alice-epub3"))
        #expect(book.metadata.title == "Alice's Adventures in Wonderland")
        #expect(book.version == "3.0")
        #expect(book.manifest["ncx"]?.properties.contains("nav") == true)   // the id "ncx" is the nav doc
        #expect(book.spine.count == 15)

        let nav = try TOCParser.parseNavDocument(book.data(at: "OEBPS/toc.xhtml"), path: "OEBPS/toc.xhtml")
        let ncx = try TOCParser.parseNCX(book.data(at: "OEBPS/toc.ncx"), path: "OEBPS/toc.ncx")
        #expect(nav?.count == 16)
        #expect(nav == ncx)
        #expect(book.toc == nav)
    }

    @Test func prideComesFromTheNCXOnly() throws {
        let book = try EPUBBook(url: EPUBTestSupport.epubURL("pride-epub2"))
        #expect(book.version == "2.0")
        #expect(book.manifest.values.allSatisfy { !$0.properties.contains("nav") })
        #expect(book.spine.count == 17)
        #expect(book.toc.count == 63)
        #expect(book.toc.allSatisfy { $0.children.isEmpty && $0.depth == 0 })
        // The cover is named by <meta name="cover">, not by an EPUB 3 property.
        #expect(book.coverItem?.id == "id-3191094967586741918")
        // Two dc:date elements; the publication one wins.
        #expect(book.metadata.published == "1998-06-01")
    }

    @Test func hubFixtureHasSeriesMetadataAndNoUsableTOC() throws {
        let book = try EPUBBook(url: EPUBTestSupport.epubURL("hub-fixture"))
        #expect(book.metadata.series == "Fixtures")
        #expect(book.metadata.seriesIndex == 3)
        #expect(book.metadata.description?.hasPrefix("A synthetic epub") == true)
        // The manifest lists toc.ncx but the archive does not contain it: no TOC, and no error.
        #expect(book.manifest["ncx"] != nil)
        #expect(book.archive.entry(at: "OEBPS/toc.ncx") == nil)
        #expect(book.toc.isEmpty)
        #expect(book.flattenedTOC.isEmpty)
        #expect(book.spine.count == 1)
    }

    @Test func epubBookIsSafeToReadFromManyThreads() async throws {
        let book = try EPUBBook(url: EPUBTestSupport.epubURL("pride-epub2"))
        let expected = book.spine.map { $0.item.path }
        let seen = try await withThrowingTaskGroup(of: [Int].self) { group in
            for _ in 0 ..< 6 {
                group.addTask {
                    try book.spine.map { try book.data(for: $0.item).count } + [book.flattenedTOC.count]
                }
            }
            return try await group.reduce(into: [[Int]]()) { $0.append($1) }
        }
        let sizes = try expected.map { try book.data(at: $0).count } + [book.flattenedTOC.count]
        #expect(seen == Array(repeating: sizes, count: 6))
    }
}
