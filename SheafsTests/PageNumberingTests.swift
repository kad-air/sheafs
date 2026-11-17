import Testing
import Foundation
import UIKit
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// The folio and "N of M" are the BOOK's pages (`ReferencePages`), never a count of screen pages.
/// Screen pages are cut anew, anchored at the position, at every fold, rotation and font change,
/// and the numbers counted from them moved with them (and, estimated for chapters not laid out yet,
/// jumped under the reader: a forward turn from 531 landed on 518). Here a position read on the
/// cover display, a spread, the tabletop's half page, and at bigger and smaller type must show the
/// SAME folio, which for Pride is the print page Python finds it on.
@MainActor
struct PageNumberingTests {
    static func session(_ name: String) async throws -> BookSession {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: name, withExtension: "epub"))
        let book = Book(title: name, author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        return session
    }

    /// Pride's page list as scripts/gen_epub_reference.py reads it (Python's ElementTree, not ours).
    struct PythonPage: Decodable { let label: String; let path: String?; let fragment: String? }
    static func pythonPageList(_ fixture: String) throws -> [PythonPage] {
        struct Reference: Decodable { let pageList: [PythonPage] }
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "epub-reference", withExtension: "json"))
        let all = try JSONDecoder().decode([String: Reference].self, from: Data(contentsOf: url))
        return try #require(all[fixture]).pageList
    }

    /// The displays and type the reader meets (text area sizes): the cover display, a page of the
    /// inner display's spread, the tabletop's upper half, then bigger and smaller type.
    static let layouts: [(name: String, size: CGSize, fontSize: Double)] = [
        ("cover", CGSize(width: 410, height: 560), 19),
        ("spread page", CGSize(width: 400, height: 600), 19),
        ("tabletop", CGSize(width: 560, height: 330), 19),
        ("cover, bigger type", CGSize(width: 410, height: 560), 27),
        ("spread page, smaller type", CGSize(width: 400, height: 600), 14),
    ]

    static func style(_ size: Double) -> TypesetStyle {
        var style = ReaderEngineTests.style
        style.fontSize = size
        return style
    }

    /// For each position and each layout, lays the chapter out as the reader does after a fold or a
    /// font change (anchored at the position) and checks the page holding it: it starts there, its
    /// folio is `expected`, and the strip says "expected of M · K pages left" with K the screen
    /// pages after it in the chapter.
    static func expectSameFolio(_ session: BookSession, at positions: [(ReadingLocation, String)],
                                sourceLocation: SourceLocation = #_sourceLocation) throws {
        for (position, expected) in positions {
            for layout in layouts {
                session.configure(style: style(layout.fontSize), textSize: layout.size)
                let chapter = try #require(session.paginatedChapter(position.spineIndex, anchor: position.textOffset))
                let page = chapter.pageIndex(containing: position.textOffset)
                #expect(chapter.range(ofPage: page).location == position.textOffset, "not anchored", sourceLocation: sourceLocation)
                #expect(session.folio(of: chapter, page: page) == expected,
                        "\(layout.name): \(position.spineIndex):\(position.textOffset)", sourceLocation: sourceLocation)
                #expect(session.folio(showing: position) == expected, sourceLocation: sourceLocation)
                let left = chapter.pageCount - page - 1
                #expect(session.progressLabel(at: position)
                        == "\(expected) of \(session.pageTotal) · \(left == 1 ? "1 page" : "\(left) pages") left in chapter",
                        sourceLocation: sourceLocation)
            }
        }
    }

    /// Pride (Project Gutenberg) carries its print edition's page list: the folio is the print page,
    /// labelled as printed, and M the last printed page, at every display and type size.
    @Test func prideShowsThePrintPageEverywhere() async throws {
        let session = try await Self.session("pride-epub2")
        let python = try Self.pythonPageList("pride-epub2.epub")
        let pages = session.referencePages
        #expect(pages.source == .pageList)
        #expect(pages.pages.count == python.count)
        #expect(session.pageTotal == 476)
        // A paragraph that starts on each of a spread of print pages (where a reader's page begins).
        var positions: [(ReadingLocation, String)] = []
        for k in stride(from: 30, to: pages.pages.count - 1, by: 60) {
            let page = pages.pages[k], next = pages.pages[k + 1]
            guard let block = session.chapters[page.spineIndex].blocks.first(where: { $0.textOffset > page.offset && $0.textLength > 0 }),
                  next.spineIndex > page.spineIndex || block.textOffset < next.offset else { continue }
            #expect(session.epub?.spine[page.spineIndex].item.path == python[k].path)
            positions.append((ReadingLocation(spineIndex: page.spineIndex, textOffset: block.textOffset),
                              ReferencePages.cleanLabel(python[k].label)))
        }
        #expect(positions.count >= 6)
        try Self.expectSameFolio(session, at: positions)
    }

    /// No page list (Alice): a page per 1,024 characters of each chapter's text, each chapter a new
    /// page, numbered through the book, the same everywhere.
    @Test func aliceShowsTheSamePageEverywhere() async throws {
        let session = try await Self.session("alice-epub3")
        #expect(session.referencePages.source == .synthetic)
        let pagesBefore = session.chapters.map { max(1, Int((Double($0.textLength) / 1024).rounded(.up))) }
        #expect(session.pageTotal == pagesBefore.reduce(0, +))
        var positions: [(ReadingLocation, String)] = []
        for spine in [3, 6, 9] {
            let paragraphs = session.chapters[spine].blocks.filter { $0.textLength > 40 }
            for block in [5, 15, 25].filter({ $0 < paragraphs.count }).map({ paragraphs[$0] }) {
                let number = pagesBefore[..<spine].reduce(0, +) + block.textOffset / 1024 + 1
                positions.append((ReadingLocation(spineIndex: spine, textOffset: block.textOffset), "\(number)"))
            }
        }
        #expect(positions.count >= 6)
        try Self.expectSameFolio(session, at: positions)
    }

    /// Each page of a spread shows its own folio (its first character's page), the strip the right
    /// page's; turning on never counts back, and laying other chapters out moves no number (the
    /// estimate that once did is gone).
    @Test func pagesNumberByTheirFirstCharacterAndNeverMove() async throws {
        let session = try await Self.session("pride-epub2")
        session.configure(style: ReaderEngineTests.style, textSize: CGSize(width: 400, height: 600))
        let spine = 8
        let chapter = try #require(session.paginatedChapter(spine))
        #expect(chapter.pageCount > 20)
        var folios: [String] = []
        for page in 0 ..< chapter.pageCount {
            let first = chapter.range(ofPage: page).location
            let folio = try #require(session.folio(of: chapter, page: page))
            #expect(folio == session.referencePages.page(spineIndex: spine, offset: first)?.label)
            // The reading position is the right page's first character: the strip says the same.
            #expect(session.folio(showing: ReadingLocation(spineIndex: spine, textOffset: first)) == folio)
            folios.append(folio)
        }
        let numbers = folios.compactMap(Int.init)
        #expect(numbers.count == folios.count)
        #expect(numbers == numbers.sorted(), "a forward turn counted back: \(numbers)")
        #expect(Set(numbers).count > 1 && numbers.last! - numbers.first! < chapter.pageCount * 2)
        for index in [spine - 1, spine + 1, spine + 2, 1, 2] { _ = session.paginatedChapter(index) }
        #expect((0 ..< chapter.pageCount).map { session.folio(of: chapter, page: $0) } == folios)
        let next = try #require(session.paginatedChapter(spine + 1))
        #expect(Int(session.folio(of: next, page: 0) ?? "") ?? 0 >= numbers.last!)
    }

    /// Before Pride's first print-page marker (the cover, the title page) there is no folio; the
    /// strip falls back to the percentage, and the trail to plain "Back".
    @Test func noFolioBeforeTheFirstMarker() async throws {
        let session = try await Self.session("pride-epub2")
        session.configure(style: ReaderEngineTests.style, textSize: CGSize(width: 400, height: 600))
        let start = ReadingLocation(spineIndex: 0, textOffset: 0)
        #expect(session.folio(at: start) == nil)
        #expect(session.pageLabel(showing: start) == nil)
        let chapter = try #require(session.paginatedChapter(0))
        #expect(session.folio(of: chapter, page: 0) == nil)
        #expect(session.progressLabel(at: start).hasPrefix(0.0.formatted(.percent.precision(.fractionLength(0))) + " · "))
        let first = try #require(session.referencePages.pages.first)
        #expect(session.folio(at: ReadingLocation(spineIndex: first.spineIndex, textOffset: first.offset)) == "vii")
    }
}
