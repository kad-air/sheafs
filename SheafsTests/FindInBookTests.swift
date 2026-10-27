import Testing
import Foundation
import UIKit
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// Find-in-book in the app: a hit's offsets index the TYPESET chapter (the offsets contract), a
/// jump lands on the page that shows the hit, and found hits paint without being tappable.
@MainActor
struct FindInBookTests {
    static func alice() async throws -> BookSession {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        return session
    }

    @Test func hitsIndexTheTypesetChapter() async throws {
        let session = try await Self.alice()
        let index = BookSearchIndex(chapters: session.chapters)
        let result = try #require(index.search("Rabbit"))
        #expect(result.totalCount == 54)
        for spine in Set(result.hits.map(\.spineIndex)) {
            let string = Typesetter.attributedString(for: session.chapters[spine], style: ReaderEngineTests.style,
                                                     images: ChapterImages(), pageSize: CGSize(width: 320, height: 500)).string as NSString
            for hit in result.hits where hit.spineIndex == spine {
                let word = string.substring(with: NSRange(location: hit.textOffset, length: hit.length))
                #expect(word.lowercased() == "rabbit", "spine \(spine) offset \(hit.textOffset): \(word)")
            }
        }
    }

    @Test func aJumpLandsOnThePageThatShowsTheHit() async throws {
        let session = try await Self.alice()
        session.configure(style: ReaderEngineTests.style, textSize: CGSize(width: 300, height: 480))
        let index = BookSearchIndex(chapters: session.chapters)
        let spine = 5 // Chapter IV, "The Rabbit Sends in a Little Bill": 16 hits
        let hits = index.hits(of: "rabbit", inSpine: spine)
        #expect(hits.count == 16)
        #expect(session.laidOutChapter(spine) == nil)

        let first = try #require(hits.first)
        _ = session.pageStart(showing: first.textOffset, inSpine: spine)
        let chapter = try #require(session.laidOutChapter(spine))
        // Laid out anchored at the hit's paragraph, so the pages break there and not mid-line.
        let paragraph = try #require(session.chapters[spine].block(containing: first.textOffset)).textOffset
        #expect(chapter.anchor == (paragraph > 0 ? paragraph : nil))
        #expect(chapter.pageCount > 5)

        for hit in hits {
            let target = session.pageStart(showing: hit.textOffset, inSpine: spine)
            #expect(target.spineIndex == spine)
            let page = chapter.pageIndex(containing: target.textOffset)
            let range = chapter.range(ofPage: page)
            #expect(range.location == target.textOffset, "a jump lands on a page start")
            #expect(NSLocationInRange(hit.textOffset, range) && NSMaxRange(range) >= hit.range.upperBound,
                    "hit \(hit.textOffset) is on page \(page) \(range)")
            #expect(!chapter.rects(for: NSRange(location: hit.textOffset, length: hit.length), page: page).isEmpty)
        }
        #expect(session.laidOutChapter(spine) === chapter, "later jumps reuse the layout")
    }

    @Test func foundHitsPaintButAreNotTappable() throws {
        let (view, chapter) = LinkStyleTests.page("<p>Plain words, then the found word, then more plain words to fill a line.</p>")
        let range = (chapter.textStorage.string as NSString).range(of: "found")
        let bare = LinkStyleTests.hues(LinkStyleTests.pixels(of: view)).warm
        view.marks = [HighlightMark(id: UUID(), spineIndex: 0, range: range, color: .yellow, isUnderline: false, isFound: true)]
        for palette in [ReaderPalette.paper, .night, .black] {
            view.palette = palette
            let painted = LinkStyleTests.hues(LinkStyleTests.pixels(of: view)).warm
            #expect(painted - bare > 200, "\(palette): the found band is missing (\(painted) vs \(bare) warm pixels)")
        }
        let rect = try #require(view.rects(for: range).first)
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        #expect(view.mark(at: middle) == nil, "a tap on a found hit is a plain tap")
        let highlight = HighlightMark(id: UUID(), spineIndex: 0, range: range, color: .green, isUnderline: false)
        view.marks.append(highlight)
        #expect(view.mark(at: middle) == highlight)
    }
}
