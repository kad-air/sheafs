import Testing
import Foundation
import UIKit
import SwiftUI
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// The three margins (side, top and bottom, gutter) that replaced the one. The defaults and every
/// migrated setting must draw exactly what the one margin drew; each margin must move its own edges
/// and nothing else. The expected numbers are the OLD build's own `[layout]` lines on the Duo
/// simulator (Pride at 19 pt, default margin 24), not values worked out with the code under test:
///   inner, flat: pages (0, 0, 453, 663) and (498, 0, 453, 663), textInsets (36, 24, 30, 24)
///   cover:       page (0, 0, 466, 644), textInsets (68.33, 24, 30, 24)
@MainActor
struct MarginTests {
    static let inner = CGSize(width: 951, height: 669)
    static let hinge = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    static let cover = CGSize(width: 466, height: 678)

    static func spread(_ margins: PageMargins) -> PageLayout {
        PageLayout.compute(.init(size: inner, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
                                 division: hinge, divisionIsActive: false, camera: nil,
                                 margins: margins, fontSize: 19, allowSpread: true, fullBleed: true))
    }

    static func coverPage(_ margins: PageMargins) -> PageLayout {
        PageLayout.compute(.init(size: cover, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
                                 division: nil, divisionIsActive: false,
                                 camera: CoverCamera.hole(window: cover, hasFold: false, orientation: .portrait),
                                 margins: margins, fontSize: 19, allowSpread: true, fullBleed: true))
    }

    /// The text column of page `index` in window coordinates.
    static func column(_ layout: PageLayout, _ index: Int) -> CGRect {
        let page = layout.pageFrames[index]
        return page.inset(by: layout.textInsets(ofPage: index))
    }

    // MARK: Migration

    /// 🔴 Settings saved with the ONE margin carry over to the same page: it was the side margin and
    /// each page's half of the gutter, and the top and bottom were fixed.
    @Test func theOneMarginMigratesToTheSameLook() throws {
        let old = #"{"theme":"sepia","font":"georgia","fontSize":22,"lineHeight":1.5,"margin":30,"justified":true,"hyphenate":false,"paragraphStyle":"spaced","keepScreenAwake":false,"tapToTurn":true}"#
        let stored = try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(old.utf8))
        #expect(stored.sideMargin == nil && stored.gutter == nil && stored.verticalMargin == nil)
        #expect(ReaderSettings.margins(stored) == PageMargins(side: 30, gutter: 30, vertical: 36))
        let atDefault = old.replacingOccurrences(of: #""margin":30"#, with: #""margin":24"#)
        #expect(ReaderSettings.margins(try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(atDefault.utf8))) == .standard)
        // The fresh defaults are the old default's look.
        #expect(ReaderSettings.margins(ReaderSettings.Stored()) == .standard)
    }

    /// Once the three are saved the old key is ignored, and it is still written (as the side
    /// margin) so an OLDER build, whose `margin` is non-optional, decodes these settings instead of
    /// resetting every one of them.
    @Test func savedMarginsWinAndOlderBuildsStillDecode() throws {
        var stored = ReaderSettings.Stored()
        stored.margin = 40
        stored.sideMargin = 40
        stored.gutter = 12
        stored.verticalMargin = 48
        let data = try JSONEncoder().encode(stored)
        var decoded = try JSONDecoder().decode(ReaderSettings.Stored.self, from: data)
        decoded.margin = 20   // an older build changed the one margin since: ignored
        #expect(ReaderSettings.margins(decoded) == PageMargins(side: 40, gutter: 12, vertical: 48))

        /// What the last build with one margin decodes (its non-optional keys).
        struct OlderBuild: Decodable {
            var theme: ReaderTheme, font: ReaderFont, fontSize: Double, lineHeight: Double, margin: Double
            var justified: Bool, hyphenate: Bool, paragraphStyle: ParagraphStyleChoice
            var keepScreenAwake: Bool, tapToTurn: Bool
        }
        let older = try JSONDecoder().decode(OlderBuild.self, from: data)
        #expect(older.margin == 40)
    }

