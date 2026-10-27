import Testing
import Foundation
import SwiftData
import UIKit
import SwiftUI
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// Bookmarks: anchored by a chapter offset, never a page number, so a text-size change puts the
/// ribbon on whichever page now holds that character; they persist in reading order and die with
/// their book; the ribbon is really drawn and keeps clear of the camera hole and the running head;
/// the Markdown export lists them in their own section.
struct BookmarkTests {
    static let layout = PageLayout(pageFrames: [CGRect(x: 0, y: 0, width: 360, height: 600)],
                                   textInsets: UIEdgeInsets(top: PageLayout.headerHeight, left: 24,
                                                            bottom: PageLayout.footerHeight, right: 24),
                                   deckFrame: nil)

    /// Whether the page view of a one-page spread showing `page` of chapter `spine` draws a ribbon.
    static func ribbon(_ session: BookSession, spine: Int, page: Int) -> Bool {
        let spread = SpreadViewController(session: session, slots: [PageSlot(spineIndex: spine, page: page)],
                                          layout: layout, palette: .paper)
        spread.loadViewIfNeeded()
        return spread.pageViews.first?.isBookmarked ?? false
    }

    @Test func bookmarkStaysOnItsTextAcrossATextSizeChange() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)

        // Mark page 3 of chapter 2 at 19 pt, as the toolbar button does: its first character.
        let small = ReaderEngineTests.style
        session.configure(style: small, textSize: Self.layout.textSize)
        let before = try #require(session.paginatedChapter(2))
        #expect(before.pageCount > 6)
        let offset = before.range(ofPage: 3).location
        let text = before.textStorage.string as NSString
        let start = ReadingLocation(spineIndex: 2, textOffset: offset)
        let bookmark = Bookmark(bookID: book.id, spineIndex: 2, textOffset: offset,
                                xpointer: session.xpointer(for: start)?.serialized,
                                label: Bookmark.label(in: text, at: offset))
        #expect(bookmark.label.count > 10)
        session.bookmarks = [bookmark.mark]
        #expect(Self.ribbon(session, spine: 2, page: 3))
        #expect(!Self.ribbon(session, spine: 2, page: 2))
        #expect(!Self.ribbon(session, spine: 2, page: 4))
        #expect(!Self.ribbon(session, spine: 3, page: 3))

        // Larger text: the caches drop and the chapter is laid out again, anchored at the reading
        // position (elsewhere in the chapter), as the reader does after a size change.
        var large = small
        large.fontSize = 27
        session.configure(style: large, textSize: Self.layout.textSize)
        #expect(session.laidOutChapter(2) == nil)
        let readingAt = before.range(ofPage: 1).location + 25
        let after = try #require(session.paginatedChapter(2, anchor: readingAt))
        #expect(after.pageCount > before.pageCount)
        let page = after.pageIndex(containing: offset)
        let markedText = text.substring(with: NSRange(location: offset, length: 40))
        let enlarged = after.textStorage.string as NSString
        // The page number moved (page 3 now holds other text) …
        #expect(page != 3)
        #expect(!enlarged.substring(with: after.range(ofPage: 3)).contains(markedText))
        // … and the ribbon is on the page holding the bookmarked text, and on no other page.
        #expect(NSLocationInRange(offset, after.range(ofPage: page)))
        let marked = (0 ..< after.pageCount).filter { !after.bookmarks(session.bookmarks, onPage: $0).isEmpty }
        #expect(marked == [page])
        #expect(Self.ribbon(session, spine: 2, page: page))
        #expect(!Self.ribbon(session, spine: 2, page: page - 1))
        #expect(!Self.ribbon(session, spine: 2, page: page + 1))
        // The text there is the text that was marked (offsets are the same at any size).
        #expect(enlarged.substring(with: NSRange(location: offset, length: 40)) == markedText)
        // The CREngine pointer stored with it leads back to the same place.
        let serialized = try #require(bookmark.xpointer)
        let pointer = try #require(XPointer(parsing: serialized))
        #expect(session.location(for: pointer) == start)
    }

    @Test func bookmarksPersistInOrderAndDieWithTheirBook() throws {
        let store = LibraryStore(inMemory: true)
        let book = Book(title: "One", author: nil, language: nil, fileSize: 1, partialMD5: "aaaa", hasCover: false)
        let other = Book(title: "Two", author: nil, language: nil, fileSize: 1, partialMD5: "bbbb", hasCover: false)
        store.context.insert(book)
        store.context.insert(other)
        store.add(Bookmark(bookID: book.id, spineIndex: 4, textOffset: 10, label: "c"))
        store.add(Bookmark(bookID: book.id, spineIndex: 1, textOffset: 900, label: "b"))
        store.add(Bookmark(bookID: book.id, spineIndex: 1, textOffset: 20, xpointer: "/body/DocFragment[2]/body/p[1]/text()[1].20", label: "a"))
        store.add(Bookmark(bookID: other.id, spineIndex: 0, textOffset: 0, label: "z"))
        let list = store.bookmarks(for: book)
        #expect(list.map(\.label) == ["a", "b", "c"])
        #expect(list[0].location == ReadingLocation(spineIndex: 1, textOffset: 20))
        #expect(list[0].mark == BookmarkMark(id: list[0].id, spineIndex: 1, textOffset: 20))
        store.delete(list[1])
        #expect(store.bookmarks(for: book).map(\.label) == ["a", "c"])
        store.delete(book)
        #expect(store.bookmarks(for: book).isEmpty)
        #expect(store.bookmarks(for: other).map(\.label) == ["z"])
        #expect(try store.context.fetch(FetchDescriptor<Bookmark>()).count == 1)
    }

    @Test func labelIsThePagesFirstWords() {
        let text = "Alice was beginning to get very tired of sitting by her sister on the bank.\n\u{FFFC}\nNext" as NSString
        #expect(Bookmark.label(in: text, at: 0) == "Alice was beginning to get very tired of sitting by her…")
        #expect(Bookmark.label(in: text, at: 0, maxLength: 200) == "Alice was beginning to get very tired of sitting by her sister on the bank. Next")
        // A page that starts inside a hyphenated word labels from the word's start.
        #expect(Bookmark.label(in: text, at: text.range(of: "ginning").location, maxLength: 20) == "beginning to get…")
        // Images and line breaks are spaces; a word longer than the label is cut.
        #expect(Bookmark.label(in: text, at: text.range(of: "bank").location) == "bank. Next")
        #expect(Bookmark.label(in: "Supercalifragilistic" as NSString, at: 0, maxLength: 5) == "Super…")
        #expect(Bookmark.label(in: "" as NSString, at: 3) == "")
        #expect(Bookmark.label(in: text, at: 10_000) == "Next")
        // Text without word spaces (Japanese): the label starts exactly at the page, never walking
        // back into the previous page's characters.
        let japanese = "吾輩は猫である名前はまだ無いどこで生れたかとんと見当がつかぬ何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している" as NSString
        let pageStart = 40
        #expect(Bookmark.label(in: japanese, at: pageStart) == japanese.substring(from: pageStart))
        #expect(Bookmark.label(in: japanese, at: pageStart, maxLength: 10) == japanese.substring(with: NSRange(location: pageStart, length: 10)) + "…")
        // A run of letters longer than a word could be is not stepped back over either.
        let long = "a " + String(repeating: "x", count: 30) as NSString
        #expect(Bookmark.label(in: long, at: 22) == String(repeating: "x", count: 10))
    }

    /// On the cover display the ribbon would sit over the camera hole: it moves left of it. On a
    /// plain page it hangs over the text's right edge, inside the head band, and the running head
    /// narrows to keep clear of it.
    @Test func ribbonKeepsClearOfTheCameraAndTheHead() throws {
        let cover = CGSize(width: 466, height: 678)
        let hole = try #require(CoverCamera.hole(window: cover, hasFold: false, orientation: .portrait))
        let input = PageLayout.Input(size: cover, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
                                     division: nil, divisionIsActive: false, camera: hole,
                                     margin: 24, fontSize: 19, allowSpread: true, fullBleed: true)
        let layout = PageLayout.compute(input)
        let bounds = CGRect(origin: .zero, size: layout.pageFrames[0].size)
        let onCover = PageView.ribbonFrame(bounds: bounds, textInsets: layout.textInsets, camera: layout.camera)
        #expect(!onCover.insetBy(dx: -6, dy: -6).intersects(hole))
        #expect(onCover.maxX < hole.minX && onCover.minY == 0 && onCover.maxY <= layout.textInsets.top)

        let page = CGRect(x: 0, y: 0, width: 440, height: 640)
        let insets = UIEdgeInsets(top: PageLayout.headerHeight, left: 28, bottom: PageLayout.footerHeight, right: 28)
        let ribbon = PageView.ribbonFrame(bounds: page, textInsets: insets, camera: nil)
        #expect(ribbon.maxX == page.width - insets.right)
        #expect(ribbon.minY == 0 && ribbon.maxY < insets.top && ribbon.width > 8 && ribbon.height > 16)
        let head = PageView.headFrame(bounds: page, textInsets: insets, lineHeight: 20, camera: nil, ribbon: ribbon)
        #expect(!head.intersects(ribbon))
        #expect(abs(head.midX - (insets.left + page.width - insets.right) / 2) < 0.5)
        #expect(head.width > 250)
    }

    /// The ribbon is painted in the theme's accent where `ribbonFrame` says, and only on a
    /// bookmarked page.
    @Test func ribbonIsDrawnOnlyOnABookmarkedPage() throws {
        let size = LinkStyleTests.pageSize
        for palette in [ReaderPalette.paper, .night] {
            let view = PageView(frame: CGRect(origin: .zero, size: size))
            view.palette = palette
            view.textInsets = UIEdgeInsets(top: PageLayout.headerHeight, left: 24, bottom: PageLayout.footerHeight, right: 24)
            let frame = PageView.ribbonFrame(bounds: view.bounds, textInsets: view.textInsets, camera: nil)
            func colour(at point: CGPoint) -> (Int, Int, Int) {
                let pixels = LinkStyleTests.pixels(of: view)
                let width = Int(size.width) * 2
                let i = (Int(point.y * 2) * width + Int(point.x * 2)) * 4
                return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            }
            func near(_ c: (Int, Int, Int), _ ui: UIColor) -> Bool {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                return abs(c.0 - Int(r * 255)) <= 3 && abs(c.1 - Int(g * 255)) <= 3 && abs(c.2 - Int(b * 255)) <= 3
            }
            let inside = CGPoint(x: frame.midX, y: frame.midY)
            let notch = CGPoint(x: frame.midX, y: frame.maxY - 1)
            #expect(near(colour(at: inside), palette.background), "\(palette): a ribbon on an unmarked page")
            view.isBookmarked = true
            #expect(near(colour(at: inside), palette.link), "\(palette): no ribbon on a bookmarked page")
            // The notch is cut out of the ribbon's end.
            #expect(near(colour(at: notch), palette.background))
        }
    }

    @Test func markdownExportListsBookmarksInTheirOwnSection() {
        let markdown = AnnotationExport.markdown(title: "Alice", author: nil, annotations: [
            ("Down the Rabbit-Hole", "Curiouser and curiouser!", "")
        ], bookmarks: [
            ("Down the Rabbit-Hole", "Alice was beginning to get very tired…"),
            ("The Pool of Tears", "  "),
            (nil, "The End"),
        ])
        #expect(markdown == """
        # Alice

        ## Down the Rabbit-Hole

        > Curiouser and curiouser!

        ## Bookmarks

        - Down the Rabbit-Hole — Alice was beginning to get very tired…
        - The Pool of Tears
        - The End

        """)
        // Bookmarks alone still make a document.
        #expect(AnnotationExport.markdown(title: "Alice", author: nil, annotations: [], bookmarks: [(nil, "")])
            == "# Alice\n\n## Bookmarks\n\n- Bookmark\n")
    }
}
