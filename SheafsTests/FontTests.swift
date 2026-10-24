import Testing
import UIKit
@testable import Sheafs

/// Every reading font must resolve to its own family on iOS. `ReaderFont.font(size:)` falls back to
/// the system font for a family that isn't installed, and a fallback looks like a perfectly good
/// font in the font list and on the page, so check the resolved family by name, plus a real bold and
/// italic face (a missing trait silently keeps the regular face).
struct FontTests {
    @Test(arguments: ReaderFont.allCases)
    func resolvesToItsOwnFamily(_ font: ReaderFont) {
        let regular = font.font(size: 17)
        switch font {
        case .newYork:
            // New York is the system font's serif design; its family reads ".AppleSystemUIFontSerif".
            #expect(regular.familyName == ".AppleSystemUIFontSerif", "\(font) resolved to \(regular.familyName)")
        case .sanFrancisco:
            #expect(regular.familyName == UIFont.systemFont(ofSize: 17).familyName)
        default:
            #expect(regular.familyName == font.familyName, "\(font) resolved to \(regular.familyName)")
        }
        #expect(font.font(size: 17, bold: true).fontName != regular.fontName, "\(font) has no bold face")
        #expect(font.font(size: 17, italic: true).fontName != regular.fontName, "\(font) has no italic face")
    }

    /// Only the system font itself may come out as the system font.
    @Test func serifChoicesAreNotTheSystemFont() {
        let system = UIFont.systemFont(ofSize: 17).familyName
        let fallbacks = ReaderFont.allCases.filter { $0 != .sanFrancisco && $0.font(size: 17).familyName == system }
        #expect(fallbacks.isEmpty, "fell back to the system font: \(fallbacks)")
    }
}
