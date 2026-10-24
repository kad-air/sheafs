import Foundation
import Testing
@testable import Sheafs

/// Volume-button page turns: how a volume reading becomes a press. iOS moves the volume in steps
/// of 1/16 (0.0625), so those are the readings a real press produces; expected values are by hand.
struct VolumeButtonTests {
    /// The slider works: each press is followed by the put-back's reading, which is not a press.
    @Test func pressesWithPutBacksTurnOncePerPress() {
        var reader = PressReader(previous: 0.5, reference: 0.5)
        #expect(reader.read(0.4375, at: 1.0) == .down)
        reader.didPutBack(at: 1.0)
        #expect(reader.read(0.500_000_1, at: 1.1) == nil)  // the put-back, give or take float noise
        #expect(reader.read(0.5625, at: 2.0) == .up)
        reader.didPutBack(at: 2.0)
        #expect(reader.read(0.5, at: 2.1) == nil)
        // Two quick presses before the put-back lands are two presses.
        #expect(reader.read(0.4375, at: 3.0) == .down)
        reader.didPutBack(at: 3.0)
        #expect(reader.read(0.375, at: 3.05) == .down)
        #expect(reader.read(0.5, at: 3.2) == nil)
    }

    /// The slider fails to put the volume back (build 5 compared against a fixed reference, so the
    /// second press here read as "up" and turned backward): direction must come from the last reading.
    @Test func directionIsRightWhenTheVolumeIsNotPutBack() {
        var reader = PressReader(previous: 0.5, reference: 0.5)
        #expect(reader.read(0.5625, at: 1.0) == .up)
        reader.didPutBack(at: 1.0)
        #expect(reader.read(0.5, at: 2.0) == .down)  // long after the put-back: a real press back down
        #expect(reader.read(0.4375, at: 3.0) == .down)
        #expect(reader.read(0.375, at: 4.0) == .down)
        // The same reading again is no press.
        #expect(reader.read(0.375, at: 5.0) == nil)
    }

    /// At either end of the range a press could not move the volume, so it would never be seen.
    @Test func referenceKeepsAStepFromBothEnds() {
        #expect(PressReader.reference(for: 0) == 0.125)
        #expect(PressReader.reference(for: 1) == 0.875)
        #expect(PressReader.reference(for: 0.5) == 0.5)
        // From the clamped reference a press in either direction still reads.
        var low = PressReader(previous: 0.125, reference: 0.125)
        #expect(low.read(0.0625, at: 1) == .down)
        var high = PressReader(previous: 0.875, reference: 0.875)
        #expect(high.read(0.9375, at: 1) == .up)
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
