import Testing
import Foundation
import SwiftUI
import UIKit
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// The reader's own invariants: the typeset string matches the chapter's offsets, pagination
/// covers every character exactly once, and pages land where the Duo's fold says they should.
struct ReaderEngineTests {
    static func alice() throws -> EPUBBook {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        return try EPUBBook(url: url)
    }

    static let style = TypesetStyle(font: .newYork, fontSize: 19, lineHeight: 1.4, justified: true, hyphenate: true,
                                    paragraphStyle: .indented, palette: .paper, language: "en")

    @Test func typesetStringMatchesChapterOffsets() throws {
        let epub = try Self.alice()
        let converter = XHTMLConverter()
        var checkedBlocks = 0
        for item in epub.spine {
            let chapter = converter.convert(try epub.data(for: item.item))
            let string = Typesetter.attributedString(for: chapter, style: Self.style, images: ChapterImages(),
                                                     pageSize: CGSize(width: 320, height: 500))
            #expect(string.length == chapter.textLength, "chapter \(item.item.path)")
            let ns = string.string as NSString
            for block in chapter.blocks {
                let range = NSRange(location: block.textOffset, length: block.textLength)
                #expect(NSMaxRange(range) <= ns.length)
                if NSMaxRange(range) <= ns.length {
                    #expect(ns.substring(with: range) == block.text, "block \(block.id) in \(item.item.path)")
                }
                checkedBlocks += 1
            }
        }
        #expect(checkedBlocks > 500)
    }

