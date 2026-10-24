import Foundation
import Testing
@testable import Sheafs

/// Volume-button page turns: how a volume reading becomes a press. Readings are the ones an iPhone
/// Duo on iOS 27.1 reported (TestFlight build 7's Volume Button Log): the volume moves in the
/// device's own steps (0.0, 0.05, 0.15, 0.2, 0.25), not iOS's nominal 1/16. Expected values by hand.
struct VolumeButtonTests {
    /// Mid-range, nothing is put back: each reading is one press, its direction from the last one.
    @Test func midRangePressesReadByTheirStep() {
        var reader = PressReader(previous: 0.15, reference: 0.25)
        #expect(!reader.needsPutBack)
        #expect(reader.read(0.2, at: 1) == .up)
        #expect(reader.read(0.15, at: 2) == .down)
        #expect(reader.read(0.2, at: 3) == .up)
        #expect(reader.read(0.25, at: 4) == .up)
        #expect(reader.read(0.25, at: 5) == nil)  // the same reading again is no press
        #expect(!reader.needsPutBack)
    }

    /// 🔴 Build 7: the volume started at 0.0, the put-back aimed at 0.125 and LANDED at 0.15, which
    /// it read as "up" and turned a page backward with no button pressed (every later put-back
    /// likewise). A landing short of or past the reference is still the put-back.
    @Test func aPutBackLandingOffTheReferenceIsNotAPress() {
        var reader = PressReader(previous: 0.0, reference: 0.25)
        #expect(reader.needsPutBack)
        reader.didPutBack(at: 45.031)
        #expect(reader.read(0.15, at: 45.034) == nil)
        #expect(!reader.needsPutBack)
        var past = PressReader(previous: 0.0, reference: 0.25)
        past.didPutBack(at: 0)
        #expect(past.read(0.3, at: 0.05) == nil)
        // After the landing, presses read normally again.
        #expect(past.read(0.25, at: 2) == .down)
    }

    /// Near the bottom a down press still reads before the put-back lands, and the landing then
    /// does not count.
    @Test func aPressAwayFromTheReferenceDuringAPutBackStillCounts() {
        var reader = PressReader(previous: 0.05, reference: 0.25)
        #expect(reader.needsPutBack)
        reader.didPutBack(at: 10)
        #expect(reader.read(0.0, at: 10.02) == .down)
        #expect(reader.read(0.25, at: 10.08) == nil)
    }

    /// A press toward the reference before the put-back lands is taken for the landing; the
    /// landing then reads as that press, so the page still turns once, the right way.
    @Test func aPressTowardTheReferenceDuringAPutBackTurnsOnce() {
        var reader = PressReader(previous: 0.05, reference: 0.25)
        reader.didPutBack(at: 10)
        #expect(reader.read(0.15, at: 10.02) == nil)
        #expect(reader.read(0.25, at: 10.08) == .up)
    }

    /// The put-back's window closes: a reading long after it is a press, whatever its value.
    @Test func aReadingAfterThePutBackWindowIsAPress() {
        var reader = PressReader(previous: 0.05, reference: 0.25)
        reader.didPutBack(at: 10)
        #expect(reader.read(0.15, at: 12) == .up)
    }

    @Test func referenceStaysWellInsideTheRange() {
        #expect(PressReader.reference(for: 0) == 0.25)
        #expect(PressReader.reference(for: 1) == 0.75)
        #expect(PressReader.reference(for: 0.5) == 0.5)
        #expect(PressReader(previous: 0.95, reference: 0.75).needsPutBack)
        #expect(PressReader(previous: 0.1, reference: 0.25).needsPutBack)
        #expect(!PressReader(previous: 0.85, reference: 0.75).needsPutBack)
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
