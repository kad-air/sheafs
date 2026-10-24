import Foundation
import Testing
@testable import Sheafs

/// Volume-button page turns: how a volume reading becomes a press. iOS moves the volume in steps
/// of 1/16 (0.0625), so those are the readings a real press produces; expected values are by hand.
struct VolumeButtonTests {
    @Test func oneStepEitherWayIsAPressAndTheResetIsNot() {
        #expect(VolumeButtonPager.press(volume: 0.5625, reference: 0.5) == .up)
        #expect(VolumeButtonPager.press(volume: 0.4375, reference: 0.5) == .down)
        // The hidden slider putting the volume back reports the reference (give or take float noise).
        #expect(VolumeButtonPager.press(volume: 0.5, reference: 0.5) == nil)
        #expect(VolumeButtonPager.press(volume: 0.500_000_1, reference: 0.5) == nil)
    }

    /// At either end of the range a press could not move the volume, so it would never be seen.
    @Test func referenceKeepsAStepFromBothEnds() {
        #expect(VolumeButtonPager.reference(for: 0) == 0.125)
        #expect(VolumeButtonPager.reference(for: 1) == 0.875)
        #expect(VolumeButtonPager.reference(for: 0.5) == 0.5)
        // From the clamped reference a press in either direction still reads.
        #expect(VolumeButtonPager.press(volume: 0.0625, reference: 0.125) == .down)
        #expect(VolumeButtonPager.press(volume: 0.9375, reference: 0.875) == .up)
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
