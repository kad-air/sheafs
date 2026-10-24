import Testing
@testable import Sheafs

/// "Back to page N" after following a link: the trail of places jumped away from. Pages here are
/// 100 characters long, worked by hand.
struct ReturnTrailTests {
    private func loc(_ spine: Int, _ offset: Int) -> ReadingLocation { ReadingLocation(spineIndex: spine, textOffset: offset) }
    private let samePage: (ReadingLocation, ReadingLocation) -> Bool = { a, b in
        a.spineIndex == b.spineIndex && a.textOffset / 100 == b.textOffset / 100
    }

    @Test func followingALinkRemembersWhereItLeftFromAndBackReturnsThere() {
        var trail = ReturnTrail()
        trail.leave(loc(3, 1250), for: loc(9, 40), samePage: samePage)
        #expect(trail.last == loc(3, 1250))
        #expect(trail.back() == loc(3, 1250))
        #expect(trail.isEmpty)
        #expect(trail.back() == nil)
    }

    /// The label keeps the number the folio showed when you left, even if pages are re-cut later.
    @Test func eachStopKeepsThePageNumberItWasLeftFrom() {
        var trail = ReturnTrail()
        trail.leave(loc(3, 1250), page: 10, for: loc(9, 40), samePage: samePage)
        trail.leave(loc(9, 40), page: 195, for: loc(1, 0), samePage: samePage)
        #expect(trail.lastPage == 195)
        _ = trail.back()
        #expect(trail.lastPage == 10)
    }

    @Test func hopsRetraceInReverse() {
        var trail = ReturnTrail()
        trail.leave(loc(3, 1250), for: loc(9, 40), samePage: samePage)   // text → endnote
        trail.leave(loc(9, 40), for: loc(1, 0), samePage: samePage)      // endnote → bibliography
        #expect(trail.back() == loc(9, 40))
        #expect(trail.back() == loc(3, 1250))
    }

    @Test func aJumpOnTheSamePageIsNotAPlaceToComeBackFrom() {
        var trail = ReturnTrail()
        trail.leave(loc(3, 1210), for: loc(3, 1290), samePage: samePage)
        #expect(trail.isEmpty)
        // The same spine but another page is.
        trail.leave(loc(3, 1210), for: loc(3, 1300), samePage: samePage)
        #expect(trail.last == loc(3, 1210))
    }

    @Test func jumpingAgainFromTheSamePageDoesNotStackItTwice() {
        var trail = ReturnTrail()
        trail.leave(loc(3, 1250), for: loc(9, 40), samePage: samePage)
        #expect(trail.back() == loc(3, 1250))
        trail.leave(loc(3, 1250), for: loc(9, 40), samePage: samePage)
        #expect(trail.stops.map(\.location) == [loc(3, 1250)])
        // The pager had not reported landing yet: a second jump from the remembered page.
        trail.leave(loc(3, 1260), for: loc(7, 0), samePage: samePage)
        #expect(trail.stops.map(\.location) == [loc(3, 1250)])
    }

    @Test func turningPagesBackOntoTheStopLeavesTheTrail() {
        var trail = ReturnTrail()
        trail.leave(loc(3, 1250), for: loc(3, 1500), samePage: samePage)
        trail.arrived(at: loc(3, 1400), samePage: samePage)
        #expect(trail.last == loc(3, 1250), "a page short of it keeps the button")
        trail.arrived(at: loc(3, 1200), samePage: samePage)
        #expect(trail.isEmpty)
    }

    @Test func theTrailKeepsTheMostRecentStops() {
        var trail = ReturnTrail()
        for spine in 0 ..< 30 { trail.leave(loc(spine, 0), for: loc(spine + 100, 0), samePage: samePage) }
        #expect(trail.stops.count == ReturnTrail.limit)
        #expect(trail.stops.first?.location == loc(10, 0))
        #expect(trail.last == loc(29, 0))
    }
}
