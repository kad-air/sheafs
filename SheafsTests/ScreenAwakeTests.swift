import Foundation
import Testing
@testable import Sheafs

/// The screen stays on while pages turn and goes back to the system's Auto-Lock once they stop.
/// Times are worked by hand from a fixed start; `check(at:)` stands in for the scheduled check.
/// `scripts/check-screen-awake` runs the real timer against the simulator's SpringBoard.
@MainActor
struct ScreenAwakeTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// The awake object and every value it gave UIKit, in order.
    private func make() -> (ScreenAwake, () -> [Bool]) {
        var calls: [Bool] = []
        let awake = ScreenAwake(setIdleTimerDisabled: { calls.append($0) }, schedules: false)
        return (awake, { calls })
    }

    /// 🔴 The bug: the screen was held on for as long as a book was open. Now it lets go once the
    /// window passes with no turn.
    @Test func theScreenLetsGoOnceThePagesStopTurning() {
        let (awake, calls) = make()
        awake.start(window: 300, reason: "test", at: at(0))
        #expect(calls() == [true])
        awake.check(at: at(299))
        #expect(awake.isHolding)
        awake.check(at: at(300))
        #expect(!awake.isHolding)
        #expect(calls() == [true, false])
    }

    @Test func everyTurnHoldsItOnForAnotherWindow() {
        let (awake, calls) = make()
        awake.start(window: 300, reason: "test", at: at(0))
        awake.activity("page turn", at: at(200))
        awake.activity("page turn", at: at(450))
        awake.check(at: at(500))     // the first deadline (300) is long gone
        #expect(awake.isHolding)
        awake.check(at: at(749))
        #expect(awake.isHolding)
        awake.check(at: at(750))
        #expect(!awake.isHolding)
        // Turns only record the time: the system is told once per change, not once per turn.
        #expect(calls() == [true, false])
    }

    @Test func aTurnAfterItLetGoHoldsItOnAgain() {
        let (awake, calls) = make()
        awake.start(window: 120, reason: "test", at: at(0))
        awake.check(at: at(130))
        #expect(!awake.isHolding)
        awake.activity("volume button", at: at(400))
        #expect(awake.isHolding)
        awake.check(at: at(519))
        #expect(awake.isHolding)
        awake.check(at: at(520))
        #expect(calls() == [true, false, true, false])
    }

    @Test func offLeavesTheIdleTimerToTheSystem() {
        let (awake, calls) = make()
        awake.start(window: nil, reason: "Off", at: at(0))
        awake.activity("page turn", at: at(10))
        #expect(!awake.isHolding)
        #expect(calls() == [false])
    }

    /// Changing the setting while reading counts from the change, at the new length.
    @Test func aNewWindowCountsFromTheChange() {
        let (awake, _) = make()
        awake.start(window: 1800, reason: "30 min", at: at(0))
        awake.start(window: 120, reason: "2 min", at: at(60))
        awake.check(at: at(179))
        #expect(awake.isHolding)
        awake.check(at: at(180))
        #expect(!awake.isHolding)
    }

    @Test func closingTheReaderGivesTheScreenBack() {
        let (awake, calls) = make()
        awake.start(window: 300, reason: "test", at: at(0))
        awake.stop(reason: "reader closed")
        #expect(!awake.isHolding)
        awake.activity("late touch", at: at(5))
        #expect(!awake.isHolding)
        #expect(calls() == [true, false])
    }

    /// The menu's values are minutes; Off has no window.
    @Test func theWindowsAreMinutes() {
        #expect(ScreenAwakeWindow.off.seconds == nil)
        #expect(ScreenAwakeWindow.fiveMinutes.seconds == 300)
        #expect(ScreenAwakeWindow.thirtyMinutes.seconds == 1800)
        #expect(ScreenAwakeWindow.standard == .fiveMinutes)
    }

    /// 🔴 Settings saved by builds with the old "Keep screen awake" switch still decode, and the
    /// switch carries over: on (which never let the screen sleep) becomes the standard window.
    @Test func theOldSwitchCarriesOver() throws {
        let on = #"{"theme":"sepia","font":"georgia","fontSize":22,"lineHeight":1.5,"margin":30,"justified":true,"hyphenate":false,"paragraphStyle":"spaced","keepScreenAwake":true,"tapToTurn":true}"#
        let off = on.replacingOccurrences(of: #""keepScreenAwake":true"#, with: #""keepScreenAwake":false"#)
        let wasOn = try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(on.utf8))
        let wasOff = try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(off.utf8))
        #expect(wasOn.screenAwakeMinutes == nil)
        #expect(ReaderSettings.screenAwake(minutes: wasOn.screenAwakeMinutes, keepScreenAwake: wasOn.keepScreenAwake) == .fiveMinutes)
        #expect(ReaderSettings.screenAwake(minutes: wasOff.screenAwakeMinutes, keepScreenAwake: wasOff.keepScreenAwake) == .off)

        let picked = on.replacingOccurrences(of: #""tapToTurn":true"#, with: #""tapToTurn":true,"screenAwakeMinutes":30"#)
        let stored = try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(picked.utf8))
        #expect(ReaderSettings.screenAwake(minutes: stored.screenAwakeMinutes, keepScreenAwake: stored.keepScreenAwake) == .thirtyMinutes)
        // A value no build offers (a later menu, a hand edit) falls back instead of failing.
        #expect(ReaderSettings.screenAwake(minutes: 7, keepScreenAwake: true) == .fiveMinutes)
    }
}
