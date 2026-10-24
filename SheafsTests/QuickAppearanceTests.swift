import Testing
@testable import Sheafs

/// The quick panel's −/+ buttons move along the detailed sheet's slider grids, so both menus land on
/// the same values. Expected values are worked by hand, not computed with the function under test.
struct QuickAppearanceTests {
    @Test func textSizeStepsByOnePointAndStopsAtTheEnds() {
        #expect(ReaderSettings.step(19, by: 1, grid: ReaderSettings.fontSizeGrid, in: ReaderSettings.fontSizeRange) == 20)
        #expect(ReaderSettings.step(19, by: -1, grid: ReaderSettings.fontSizeGrid, in: ReaderSettings.fontSizeRange) == 18)
        #expect(ReaderSettings.step(32, by: 1, grid: ReaderSettings.fontSizeGrid, in: ReaderSettings.fontSizeRange) == 32)
        #expect(ReaderSettings.step(12, by: -1, grid: ReaderSettings.fontSizeGrid, in: ReaderSettings.fontSizeRange) == 12)
    }

    @Test func lineSpacingMovesTwoSliderStepsWithoutFloatNoise() {
        let grid = ReaderSettings.lineHeightGrid, range = ReaderSettings.lineHeightRange
        // 1.1 + 7 × 0.05 in floating point is 1.4500000000000002; the step must come out exact.
        #expect(ReaderSettings.step(1.4, by: 2, grid: grid, in: range) == 1.5)
        #expect(ReaderSettings.step(1.45, by: 2, grid: grid, in: range) == 1.55)
        #expect(ReaderSettings.step(1.45, by: -2, grid: grid, in: range) == 1.35)
        #expect(ReaderSettings.step(1.85, by: 2, grid: grid, in: range) == 1.9)
        #expect(ReaderSettings.step(1.15, by: -2, grid: grid, in: range) == 1.1)
        // An off-grid value (older builds, hand-edited defaults) snaps to the nearest grid point first.
        #expect(ReaderSettings.step(1.43, by: 2, grid: grid, in: range) == 1.55)
    }

    @Test func marginsMoveFourPointsAndStopAtTheEnds() {
        let grid = ReaderSettings.marginGrid, range = ReaderSettings.marginRange
        #expect(ReaderSettings.step(24, by: 2, grid: grid, in: range) == 28)
        #expect(ReaderSettings.step(24, by: -2, grid: grid, in: range) == 20)
        #expect(ReaderSettings.step(54, by: 2, grid: grid, in: range) == 56)
        #expect(ReaderSettings.step(10, by: -2, grid: grid, in: range) == 8)
    }

    /// The defaults sit on the grids, so the first tap moves by exactly one quick step.
    @Test func defaultsSitOnTheGrids() {
        let stored = ReaderSettings.Stored()
        #expect(ReaderSettings.step(stored.fontSize, by: 0, grid: ReaderSettings.fontSizeGrid,
                                    in: ReaderSettings.fontSizeRange) == stored.fontSize)
        #expect(ReaderSettings.step(stored.lineHeight, by: 0, grid: ReaderSettings.lineHeightGrid,
                                    in: ReaderSettings.lineHeightRange) == stored.lineHeight)
        #expect(ReaderSettings.step(stored.margin, by: 0, grid: ReaderSettings.marginGrid,
                                    in: ReaderSettings.marginRange) == stored.margin)
    }
}
