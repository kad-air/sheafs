import SwiftUI
import UIKit

/// The colors of a reading theme.
struct ReaderPalette: Hashable, Sendable {
    var background: UIColor
    var text: UIColor
    var secondary: UIColor
    var link: UIColor
    var isDark: Bool

    static let paper = ReaderPalette(
        background: UIColor(red: 0.985, green: 0.975, blue: 0.955, alpha: 1),
        text: UIColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1),
        secondary: UIColor(red: 0.52, green: 0.50, blue: 0.47, alpha: 1),
        link: UIColor(red: 0.45, green: 0.30, blue: 0.18, alpha: 1),
        isDark: false)

    static let sepia = ReaderPalette(
        background: UIColor(red: 0.96, green: 0.925, blue: 0.85, alpha: 1),
        text: UIColor(red: 0.24, green: 0.19, blue: 0.13, alpha: 1),
        secondary: UIColor(red: 0.56, green: 0.49, blue: 0.40, alpha: 1),
        link: UIColor(red: 0.50, green: 0.32, blue: 0.16, alpha: 1),
        isDark: false)

    static let night = ReaderPalette(
        background: UIColor(red: 0.07, green: 0.07, blue: 0.075, alpha: 1),
        text: UIColor(red: 0.82, green: 0.81, blue: 0.79, alpha: 1),
        secondary: UIColor(red: 0.50, green: 0.50, blue: 0.49, alpha: 1),
        link: UIColor(red: 0.78, green: 0.64, blue: 0.45, alpha: 1),
        isDark: true)

    static func resolve(_ theme: ReaderTheme, colorScheme: ColorScheme) -> ReaderPalette {
        switch theme {
        case .paper: .paper
        case .sepia: .sepia
        case .night: .night
        case .system: colorScheme == .dark ? .night : .paper
        }
    }

    /// The colour scheme the reader forces so its bars and sheets match the page, or nil to follow
    /// the device. 🔴 Automatic must be nil: the reader resolves the palette from the environment's
    /// `colorScheme`, and a forced scheme overrides that same environment, so the first value would
    /// latch and live Light/Dark changes would never reach the page.
    static func forcedColorScheme(for theme: ReaderTheme) -> ColorScheme? {
        switch theme {
        case .paper, .sepia: .light
        case .night: .dark
        case .system: nil
        }
    }
}

extension Color {
    init(_ uiColor: UIColor, _ unused: Void = ()) { self.init(uiColor: uiColor) }
}
