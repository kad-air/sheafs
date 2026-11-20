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
        // With the book's stylesheets, as `BookSession` converts.
        let stylesheets = StylesheetLibrary(book: epub)
        var checkedBlocks = 0
        for item in epub.spine {
            let chapter = converter.convert(try epub.data(for: item.item), documentPath: item.item.path,
                                            stylesheets: stylesheets)
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
                                              division: nil, divisionIsActive: false, camera: nil,
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.pageFrames.count == 1)
        #expect(layout.pageFrames[0].maxX <= 466 - 84)
        #expect(layout.textSize.width < layout.pageFrames[0].width)
    }

    @Test func innerDisplayLandscapeIsASpreadAroundTheFold() {
        let fold = CGRect(x: 475.5, y: 0, width: 0, height: 669)
        let layout = PageLayout.compute(.init(size: CGSize(width: 951, height: 669),
                                              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: fold, divisionIsActive: false, camera: nil,
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
                                              division: fold, divisionIsActive: true, camera: nil,
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.isSpread)
        #expect(layout.pageFrames[0].maxX <= fold.minX)
        #expect(layout.pageFrames[1].minX >= fold.maxX)
        #expect(layout.deckFrame == nil)
    }

    /// Unfolding from book pose to flat must not move a single line: the simulator reports the hinge
    /// as the same 40 pt region in both poses (455.5, 0, 40 × 669), only its `isActive` changes, and
    /// the pages used to be 453 pt wide folded but 441 pt flat (a 2 pt vs 14 pt pad), so every line
    /// broke differently. A zero-width inactive region (what the device may report flat) gets the
    /// same gutter too.
    @Test func bookPoseAndFlatLayTheSpreadOutIdentically() {
        func layout(_ fold: CGRect, active: Bool) -> PageLayout {
            PageLayout.compute(.init(size: CGSize(width: 951, height: 669),
                                     safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
                                     division: fold, divisionIsActive: active, camera: nil,
                                     margin: 24, fontSize: 19, allowSpread: true, fullBleed: true))
        }
        let hinge = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        let book = layout(hinge, active: true)
        #expect(book.isSpread)
        #expect(book.pageFrames[0].maxX <= hinge.minX)
        #expect(book.pageFrames[1].minX >= hinge.maxX)
        #expect(layout(hinge, active: false) == book)
        #expect(layout(CGRect(x: 475.5, y: 0, width: 0, height: 669), active: false) == book)
        #expect(book.pageFrames == [CGRect(x: 0, y: 0, width: 453, height: 663),
                                    CGRect(x: 498, y: 0, width: 453, height: 663)])
    }

    /// A spread's pages run down to `spreadFootInset` above the window's bottom edge, not to the
    /// bottom safe area: the home indicator is centred on the display, in the gutter, under neither
    /// folio. 🔴 On the Duo's inner display (34 pt safe area) they stopped at 635 pt with the 30 pt
    /// folio band on top: text 569 pt tall, the folio's ink 43 pt above the edge. A single page keeps
    /// to the safe area (the indicator is under its folio), and so does tabletop's deck.
    @Test func spreadPagesRunToTheFootSinglePagesKeepClearOfTheHomeIndicator() {
        func compute(_ size: CGSize, bottom: CGFloat, fold: CGRect?) -> PageLayout {
            PageLayout.compute(.init(size: size, safeArea: EdgeInsets(top: 0, leading: 0, bottom: bottom, trailing: 84),
                                     division: fold, divisionIsActive: fold != nil, camera: nil,
                                     margin: 24, fontSize: 19, allowSpread: true, fullBleed: true))
        }
        let window = CGSize(width: 951, height: 669)
        let duo = compute(window, bottom: 34, fold: CGRect(x: 455.5, y: 0, width: 40, height: 669))
        #expect(duo.isSpread)
        #expect(duo.pageFrames.map(\.maxY) == [663, 663])
        #expect(duo.textSize.height == 597, "the text was 569 pt tall when the pages stopped at the safe area")
        let lineHeight: CGFloat = 17.5   // the footnote font's line + 2, as `PageView` draws margins
        for page in duo.pageFrames {
            let folio = PageView.folioFrame(bounds: CGRect(origin: .zero, size: page.size),
                                            textInsets: duo.textInsets, lineHeight: lineHeight)
                .offsetBy(dx: page.minX, dy: page.minY)
            #expect(folio.maxY <= page.maxY)
            #expect(window.height - folio.maxY >= PageLayout.spreadFootInset + 4, "folio at the very edge: \(folio)")
            // The folio is centred on its page, far beside the indicator (134 pt wide, centred on the display).
            #expect(abs(folio.midX - window.width / 2) > 67 + 60, "folio near the home indicator: \(folio)")
        }
        // No indicator (no bottom inset): to the edge, as before. A spread without a fold (iPad
        // landscape, 20 pt safe area): the same foot.
        #expect(compute(window, bottom: 0, fold: CGRect(x: 455.5, y: 0, width: 40, height: 669)).pageFrames.map(\.maxY) == [669, 669])
        let pad = compute(CGSize(width: 1210, height: 834), bottom: 20, fold: nil)
        #expect(pad.isSpread)
        #expect(pad.pageFrames.map(\.maxY) == [828, 828])
        // A single page (cover display, iPhone, inner portrait): the folio stays above the safe area.
        let cover = compute(CGSize(width: 466, height: 678), bottom: 34, fold: nil)
        #expect(!cover.isSpread)
        let safeBottom: CGFloat = 678 - 34
        #expect(cover.pageFrames[0].maxY == safeBottom)
        let folio = PageView.folioFrame(bounds: CGRect(origin: .zero, size: cover.pageViewSize),
                                        textInsets: cover.textInsets, lineHeight: lineHeight)
        #expect(folio.maxY <= cover.pageFrames[0].height)
    }

    /// Tabletop / laptop: the page on the upper half runs down to the MIDDLE of the fold, so its
    /// bottom edge (the line under the folio) is on the crease's centreline, the folio just above
    /// it in the crease's upper half and the text 20 pt taller than when the page stopped at the
    /// fold's top; the block of pages still to read hangs below the centreline. The deck starts
    /// below the fold, where it always did.
    @Test func tabletopPosePutsThePageDownToTheFoldsMiddleAndControlsBelow() throws {
        let fold = CGRect(x: 0, y: 450, width: 669, height: 50)
        let layout = PageLayout.compute(.init(size: CGSize(width: 669, height: 951),
                                              safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                                              division: fold, divisionIsActive: true, camera: nil,
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.pageFrames.count == 1)
        #expect(layout.pageFrames[0].maxY == fold.midY)
        #expect(layout.pageFrames[0].minY == 59)
        let deck = try #require(layout.deckFrame)
        #expect(deck.minY == fold.maxY)
        let bottomLimit: CGFloat = 951 - 34
        #expect(deck.maxY <= bottomLimit)
    }

    /// The Duo simulator's tabletop as `[layout]` reports it (the 40 pt hinge at 455.5, full bleed,
    /// 34 pt home indicator): the page is 475.5 pt tall, its text 409.5 pt (389.5 when the page
    /// stopped at the fold's top, 455.5), the folio in the band just above the centreline and the
    /// surface's first row (the page's edge line) the pixel row the centreline runs through.
    /// Flat (an inactive fold) the same window is one tall page, as before.
    @Test func duoTabletopPageEndsOnTheCreaseCentreline() throws {
        let hinge = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let layout = PageLayout.compute(.init(size: CGSize(width: 669, height: 951),
                                              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0),
                                              division: hinge, divisionIsActive: true, camera: nil,
                                              margin: 24, fontSize: 19, allowSpread: true, fullBleed: true))
        #expect(layout.pageFrames == [CGRect(x: 0, y: 0, width: 669, height: 475.5)])
        #expect(Double(layout.pageFrames[0].maxY) == TabletopEdgeTests.pageBottom)
        #expect(layout.textSize.height == 475.5 - PageLayout.headerHeight - PageLayout.footerHeight)
        #expect(layout.deckFrame == CGRect(x: 0, y: 495.5, width: 669, height: 951 - 34 - 495.5))
        let folio = PageView.folioFrame(bounds: CGRect(origin: .zero, size: layout.pageViewSize),
                                        textInsets: layout.textInsets, lineHeight: 18)
        // The folio's line (453.5…471.5) is mostly in the crease's upper half, wholly above its middle.
        #expect(folio.midY > hinge.minY, "the folio is not down in the crease: \(folio)")
        #expect(folio.maxY <= hinge.midY, "the folio crosses the centreline: \(folio)")
        let surface = TabletopBaseView.top(pageBottom: layout.pageFrames[0].maxY, scale: 3)
        #expect(surface * 3 == (hinge.midY * 3).rounded(.down), "the page's edge is not on the centreline's pixel row")
        let flat = PageLayout.compute(.init(size: CGSize(width: 669, height: 951),
                                            safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0),
                                            division: hinge, divisionIsActive: false, camera: nil,
                                            margin: 24, fontSize: 19, allowSpread: true, fullBleed: true))
        #expect(flat.pageFrames == [CGRect(x: 0, y: 0, width: 669, height: 917)])
        #expect(flat.deckFrame == nil)
    }

    @Test func innerDisplayPortraitFlatIsOneTallPage() {
        let fold = CGRect(x: 0, y: 475.5, width: 669, height: 0)
        let layout = PageLayout.compute(.init(size: CGSize(width: 669, height: 951),
                                              safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                                              division: fold, divisionIsActive: false, camera: nil,
                                              margin: 24, fontSize: 19, allowSpread: true))
        #expect(layout.pageFrames.count == 1)
        #expect(layout.deckFrame == nil)
        let expectedHeight: CGFloat = 951 - 59 - 34
        #expect(layout.pageFrames[0].height == expectedHeight)
    }

    @Test func coverCameraHoleStartsTheTextBelowItAndMovesTheHead() {
        // The hole the Duo's cover display reports on the device, in window coordinates (portrait).
        let device = CGRect(x: 399.67, y: 29.33, width: 37, height: 37)
        let cover = CGSize(width: 466, height: 678)
        let hole = CoverCamera.hole(window: cover, hasFold: false, orientation: .portrait)
        #expect(hole.map { abs($0.minX - device.minX) < 1 && abs($0.minY - device.minY) < 1 && $0.size == device.size } == true)
        let input = PageLayout.Input(size: cover,
                                     safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
                                     division: nil, divisionIsActive: false, camera: hole,
                                     margin: 24, fontSize: 19, allowSpread: true, fullBleed: true)
        let layout = PageLayout.compute(input)
        let zero: CGFloat = 0
        #expect(layout.pageFrames[0].minY == zero)
        // The text starts 2 pt below the hole (Books runs up to the hole).
        #expect(abs(layout.textInsets.top - (device.maxY + 2)) < 1)
        #expect(layout.textInsets.bottom == PageLayout.footerHeight)
        #expect(layout.camera == hole)
        // The running head stays clear of the hole and above the text.
        let lineHeight: CGFloat = 20
        let head = PageView.headFrame(bounds: layout.pageFrames[0], textInsets: layout.textInsets,
                                      lineHeight: lineHeight, camera: layout.camera)
        #expect(!head.intersects(device))
        #expect(head.maxY <= layout.textInsets.top)
        #expect(head.width > 250)
        // The folio sits inside the page, above the home indicator's zone.
        let folio = PageView.folioFrame(bounds: layout.pageFrames[0], textInsets: layout.textInsets, lineHeight: lineHeight)
        #expect(folio.maxY <= layout.pageFrames[0].height)
        #expect(folio.minY >= layout.pageFrames[0].height - layout.textInsets.bottom)
    }

    @Test func coverCameraTurnsWithTheInterfaceAndExistsNowhereElse() {
        let cover = CGSize(width: 466, height: 678), wide = CGSize(width: 678, height: 466)
        func near(_ a: CGRect?, _ b: CGRect) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && a.size == b.size
        }
        // Hinge down (phone top on the left, interface landscape-right): the hole is at the top left,
        // as seen on the phone and as the device reported it, (29, 29, 37 × 37). Hinge up: bottom right.
        #expect(near(CoverCamera.hole(window: wide, hasFold: false, orientation: .landscapeRight),
                     CGRect(x: 29, y: 29, width: 37, height: 37)))
        #expect(near(CoverCamera.hole(window: wide, hasFold: false, orientation: .landscapeLeft),
                     CGRect(x: 612, y: 400, width: 37, height: 37)))
        // Mid-rotation, the size decides.
        #expect(CoverCamera.hole(window: cover, hasFold: false, orientation: .landscapeLeft).map { abs($0.minY - 29.33) < 0.01 } == true)
        // The inner display (it has a fold, flat or not), other sizes: no camera at all, whatever
        // the system reports as occlusions there (status cluster, Live Activities).
        #expect(CoverCamera.hole(window: CGSize(width: 951, height: 669), hasFold: true, orientation: .landscapeRight) == nil)
        #expect(CoverCamera.hole(window: CGSize(width: 669, height: 951), hasFold: true, orientation: .portrait) == nil)
        #expect(CoverCamera.hole(window: cover, hasFold: true, orientation: .portrait) == nil)
        #expect(CoverCamera.hole(window: CGSize(width: 402, height: 874), hasFold: false, orientation: .portrait) == nil)
        // A hole at the bottom (phone top on the right) widens the folio band, not the head band.
        let input = PageLayout.Input(size: wide, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 21, trailing: 0),
                                     division: nil, divisionIsActive: false,
                                     camera: CoverCamera.hole(window: wide, hasFold: false, orientation: .landscapeLeft),
                                     margin: 24, fontSize: 19, allowSpread: true, fullBleed: true)
        let layout = PageLayout.compute(input)
        #expect(layout.textInsets.top == PageLayout.headerHeight)
        #expect(layout.pageFrames[0].maxY - layout.textInsets.bottom <= 399.67 - 2 + 0.01)
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
