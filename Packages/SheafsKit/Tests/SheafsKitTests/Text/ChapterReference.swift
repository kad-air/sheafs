import Foundation
import Testing

/// The decoded `chapter-reference.json`, produced by `scripts/gen_chapter_reference.py` with
/// Python's `html.parser`: an independent second source for the converter's element paths,
/// paragraph text, element ids and titles.
struct ChapterReference: Decodable, Sendable {
    struct Sample: Decodable, Sendable {
        var index: Int
        var path: String
        var text: String
    }

    struct Cell: Decodable, Sendable {
        var header: Bool
        var text: String
    }

    struct Row: Decodable, Sendable {
        var path: String
        var cells: [Cell]
    }

    struct Table: Decodable, Sendable {
        var path: String
        var caption: String?
        var rows: [Row]
    }

    struct Document: Decodable, Sendable {
        var path: String
        var spineIndex: Int
        var title: String?
        var paragraphCount: Int
        var nonEmptyParagraphCount: Int
        var ids: [String]
        var samples: [Sample]
        var tables: [Table]
    }

    struct EPUB: Decodable, Sendable {
        var documents: [Document]
    }

    var sampleStride: Int
    var epubs: [String: EPUB]
    /// Loose XHTML fixtures (`Fixtures/<name>`), keyed by file name.
    var xhtml: [String: Document]

    static func load() throws -> ChapterReference {
        guard let url = Bundle.module.url(
            forResource: "chapter-reference", withExtension: "json", subdirectory: "Fixtures"
        ) else {
            throw TextFixture.Failure(description: "chapter-reference.json is missing from the test bundle")
        }
        return try JSONDecoder().decode(ChapterReference.self, from: Data(contentsOf: url))
    }

    /// One parameterized test case: a spine document of a fixture EPUB.
    struct Case: Sendable, CustomTestStringConvertible {
        var epub: String
        var document: Document
        var testDescription: String { "\(epub) \(document.path)" }
    }

    /// Loaded once. An unreadable file yields no cases, which `ChapterReferenceTests` turns into
    /// a loud failure (it asserts the full set of spine documents is present).
    static let cases: [Case] = {
        guard let reference = try? load() else { return [] }
        return reference.epubs.keys.sorted().flatMap { epub in
            reference.epubs[epub]?.documents.map { Case(epub: epub, document: $0) } ?? []
        }
    }()
}
