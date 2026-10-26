import Foundation
import Testing
@testable import Sheafs

/// Volume-button page turns: how a volume reading becomes a press. Readings are the ones an iPhone
/// Duo on iOS 27.1 reported (TestFlight build 7's Volume Button Log): the volume moves in the
/// device's own steps (0.0, 0.05, 0.15, 0.2, 0.25, 0.3), not iOS's nominal 1/16, and a put-back
/// lands exactly only on a value the device itself reported. Expected values by hand.
struct VolumeButtonTests {
    /// Every press is put back: the press reads, the landing (exact, the reference is on the
    /// device's grid) does not, and the next press reads again. The level never drifts.
    @Test func everyPressIsPutBackAndTheLandingIsNotAPress() {
        var reader = PressReader(previous: 0.25, reference: 0.25)
        #expect(!reader.needsPutBack)
        #expect(reader.read(0.3, at: 51.063) == .up)
        #expect(reader.needsPutBack)
        reader.didPutBack(at: 51.064)
        #expect(reader.read(0.25, at: 51.07) == nil)
        #expect(!reader.needsPutBack)
        #expect(reader.read(0.2, at: 52.295) == .down)
        reader.didPutBack(at: 52.296)
        #expect(reader.read(0.25, at: 52.30) == nil)
        #expect(reader.read(0.3, at: 53.096) == .up)
        #expect(reader.reference == 0.25)
    }

    /// 🔴 Build 7's log, replayed: the volume started at 0.0, the put-back aimed at 0.125 and
    /// LANDED at 0.15. Build 7 kept aiming at 0.125, so every landing (0.15 again) read as "up":
    /// pages turned at random. Now the landing becomes the reference, and the next put-back (to
    /// 0.15, a value the device reported) lands exactly: 0.2 up, 0.15 landing, 0.05 down, 0.15
    /// landing, each press one page the right way.
    @Test func thePutBackLandingBecomesTheReference() {
        var reader = PressReader(previous: 0.0, reference: 0.125)
        #expect(reader.needsPutBack)
        reader.didPutBack(at: 45.031)
        #expect(reader.read(0.15, at: 45.034) == nil)
        #expect(reader.reference == 0.15)
        #expect(!reader.needsPutBack)
        #expect(reader.read(0.2, at: 47.103) == .up)
        reader.didPutBack(at: 47.104)
        #expect(reader.read(0.15, at: 47.159) == nil)
        #expect(reader.read(0.05, at: 47.988) == .down)
        reader.didPutBack(at: 47.989)
        #expect(reader.read(0.15, at: 48.0) == nil)
        #expect(reader.reference == 0.15)
    }

    /// A landing past the reference is still the put-back (and is adopted).
    @Test func aLandingPastTheReferenceIsStillTheLanding() {
        var reader = PressReader(previous: 0.0, reference: 0.25)
        reader.didPutBack(at: 0)
        #expect(reader.read(0.3, at: 0.05) == nil)
        #expect(reader.reference == 0.3)
        #expect(reader.read(0.25, at: 2) == .down)
    }

    /// Two quick presses the same way: the second arrives before the first's landing and still
    /// reads (it is farther from the reference, not nearer); the landing then reads as nothing.
    @Test func aSecondPressBeforeTheLandingStillCounts() {
        var reader = PressReader(previous: 0.25, reference: 0.25)
        #expect(reader.read(0.3, at: 10) == .up)
        reader.didPutBack(at: 10.001)
        #expect(reader.read(0.35, at: 10.05) == .up)
        reader.didPutBack(at: 10.051)
        #expect(reader.read(0.25, at: 10.08) == nil)
        #expect(reader.reference == 0.25)
    }

    /// A press toward the reference before the put-back lands is taken for the landing; the
    /// volume is right afterwards and the next press reads normally.
    @Test func aPressTowardTheReferenceDuringAPutBackIsTheLanding() {
        var reader = PressReader(previous: 0.25, reference: 0.25)
        #expect(reader.read(0.3, at: 10) == .up)
        reader.didPutBack(at: 10.001)
        #expect(reader.read(0.25, at: 10.02) == nil)
        #expect(reader.read(0.2, at: 11) == .down)
    }

    /// The put-back's window closes: a reading long after it is a press, whatever its value.
    @Test func aReadingAfterThePutBackWindowIsAPress() {
        var reader = PressReader(previous: 0.3, reference: 0.25)
        reader.didPutBack(at: 10)
        #expect(reader.read(0.25, at: 12) == .down)
    }

    /// A failed put-back (the slider missing, as on the simulator) must not flip directions: a
    /// press is read from the previous reading, not from the reference.
    @Test func aFailedPutBackKeepsDirectionsRight() {
        var reader = PressReader(previous: 0.25, reference: 0.25)
        #expect(reader.read(0.3, at: 10) == .up)
        reader.didPutBack(at: 10.001)   // nothing lands
        #expect(reader.read(0.35, at: 12) == .up)
        #expect(reader.read(0.3, at: 13) == .down)
    }

    /// Volume up goes forward, down goes back (chosen after trying the reverse on the device).
    @Test func volumeUpTurnsForward() {
        #expect(VolumeButtonPager.Press.up.turnsForward)
        #expect(!VolumeButtonPager.Press.down.turnsForward)
    }

    /// The reference keeps one step of room either way (a down press at 0 goes unseen), else it
    /// is the user's own volume, which is not moved at all.
    @Test func referenceIsTheUsersVolumeKeptOffTheEnds() {
        #expect(PressReader.reference(for: 0) == 0.1)
        #expect(PressReader.reference(for: 1) == 0.9)
        #expect(PressReader.reference(for: 0.5) == 0.5)
        #expect(PressReader.reference(for: 0.35) == 0.35)
        #expect(PressReader(previous: 0.0, reference: 0.1).needsPutBack)
        #expect(!PressReader(previous: 0.35, reference: 0.35).needsPutBack)
    }

    /// Settings saved before the key existed must still decode (a non-optional missing key resets
    /// every setting), and the buttons stay off until the user turns them on.
    @Test func settingsFromBeforeTheKeyStillDecodeWithTheButtonsOff() throws {
        let saved = #"""
        {"theme":"sepia","font":"newYork","fontSize":23,"lineHeight":1.5,"margin":28,"justified":true,
         "hyphenate":false,"paragraphStyle":"indented","keepScreenAwake":false,"tapToTurn":false,
         "highlightColor":"yellow","pageTurn":"slide"}
        """#
        let stored = try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(saved.utf8))
        #expect(stored.fontSize == 23)
        #expect(stored.tapToTurn == false)
        #expect(stored.volumeButtonsTurn == nil)
        #expect(ReaderSettings.Stored().volumeButtonsTurn == nil)
    }
}

extension VolumeButtonTests {
    /// The put-back first moves the slider to the real volume (it lags the system; a set to the
    /// value it already holds is a no-op), and the device echoes that same reading (Duo log:
    /// 0.35 up, put back, 0.35 again, then 0.3). The echo is neither a press nor the landing.
    @Test func thePutBacksEchoOfTheSameReadingIsNothing() {
        var reader = PressReader(previous: 0.3, reference: 0.3)
        #expect(reader.read(0.35, at: 10) == .up)
        reader.didPutBack(at: 10.001)
        #expect(reader.read(0.35, at: 10.01) == nil)
        #expect(reader.needsPutBack)
        #expect(reader.read(0.3, at: 10.02) == nil)
        #expect(!reader.needsPutBack)
        #expect(reader.reference == 0.3)
    }
}
