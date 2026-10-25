import Testing
import SwiftUI
@testable import Sheafs

/// Nothing but the display itself may move the text: not the bars coming and going. The cover-display
/// insets are the ones the iPhone Duo simulator logged while toggling the bars. (The status cluster
/// and Live Activities, which the system reports as occlusion regions, are not inputs at all any
/// more: only the cover camera's known spot is, `CoverCamera`.)
struct SteadyPageGeometryTests {
    static let cover = CGSize(width: 466, height: 678)
    static let coverCamera = CoverCamera.hole(window: cover, hasFold: false, orientation: .portrait)
    static let inner = CGSize(width: 951, height: 669)
    static let innerFold = CGRect(x: 475.5, y: 0, width: 0, height: 669)

    static func coverInput(top: CGFloat, bottom: CGFloat) -> PageLayout.Input {
        PageLayout.Input(size: cover, safeArea: EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 84),
                         division: nil, divisionIsActive: false, camera: coverCamera,
                         margin: 24, fontSize: 19, allowSpread: true, fullBleed: true)
    }

    static func innerInput(top: CGFloat, bottom: CGFloat, foldActive: Bool = false) -> PageLayout.Input {
        PageLayout.Input(size: inner, safeArea: EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 84),
                         division: innerFold, divisionIsActive: foldActive, camera: nil,
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
        replay.see(Self.coverInput(top: 24, bottom: 142.67), barsVisible: true)
        replay.see(Self.coverInput(top: 24, bottom: 34), barsVisible: false, after: 3)
        replay.see(Self.coverInput(top: 0, bottom: 34), barsVisible: false)
        for layout in replay.layouts { #expect(layout == reading) }
    }

    @Test func togglingTheBarsOnTheInnerDisplayLeavesTheSpreadAlone() {
        var replay = Replay()
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false)
        let reading = replay.layouts[0]
        #expect(reading.isSpread)
        #expect(reading.textInsets.top == PageLayout.headerHeight)
        #expect(reading.camera == nil)
        replay.see(Self.innerInput(top: 24, bottom: 20), barsVisible: true, after: 10)
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false, after: 3)
        for layout in replay.layouts { #expect(layout == reading) }
    }

    @Test func theCoverCameraIsStillAvoided() {
        var replay = Replay()
        replay.see(Self.coverInput(top: 0, bottom: 34), barsVisible: false)
        // The text starts 2 pt below the hole (29.33 + 37 + 2), as before.
        #expect(abs(replay.layouts[0].textInsets.top - 68.33) < 0.01)
        #expect(replay.layouts[0].camera == Self.coverCamera)
    }

    @Test func foldingIntoBookPoseIsFollowedAtOnce() {
        var replay = Replay()
        replay.see(Self.innerInput(top: 0, bottom: 20), barsVisible: false)
        // Long after the flat geometry locked, book pose arrives with other insets: a new display
        // state, so they are taken at once (the lock would have held the flat bottom inset).
        replay.see(Self.innerInput(top: 0, bottom: 34, foldActive: true), barsVisible: false, after: 10)
        let flat = replay.layouts[0], book = replay.layouts[1]
        #expect(flat.pageFrames[0].height == 649)
        #expect(book.pageFrames[0].height == 635)
        // The gutter is the same 44 pt in both poses (`minimumFoldGutter`), so the measure and every
        // line break stay put; page edges land on whole points, rounded away from the fold.
        #expect(flat.pageFrames.map(\.minX) == [0, 498])
        #expect(book.pageFrames.map(\.minX) == [0, 498])
        #expect(flat.pageFrames.map(\.width) == book.pageFrames.map(\.width))
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
