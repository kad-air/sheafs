import Testing
import Foundation
import UIKit
import SheafsKit
@testable import Sheafs

/// Book-wide page numbers must count on by one as you turn, though the estimate for chapters not
/// laid out yet moves under them. The landmine (an iPhone Duo recording, The Lord of the Rings,
/// tabletop): turning forward from page 531 landed on page 518, because every number was summed
/// afresh from estimates that had shifted when the neighbouring chapters were laid out.
@MainActor
struct PageNumberingTests {
    /// The numbering before the fix: every chapter before this one, exact or estimated, summed anew.
    static func legacyStart(of index: Int, exact: (Int) -> Int?, estimate: (Int) -> Int) -> Int {
        (0 ..< index).reduce(0) { $0 + (exact($1) ?? estimate($1)) }
    }

    /// A long book read from the middle, as the reader does it: chapter 20 laid out and numbered,
    /// then its neighbours laid out in the background, each changing the estimate for all the
    /// chapters before (their exact counts differ from what was estimated), then turned through
    /// page by page across three chapter boundaries.
    @Test func turnsCountOnByOneWhileTheEstimateMoves() {
        let lengths = (0 ..< 40).map { 9000 + ($0 * 7919) % 21000 }
        var laidOut: [Int: Int] = [:]
        var perPage = 1500.0
        func exact(_ index: Int) -> Int? { laidOut[index] }
        func estimate(_ index: Int) -> Int { max(1, Int((Double(lengths[index]) / perPage).rounded(.up))) }
        /// Lays a chapter out at 1200 characters a page, and the estimate follows the laid-out ones.
        func layOut(_ index: Int) {
            laidOut[index] = Int((Double(lengths[index]) / 1200).rounded(.up))
            let chars = laidOut.keys.reduce(0) { $0 + lengths[$1] }, pages = laidOut.values.reduce(0, +)
            perPage = Double(chars) / Double(pages)
        }

        var numbering = PageNumbering()
        var previous: Int?
        var legacyWentBack = false, legacyPrevious: Int?
        layOut(20)
        for chapter in 20 ... 23 {
            for page in 0 ..< laidOut[chapter]! {
                let number = numbering.start(of: chapter, exact: exact, estimate: estimate) + page + 1
                let legacy = Self.legacyStart(of: chapter, exact: exact, estimate: estimate) + page + 1
                if let previous { #expect(number == previous + 1, "chapter \(chapter) page \(page): \(previous) → \(number)") }
                if let legacyPrevious, legacy != legacyPrevious + 1 { legacyWentBack = true }
                previous = number
                legacyPrevious = legacy
                // The prefetch: after the first page shown, the chapters either side get laid out.
                if page == 0 {
                    if laidOut[chapter + 1] == nil { layOut(chapter + 1) }
                    if laidOut[chapter - 1] == nil { layOut(chapter - 1) }
                }
            }
        }
        // The replay is the landmine: summed afresh, the same turns jumped.
        #expect(legacyWentBack, "the replay no longer reproduces the jump; it proves nothing")
    }

    /// Paging back into a chapter laid out on the way counts back by one.
    @Test func turningBackCountsBackByOne() {
        var numbering = PageNumbering()
        let estimates = [10, 10, 10, 10, 10]
        var laidOut = [3: 12]
        let first = numbering.start(of: 3, exact: { laidOut[$0] }, estimate: { estimates[$0] })
        #expect(first == 30)
        laidOut[2] = 14 // more pages than estimated: the numbers behind shift, not the ones shown
        let before = numbering.start(of: 2, exact: { laidOut[$0] }, estimate: { estimates[$0] })
        #expect(before + 14 == first, "the last page of chapter 2 is not the one before chapter 3's first")
    }

    /// A chapter reached by a jump starts from the estimate, and keeps that number until reset.
    @Test func aJumpKeepsItsNumberUntilTheLayoutChanges() {
        var numbering = PageNumbering()
        var estimate = 10
        let start = numbering.start(of: 30, exact: { _ in nil }, estimate: { _ in estimate })
        #expect(start == 300)
        estimate = 9
        #expect(numbering.start(of: 30, exact: { _ in nil }, estimate: { _ in estimate }) == 300)
        numbering.reset()
        #expect(numbering.start(of: 30, exact: { _ in nil }, estimate: { _ in estimate }) == 270)
    }

    /// The same in the app's session, with a real book: page 1 of a chapter is numbered, other
    /// chapters are laid out (which moves the estimate), and the next pages and the next chapter
    /// still count on by one; the numbering before the fix would have moved.
    @Test func sessionNumbersHoldWhileNeighboursAreLaidOut() async throws {
        let session = try await FindInBookTests.alice()
        session.configure(style: ReaderEngineTests.style, textSize: CGSize(width: 300, height: 480))
        let spine = 6
        let chapter = try #require(session.paginatedChapter(spine))
        #expect(chapter.pageCount >= 2)
        func legacy(_ index: Int, page: Int) -> Int {
            var chars = 0, pages = 0
            for i in session.chapters.indices { if let c = session.laidOutChapter(i) { chars += session.chapters[i].textLength; pages += c.pageCount } }
            let perPage = pages > 0 ? max(200, Double(chars) / Double(pages)) : 1500
            return Self.legacyStart(of: index, exact: { session.laidOutChapter($0)?.pageCount },
                                    estimate: { max(1, Int((Double(session.chapters[$0].textLength) / perPage).rounded(.up))) }) + page + 1
        }
        let first = session.bookPages(spineIndex: spine, page: 0).page
        let legacyFirst = legacy(spine, page: 0)
        #expect(first == legacyFirst, "a cold chapter starts from the same estimate as before")
        // The neighbours and a few more get laid out, as the prefetch and the reader's turns would.
        for index in [spine + 1, spine - 1, spine - 2, spine + 2, 1, 2] { _ = session.paginatedChapter(index) }
        #expect(session.bookPages(spineIndex: spine, page: 1).page == first + 1)
        let lastPage = chapter.pageCount - 1
        #expect(session.bookPages(spineIndex: spine, page: lastPage).page == first + lastPage)
        #expect(session.bookPages(spineIndex: spine + 1, page: 0).page == first + chapter.pageCount,
                "the next chapter's first page does not follow this one's last")
        #expect(legacy(spine, page: 1) != first + 1, "Alice no longer moves the estimate here; the test proves nothing")
        // A new size is a new layout: numbering starts afresh.
        session.configure(style: ReaderEngineTests.style, textSize: CGSize(width: 280, height: 420))
        _ = session.paginatedChapter(spine)
        #expect(session.bookPages(spineIndex: spine, page: 0).page == legacy(spine, page: 0))
    }
}
