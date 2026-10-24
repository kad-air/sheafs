import Testing
import SwiftUI
@testable import Sheafs

/// Nothing but the display itself may move the text: not the bars coming and going, not the status
/// bar's cluster or a Live Activity, which the system reports as occlusion regions just like the cover
/// display's camera hole. The cover-display insets are the ones the iPhone Duo simulator logged while
/// toggling the bars; the inner-display occlusion is the status cluster from a device screenshot
/// (clock, Wi-Fi and a Live Activity ring at the top of the vertical bar), which pushed both pages'
/// text down below it.
struct SteadyPageGeometryTests {
    static let cover = CGSize(width: 466, height: 678)
    static let coverCamera = [CGRect(x: 399.67, y: 29.33, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: 82)]
    static let inner = CGSize(width: 951, height: 669)
    static let innerFold = CGRect(x: 475.5, y: 0, width: 0, height: 669)
    static let statusCluster = CGRect(x: 878, y: 28, width: 48, height: 72)

    static func coverInput(top: CGFloat, bottom: CGFloat, occlusions: [CGRect] = coverCamera) -> PageLayout.Input {
        PageLayout.Input(size: cover, safeArea: EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 84),
                         division: nil, divisionIsActive: false, occlusions: occlusions,
                         margin: 24, fontSize: 19, allowSpread: true, fullBleed: true)
    }

    static func innerInput(top: CGFloat, bottom: CGFloat, occlusions: [CGRect] = [],
                           foldActive: Bool = false) -> PageLayout.Input {
        PageLayout.Input(size: inner, safeArea: EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 84),
                         division: innerFold, divisionIsActive: foldActive, occlusions: occlusions,
                         margin: 24, fontSize: 19, allowSpread: true, fullBleed: true)
    }

    /// Feeds inputs as the reader sees them and returns every layout it would have drawn.
    struct Replay {
        var geometry = SteadyPageGeometry()
        var layouts: [PageLayout] = []
        var now: TimeInterval = 100
        mutating func see(_ fresh: PageLayout.Input, barsVisible: Bool, after seconds: TimeInterval = 0.1) {
            now += seconds
            geometry.observe(fresh, barsVisible: barsVisible, now: now)
            layouts.append(PageLayout.compute(geometry.input(for: fresh)))
        }
    }

    @Test func togglingTheBarsOnTheCoverDisplayLeavesTheTextAlone() {
        var replay = Replay()
        replay.see(Self.coverInput(top: 0, bottom: 34), barsVisible: false)
        let reading = replay.layouts[0]
        #expect(reading.pageFrames == [CGRect(x: 0, y: 0, width: 466, height: 644)])
        // Long after opening: tap, the strip then the status bar arrive; tap, they leave in the other
        // order (this half-gone state laid the page 24 pt lower and repaginated it).
        replay.see(Self.coverInput(top: 0, bottom: 142.67), barsVisible: true, after: 10)
        replay.see(Self.coverInput(top: 24, bottom: 142.67, occlusions: [Self.coverCamera[0],
                                   CGRect(x: 382, y: 0, width: 84, height: 174)]), barsVisible: true)
        replay.see(Self.coverInput(top: 24, bottom: 34), barsVisible: false, after: 3)
        replay.see(Self.coverInput(top: 0, bottom: 34), barsVisible: false)
        for layout in replay.layouts { #expect(layout == reading) }
    }

    @Test func theStatusClusterAndLiveActivitiesDoNotPushTheSpreadDown() {
        var replay = Replay()
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false)
        let reading = replay.layouts[0]
        #expect(reading.isSpread)
        #expect(reading.textInsets.top == PageLayout.headerHeight)
        // The bars come up: status bar inset plus the clock/Wi-Fi cluster as an occlusion.
        replay.see(Self.innerInput(top: 24, bottom: 20, occlusions: [Self.statusCluster]), barsVisible: true, after: 10)
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false, after: 3)
        // A Live Activity pops in while reading, bars hidden.
        replay.see(Self.innerInput(top: 0, bottom: 20, occlusions: [Self.statusCluster]), barsVisible: false, after: 20)
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false, after: 5)
        for layout in replay.layouts { #expect(layout == reading) }
    }

    @Test func theCoverCameraIsStillAvoided() {
        var replay = Replay()
        replay.see(Self.coverInput(top: 0, bottom: 34), barsVisible: false)
        // The text starts 2 pt below the hole (29.33 + 37 + 2), as before.
        #expect(abs(replay.layouts[0].textInsets.top - 68.33) < 0.01)
        #expect(replay.layouts[0].occlusions == [Self.coverCamera[0]])
    }

    @Test func foldingIntoBookPoseIsFollowedAtOnce() {
        var replay = Replay()
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false)
        replay.see(Self.innerInput(top: 0, bottom: 20, foldActive: true), barsVisible: false, after: 10)
        let flat = replay.layouts[0], book = replay.layouts[1]
        // Flat: a 14 pt gutter each side of the zero-width fold; book pose: the fold frame + 2 pt.
        // Page edges land on whole points, rounded away from the fold.
        #expect(flat.pageFrames[1].minX == 490)
        #expect(book.pageFrames[1].minX == 478)
    }

    @Test func aNewDisplaySettlesWhileTheBarsLeaveThenLocks() {
        var replay = Replay()
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false)
        // Fold to the cover display while the bars were up: the reader hides them, so the first
        // cover-display states still carry their insets for a moment.
        replay.see(Self.coverInput(top: 24, bottom: 142.67), barsVisible: false, after: 10)
        replay.see(Self.coverInput(top: 24, bottom: 34), barsVisible: false, after: 0.2)
        replay.see(Self.coverInput(top: 0, bottom: 34), barsVisible: false, after: 0.3)
        #expect(replay.layouts.last?.pageFrames == [CGRect(x: 0, y: 0, width: 466, height: 644)])
        // Locked from here on.
        replay.see(Self.coverInput(top: 24, bottom: 34), barsVisible: false, after: 5)
        #expect(replay.layouts.last?.pageFrames == [CGRect(x: 0, y: 0, width: 466, height: 644)])
    }
}
