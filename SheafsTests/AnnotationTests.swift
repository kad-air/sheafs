import Testing
import Foundation
import SwiftData
import UIKit
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// Highlights and notes: the selection snaps to words, highlight rects land on the right page and
/// map back to their characters, annotations persist in order and die with their book, and the
/// pointers stored for both ends resolve back to the same offsets.
struct AnnotationTests {
    @Test func longPressSnapsToWords() {
        let s = "Alice was beginning to get very tired.\nSecond paragraph, here." as NSString
        let was = s.range(of: "was")
        #expect(PaginatedChapter.wordRange(in: s, at: was.location + 1) == was)
        #expect(PaginatedChapter.wordRange(in: s, at: was.location) == was)
        // Pressing on the space after a word or on the period gets a neighbouring word, never a blank.
        let onSpace = PaginatedChapter.wordRange(in: s, at: NSMaxRange(was))
        #expect(onSpace == was || onSpace == s.range(of: "beginning"))
        let tired = s.range(of: "tired")
        #expect(PaginatedChapter.wordRange(in: s, at: NSMaxRange(tired)) == tired)
        // The newline belongs to the first paragraph; the word never crosses into the second.
        #expect(PaginatedChapter.wordRange(in: s, at: NSMaxRange(tired) + 1) == tired)
        #expect(PaginatedChapter.wordRange(in: s, at: s.range(of: "Second").location + 2) == s.range(of: "Second"))
        // Out-of-range indices clamp instead of crashing.
        let clamped = PaginatedChapter.wordRange(in: s, at: 10_000)
        #expect(NSMaxRange(clamped) <= s.length && clamped.length > 0)
        #expect(PaginatedChapter.wordRange(in: "" as NSString, at: 3) == NSRange(location: 0, length: 0))
    }

    @Test func highlightRectsStayOnTheirPageAndMapBack() throws {
        let epub = try ReaderEngineTests.alice()
        let chapter = XHTMLConverter().convert(try epub.data(for: epub.spine[2].item))
        let pageSize = CGSize(width: 300, height: 480)
        let string = Typesetter.attributedString(for: chapter, style: ReaderEngineTests.style, images: ChapterImages(), pageSize: pageSize)
        let paginated = PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: pageSize)
        let page1 = paginated.range(ofPage: 1), page2 = paginated.range(ofPage: 2)
        // A highlight straddling the page break: each page gets its own part, the others nothing.
        let span = NSRange(location: NSMaxRange(page1) - 40, length: 80)
        let on1 = paginated.rects(for: span, page: 1), on2 = paginated.rects(for: span, page: 2)
        #expect(!on1.isEmpty && !on2.isEmpty)
        #expect(paginated.rects(for: span, page: 0).isEmpty)
        #expect(paginated.rects(for: span, page: 3).isEmpty)
        for rect in on1 + on2 {
            #expect(rect.minX >= -1 && rect.maxX <= pageSize.width + 1, "\(rect)")
            #expect(rect.minY >= -1 && rect.maxY <= pageSize.height + 1, "\(rect)")
            #expect(rect.height > 10 && rect.width > 0)
        }
        // The last piece sits at the bottom of page 1, the first piece at the top of page 2.
        #expect(try #require(on1.last).maxY > pageSize.height - 60)
        #expect(try #require(on2.first).minY < 4)
        // The rect of one character maps back to that character, and points far outside clamp to
        // the page's own ends (how the handles behave when dragged off the text).
        let first = page2.location
        let rect = try #require(paginated.rects(for: NSRange(location: first, length: 1), page: 2).first)
        #expect(paginated.nearestCharacter(to: CGPoint(x: rect.midX, y: rect.midY), page: 2).index == first)
        #expect(paginated.nearestCharacter(to: CGPoint(x: -500, y: -500), page: 2).index == first)
        let far = paginated.nearestCharacter(to: CGPoint(x: 5000, y: 5000), page: 2).index
        #expect(far >= NSMaxRange(page2) - 2 && far < NSMaxRange(page2))
        // An empty or off-chapter range draws nothing.
        #expect(paginated.rects(for: NSRange(location: first, length: 0), page: 2).isEmpty)
        #expect(paginated.rects(for: NSRange(location: string.length + 10, length: 5), page: paginated.pageCount - 1).isEmpty)
    }

    @Test func annotationsPersistInOrderAndDieWithTheirBook() throws {
        let store = LibraryStore(inMemory: true)
        let book = Book(title: "One", author: nil, language: nil, fileSize: 1, partialMD5: "aaaa", hasCover: false)
        let other = Book(title: "Two", author: nil, language: nil, fileSize: 1, partialMD5: "bbbb", hasCover: false)
        store.context.insert(book)
        store.context.insert(other)
        store.add(Annotation(bookID: book.id, spineIndex: 3, startOffset: 10, endOffset: 20, text: "b", color: .green))
        store.add(Annotation(bookID: book.id, spineIndex: 1, startOffset: 50, endOffset: 60, text: "a", note: "why",
                             color: .yellow, isUnderline: true))
        store.add(Annotation(bookID: other.id, spineIndex: 0, startOffset: 0, endOffset: 4, text: "c", color: .pink))
        let list = store.annotations(for: book)
        #expect(list.map(\.text) == ["a", "b"])
        #expect(list[0].mark == HighlightMark(id: list[0].id, spineIndex: 1, range: NSRange(location: 50, length: 10),
                                              color: .yellow, isUnderline: true))
        #expect(list[0].hasNote && !list[1].hasNote)
        store.delete(list[1])
        #expect(store.annotations(for: book).count == 1)
        store.delete(book)
        #expect(store.annotations(for: book).isEmpty)
        #expect(store.annotations(for: other).map(\.text) == ["c"])
        #expect(try store.context.fetch(FetchDescriptor<Annotation>()).count == 1)
    }

    @Test func bothEndsOfAHighlightRoundTripThroughPointers() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        let chapter = session.chapters[2]
        let block = try #require(chapter.blocks.first { $0.textLength > 60 })
        let start = ReadingLocation(spineIndex: 2, textOffset: block.textOffset + 5)
        let end = ReadingLocation(spineIndex: 2, textOffset: block.textOffset + 41)
        let startPointer = try #require(session.xpointer(for: start)).serialized
        let endPointer = try #require(session.xpointer(for: end)).serialized
        #expect(startPointer != endPointer)
        #expect(startPointer.hasSuffix(".5") && endPointer.hasSuffix(".41"))
        #expect(session.location(for: try #require(XPointer(parsing: startPointer))) == start)
        #expect(session.location(for: try #require(XPointer(parsing: endPointer))) == end)
    }

    @Test func markdownExportIsStable() {
        let markdown = AnnotationExport.markdown(title: "Alice", author: "Lewis Carroll", annotations: [
            ("Down the Rabbit-Hole", "Alice was beginning\nto get very tired", "  so relatable  "),
            ("Down the Rabbit-Hole", "Curiouser and curiouser!", ""),
            (nil, "The End", "fin"),
        ])
        #expect(markdown == """
        # Alice
        *Lewis Carroll*

        ## Down the Rabbit-Hole

        > Alice was beginning
        > to get very tired

        so relatable

        > Curiouser and curiouser!

        > The End

        fin

        """)
    }
}