    /// The migration runs at load, ONCE: the three keys are saved straight away, so the next load
    /// reads them and no longer looks at the old one.
    @Test func theMigrationIsSavedAtLoad() throws {
        let key = "reader.settings.v1"
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let old = #"{"theme":"paper","font":"newYork","fontSize":19,"lineHeight":1.4,"margin":32,"justified":true,"hyphenate":true,"paragraphStyle":"indented","keepScreenAwake":true,"tapToTurn":true}"#
        UserDefaults.standard.set(Data(old.utf8), forKey: key)

        let settings = ReaderSettings()
        #expect(settings.margins == PageMargins(side: 32, gutter: 32, vertical: 36))
        let after = try JSONDecoder().decode(ReaderSettings.Stored.self, from: try #require(UserDefaults.standard.data(forKey: key)))
        #expect(after.sideMargin == 32 && after.gutter == 32 && after.verticalMargin == 36)
        #expect(after.margin == 32)
        #expect(after.fontSize == 19 && after.theme == .paper, "the migration kept the other settings")

        settings.gutter = 16
        let next = ReaderSettings()
        #expect(next.margins == PageMargins(side: 32, gutter: 16, vertical: 36))
    }

    // MARK: Layout

    /// The defaults draw what the one margin drew, to the point (the old build's `[layout]` lines).
    @Test func theDefaultsDrawWhatTheOneMarginDrew() {
        let spread = Self.spread(.standard)
        #expect(spread.pageFrames == [CGRect(x: 0, y: 0, width: 453, height: 663), CGRect(x: 498, y: 0, width: 453, height: 663)])
        let old = UIEdgeInsets(top: 36, left: 24, bottom: 30, right: 24)
        #expect(spread.textInsets(ofPage: 0) == old && spread.textInsets(ofPage: 1) == old)
        #expect(spread.textInsets == old, "the [layout] line the check scripts read")
        #expect(spread.bandGap == 0)
        #expect(spread.textSize == CGSize(width: 405, height: 597), "the old build's [folio] text=405x597")
        #expect(spread.foldGap == 45)

        let cover = Self.coverPage(.standard)
        #expect(cover.pageFrames == [CGRect(x: 0, y: 0, width: 466, height: 644)])
        #expect(abs(cover.textInsets.top - 68.33) < 0.01)
        #expect(cover.textInsets.left == 24 && cover.textInsets.right == 24 && cover.textInsets.bottom == 30)
        #expect(cover.textSize.width == 418, "the old build's [folio] text=418x545")
        #expect(cover.foldGap == nil)
    }

    /// 🔴 On a spread the side margin moves the two OUTER edges only: the space between the columns
    /// (the fold plus both gutters, 93 pt) stays. Both pages stay the same width (one pagination).
    @Test func aSideMarginChangeLeavesTheGutter() {
        let base = Self.spread(.standard)
        let wide = Self.spread(PageMargins(side: 40, gutter: 24, vertical: 36))
        #expect(Self.column(base, 1).minX - Self.column(base, 0).maxX == 93)
        #expect(Self.column(wide, 1).minX - Self.column(wide, 0).maxX == 93)
        #expect(Self.column(wide, 0).maxX == Self.column(base, 0).maxX)
        #expect(Self.column(wide, 1).minX == Self.column(base, 1).minX)
        #expect(Self.column(wide, 0).minX == 40)
        #expect(Self.column(wide, 1).maxX == Self.inner.width - 40)
        #expect(Self.column(wide, 0).width == Self.column(wide, 1).width)
        #expect(wide.pageFrames == base.pageFrames)
    }

    /// And the gutter moves the two INNER edges only: the outer ones stay at the side margin.
    @Test func aGutterChangeLeavesTheSideMargins() {
        let base = Self.spread(.standard)
        let narrow = Self.spread(PageMargins(side: 24, gutter: 12, vertical: 36))
        #expect(Self.column(narrow, 1).minX - Self.column(narrow, 0).maxX == CGFloat(45 + 2 * 12))
        #expect(Self.column(narrow, 0).minX == Self.column(base, 0).minX)
        #expect(Self.column(narrow, 1).maxX == Self.column(base, 1).maxX)
        #expect(Self.column(narrow, 0).width == Self.column(narrow, 1).width)
        #expect(narrow.textSize.width == base.textSize.width + 12)
        // Neither touches the top or bottom.
        #expect(Self.column(narrow, 0).minY == Self.column(base, 0).minY)
        #expect(Self.column(narrow, 0).maxY == Self.column(base, 0).maxY)
        // One page has no gutter: the setting changes nothing there.
        #expect(Self.coverPage(PageMargins(side: 24, gutter: 56, vertical: 36)) == Self.coverPage(.standard))
    }

    /// Top and bottom: the text moves in by the same amount at both ends; the running head and the
    /// folio stay where they were (a spread's folio stays at the foot of the page, PR 94). The cover
    /// camera's band gets the same addition, so every step shows.
    @Test func topAndBottomMoveTheTextNotTheHeadOrFolio() {
        let base = Self.spread(.standard)
        let tall = Self.spread(PageMargins(side: 24, gutter: 24, vertical: 48))
        #expect(tall.bandGap == 12)
        #expect(Self.column(tall, 1).minY == Self.column(base, 1).minY + 12)
        #expect(Self.column(tall, 1).maxY == Self.column(base, 1).maxY - 12)
        #expect(Self.column(tall, 0).minX == Self.column(base, 0).minX && Self.column(tall, 1).maxX == Self.column(base, 1).maxX)
        #expect(Self.column(tall, 1).minX - Self.column(tall, 0).maxX == 93)
        let lineHeight: CGFloat = 17.5
        for index in 0 ..< 2 {
            let bounds = CGRect(origin: .zero, size: base.pageFrames[index].size)
            #expect(PageView.headFrame(bounds: bounds, textInsets: tall.textInsets(ofPage: index), bandGap: tall.bandGap,
                                       lineHeight: lineHeight, camera: nil)
                    == PageView.headFrame(bounds: bounds, textInsets: base.textInsets(ofPage: index), lineHeight: lineHeight, camera: nil))
            #expect(PageView.folioFrame(bounds: bounds, textInsets: tall.textInsets(ofPage: index), bandGap: tall.bandGap,
                                        lineHeight: lineHeight)
                    == PageView.folioFrame(bounds: bounds, textInsets: base.textInsets(ofPage: index), lineHeight: lineHeight))
        }
        let cover = Self.coverPage(PageMargins(side: 24, gutter: 24, vertical: 48))
        #expect(abs(cover.textInsets.top - (68.33 + 12)) < 0.01)
        #expect(cover.textInsets.bottom == PageLayout.footerHeight + 12)
    }

    /// Ask beside the book keeps the spread's right page as it was, its gutter on its left.
    @Test func askBesideKeepsTheRightPagesMargins() {
        let spread = Self.spread(PageMargins(side: 40, gutter: 12, vertical: 36))
        let single = AskPresentation.choose(for: spread, division: Self.hinge, window: Self.inner).pages(spread)
        #expect(single.textInsets(ofPage: 0) == spread.textInsets(ofPage: 1))
        #expect(single.textInsets.left == 12 && single.textInsets.right == 40)
        #expect(single.textSize == spread.textSize)
    }

    /// Where the Gutter control shows: a spread on the Duo's inner display, flat or in book pose, and
    /// an iPad in landscape; never one page (cover display, inner portrait, tabletop, iPad portrait).
    @Test func theGutterIsOfferedOnlyOverASpread() {
        func gap(_ size: CGSize, fold: CGRect?, active: Bool = false) -> CGFloat? {
            PageLayout.compute(.init(size: size, safeArea: EdgeInsets(), division: fold, divisionIsActive: active,
                                     camera: nil, margins: .standard, fontSize: 19, allowSpread: true, fullBleed: true)).foldGap
        }
        #expect(gap(Self.inner, fold: Self.hinge) == 45)
        #expect(gap(Self.inner, fold: Self.hinge, active: true) == 45)
        #expect(gap(CGSize(width: 1210, height: 834), fold: nil) == 28)
        #expect(gap(Self.cover, fold: nil) == nil)
        #expect(gap(CGSize(width: 669, height: 951), fold: CGRect(x: 0, y: 455.5, width: 669, height: 40), active: true) == nil)
        #expect(gap(CGSize(width: 669, height: 951), fold: CGRect(x: 0, y: 455.5, width: 669, height: 40)) == nil)
        #expect(gap(CGSize(width: 834, height: 1210), fold: nil) == nil)
    }

    /// The defaults and both ends sit on the sliders' grid.
    @Test func theDefaultsSitOnTheGridsInsideTheRanges() {
        let standard = PageMargins.standard
        for (value, range) in [(Double(standard.side), ReaderSettings.marginRange),
                               (Double(standard.gutter), ReaderSettings.marginRange),
                               (Double(standard.vertical), ReaderSettings.verticalMarginRange)] {
            #expect(range.contains(value))
            #expect(ReaderSettings.step(value, by: 0, grid: ReaderSettings.marginGrid, in: range) == value)
            #expect(ReaderSettings.step(range.upperBound, by: 0, grid: ReaderSettings.marginGrid, in: range) == range.upperBound)
        }
        #expect(ReaderSettings.verticalMarginRange.lowerBound == Double(PageLayout.headerHeight), "below it the text runs into the running head")
    }

    /// A real pager on the inner display: the LEFT page's view gets the mirrored insets (side margin
    /// on its left, gutter at the fold), the right page's the layout's, and both the band gap.
    @Test func theLeftPageViewMirrorsTheRightOne() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        let layout = Self.spread(PageMargins(side: 40, gutter: 12, vertical: 44))
        session.configure(style: ReaderEngineTests.style, textSize: layout.textSize)
        let controller = PagerController(session: session)
        controller.pageTurn = .slide
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: Self.inner)
        controller.apply(layout: layout, palette: .paper, location: ReadingLocation(spineIndex: 2, textOffset: 0), animated: false)
        controller.currentSpread?.loadViewIfNeeded()
        let pages = try #require(controller.currentSpread?.pageViews)
        #expect(pages.count == 2)
        #expect(pages[0].textInsets == UIEdgeInsets(top: 44, left: 40, bottom: 38, right: 12))
        #expect(pages[1].textInsets == UIEdgeInsets(top: 44, left: 12, bottom: 38, right: 40))
        #expect(pages.allSatisfy { $0.bandGap == 8 })
    }
}