    @Test func paginationCoversEveryCharacterOnce() throws {
        let epub = try Self.alice()
        let converter = XHTMLConverter()
        // A chapter with real prose (the first Gutenberg chapter after the wrapper page).
        let item = epub.spine[2].item
        let chapter = converter.convert(try epub.data(for: item))
        let pageSize = CGSize(width: 300, height: 480)
        let string = Typesetter.attributedString(for: chapter, style: Self.style, images: ChapterImages(), pageSize: pageSize)
        let paginated = PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: pageSize)
        #expect(paginated.pageCount > 3)
        var cursor = 0
        for page in 0 ..< paginated.pageCount {
            let range = paginated.range(ofPage: page)
            #expect(range.location == cursor, "page \(page) starts at \(range.location), expected \(cursor)")
            #expect(range.length > 0)
            cursor = NSMaxRange(range)
            #expect(paginated.pageIndex(containing: range.location) == page)
            #expect(paginated.pageIndex(containing: NSMaxRange(range) - 1) == page)
        }
        #expect(cursor == string.length)
        // Bigger pages mean fewer pages.
        let bigger = PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: CGSize(width: 600, height: 900))
        #expect(bigger.pageCount < paginated.pageCount)
    }

    // Display sizes in points: cover 466×678, inner 951×669 (landscape) / 669×951 (portrait).

    @Test func coverDisplayIsOnePage() {
        let layout = PageLayout.compute(.init(size: CGSize(width: 466, height: 678),
                                              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: nil, divisionIsActive: false, occlusions: [],
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.pageFrames.count == 1)
        #expect(layout.pageFrames[0].maxX <= 466 - 84)
        #expect(layout.textSize.width < layout.pageFrames[0].width)
    }

    @Test func innerDisplayLandscapeIsASpreadAroundTheFold() {
        let fold = CGRect(x: 475.5, y: 0, width: 0, height: 669)
        let layout = PageLayout.compute(.init(size: CGSize(width: 951, height: 669),
                                              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: fold, divisionIsActive: false, occlusions: [],
                                              margin: 24, fontSize: 19, allowSpread: true, fullBleed: true))
        #expect(layout.isSpread)
        let left = layout.pageFrames[0], right = layout.pageFrames[1]
        #expect(left.width == right.width)
        #expect(left.maxX < fold.minX)
        #expect(right.minX > fold.maxX)
        // Full bleed: the pages use the whole width, bars overlay them.
        let fullWidth: CGFloat = 951
        #expect(right.maxX == fullWidth)
        #expect(left.minX == 0)
        #expect(left.minY == right.minY)
        #expect(left.height == right.height)
    }

    @Test func bookPoseKeepsTextOutOfTheActiveFold() {
        let fold = CGRect(x: 445, y: 0, width: 60, height: 669)
        let layout = PageLayout.compute(.init(size: CGSize(width: 951, height: 669),
                                              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: fold, divisionIsActive: true, occlusions: [],
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.isSpread)
        #expect(layout.pageFrames[0].maxX <= fold.minX)
        #expect(layout.pageFrames[1].minX >= fold.maxX)
        #expect(layout.deckFrame == nil)
    }

    @Test func tabletopPosePutsThePageAboveTheFoldAndControlsBelow() throws {
        let fold = CGRect(x: 0, y: 450, width: 669, height: 50)
        let layout = PageLayout.compute(.init(size: CGSize(width: 669, height: 951),
                                              safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                                              division: fold, divisionIsActive: true, occlusions: [],
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.pageFrames.count == 1)
        #expect(layout.pageFrames[0].maxY <= fold.minY)
        let deck = try #require(layout.deckFrame)
        #expect(deck.minY == fold.maxY)
        let bottomLimit: CGFloat = 951 - 34
        #expect(deck.maxY <= bottomLimit)
    }

    @Test func innerDisplayPortraitFlatIsOneTallPage() {
        let fold = CGRect(x: 0, y: 475.5, width: 669, height: 0)
        let layout = PageLayout.compute(.init(size: CGSize(width: 669, height: 951),
                                              safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                                              division: fold, divisionIsActive: false, occlusions: [],
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.pageFrames.count == 1)
        #expect(layout.deckFrame == nil)
        let expectedHeight: CGFloat = 951 - 59 - 34
        #expect(layout.pageFrames[0].height == expectedHeight)
    }

    @Test func activeCameraOcclusionPushesTheTopDown() {
        let layout = PageLayout.compute(.init(size: CGSize(width: 951, height: 669),
                                              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: nil, divisionIsActive: false,
                                              occlusions: [CGRect(x: 200, y: 0, width: 60, height: 40)],
                                              margin: 24, fontSize: 19, allowSpread: false))
        let expectedTop: CGFloat = 40
        #expect(layout.pageFrames[0].minY == expectedTop)
    }

    @Test func libraryColumnsAreEvenOverAFold() {
        #expect(LibraryView.columnCount(for: 466, evenRequired: false) == 3)
        #expect(LibraryView.columnCount(for: 466, evenRequired: true) == 4)
        #expect(LibraryView.columnCount(for: 951, evenRequired: true) == 6)
        #expect(LibraryView.columnCount(for: 200, evenRequired: false) == 2)
    }

    @Test func xpointerRoundTripsThroughAChapter() throws {
        let epub = try Self.alice()
        let chapter = XHTMLConverter().convert(try epub.data(for: epub.spine[2].item))
        let block = try #require(chapter.blocks.first { $0.textLength > 40 })
        let pointer = XPointer(spineIndex: 2, elementPath: block.elementPath, textNodeIndex: 1, characterOffset: 7)
        let parsed = try #require(XPointer(parsing: pointer.serialized))
        #expect(parsed == pointer)
        #expect(pointer.serialized.hasPrefix("/body/DocFragment[3]/body/"))
        let found = try #require(chapter.block(atElementPath: parsed.elementPath))
        #expect(found.id == block.id)
    }
}

struct AnchoredPaginationTests {
    @Test func anchorBecomesTheFirstCharacterOfItsPage() throws {
        let epub = try ReaderEngineTests.alice()
        let item = epub.spine[2].item
        let chapter = XHTMLConverter().convert(try epub.data(for: item))
        let pageSize = CGSize(width: 300, height: 480)
        let string = Typesetter.attributedString(for: chapter, style: ReaderEngineTests.style, images: ChapterImages(), pageSize: pageSize)
        // Somewhere in the middle of a paragraph, on a different size than the one that produced it.
        let plain = PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: CGSize(width: 340, height: 600))
        let anchor = plain.range(ofPage: 2).location + 37
        let anchored = PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: pageSize, anchor: anchor)
        let page = anchored.pageIndex(containing: anchor)
        #expect(anchored.range(ofPage: page).location == anchor)
        // Every character is still covered exactly once, in order.
        var cursor = 0
        for index in 0 ..< anchored.pageCount {
            let range = anchored.range(ofPage: index)
            #expect(range.location == cursor)
            #expect(range.length > 0)
            cursor = NSMaxRange(range)
        }
        #expect(cursor == string.length)
        // Page count stays within one of the plain layout at the same size.
        let same = PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: pageSize)
        #expect(abs(same.pageCount - anchored.pageCount) <= 1)
        // Character lookups map back to chapter coordinates on both sides of the break.
        let point = CGPoint(x: 10, y: 5)
        if let before = anchored.characterIndex(at: point, page: 0) { #expect(before < anchor) }
        if let after = anchored.characterIndex(at: point, page: page) { #expect(after >= anchor) }
        // An anchor at the start or the end is the plain layout.
        #expect(PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: pageSize, anchor: 0).anchor == nil)
        #expect(PaginatedChapter(spineIndex: 2, attributedString: string, pageSize: pageSize, anchor: string.length).anchor == nil)
    }
}
