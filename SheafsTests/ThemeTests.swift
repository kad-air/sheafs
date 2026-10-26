import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Sheafs

/// The Black theme and the Light/Dark picks behind Automatic.
struct ThemeTests {
    /// Black is pure #000000 (OLED pixels off), not a near-black like Night.
    @Test func blackIsPureBlack() {
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        #expect(ReaderPalette.black.background.getRed(&r, green: &g, blue: &b, alpha: &a))
        #expect(r == 0 && g == 0 && b == 0 && a == 1)
        #expect(ReaderPalette.black.isDark)
        #expect(ReaderPalette.black != ReaderPalette.night)
        #expect(ReaderPalette.resolve(.black, system: .light, light: .paper, dark: .night) == .black)
    }

    @Test func automaticFollowsTheDeviceThroughTheUsersPicks() {
        #expect(ReaderPalette.resolve(.system, system: .light, light: .paper, dark: .night) == .paper)
        #expect(ReaderPalette.resolve(.system, system: .dark, light: .paper, dark: .night) == .night)
        #expect(ReaderPalette.resolve(.system, system: .light, light: .sepia, dark: .black) == .sepia)
        #expect(ReaderPalette.resolve(.system, system: .dark, light: .sepia, dark: .black) == .black)
        // Fixed themes ignore the picks and the device.
        #expect(ReaderPalette.resolve(.sepia, system: .dark, light: .paper, dark: .black) == .sepia)
    }

    /// The reader's bars follow the page, not the device: Automatic with Night for Light mode runs
    /// dark in Light mode, and resolving again from the DEVICE scheme keeps Night (resolving from
    /// the forced `.dark` would jump to the Dark-mode pick).
    @Test func barsFollowThePageNotTheDevice() {
        let page = ReaderPalette.resolve(.system, system: .light, light: .night, dark: .black)
        #expect(page == .night)
        #expect(page.colorScheme == .dark)
        #expect(ReaderPalette.paper.colorScheme == .light)
        #expect(ReaderPalette.sepia.colorScheme == .light)
        #expect(ReaderPalette.black.colorScheme == .dark)
    }

    /// 🔴 Settings saved before the Light/Dark picks existed still decode (a missing non-optional
    /// key fails the whole decode and resets every setting), and come out as Paper / Night.
    @Test func settingsSavedBeforeThePicksStillDecode() throws {
        let old = #"{"theme":"sepia","font":"georgia","fontSize":22,"lineHeight":1.5,"margin":30,"justified":true,"hyphenate":false,"paragraphStyle":"spaced","keepScreenAwake":false,"tapToTurn":true,"highlightColor":"yellow","pageTurn":"slide","volumeButtonsTurn":true}"#
        let stored = try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(old.utf8))
        #expect(stored.theme == .sepia)
        #expect(stored.fontSize == 22)
        #expect(stored.lightTheme == nil && stored.darkTheme == nil)

        let new = #"{"theme":"black","font":"georgia","fontSize":22,"lineHeight":1.5,"margin":30,"justified":true,"hyphenate":false,"paragraphStyle":"spaced","keepScreenAwake":false,"tapToTurn":true,"lightTheme":"sepia","darkTheme":"black"}"#
        let picked = try JSONDecoder().decode(ReaderSettings.Stored.self, from: Data(new.utf8))
        #expect(picked.theme == .black && picked.lightTheme == .sepia && picked.darkTheme == .black)
    }

    @Test func automaticCannotStandForItself() {
        #expect(!ReaderTheme.fixed.contains(.system))
        #expect(ReaderTheme.fixed.contains(.black))
        #expect(ReaderTheme.fixed.count == ReaderTheme.allCases.count - 1)
    }
}
