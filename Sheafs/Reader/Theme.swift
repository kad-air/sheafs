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

    /// The colour scheme the reader runs in: the theme's own for a fixed theme, else the system's.
    /// 🔴 Always a value, never nil. `preferredColorScheme(nil)` does NOT undo an earlier forced
    /// scheme on the presentation: after Night, choosing Automatic kept the reader dark in Light
    /// mode. And the system's scheme must come from the window scene (`SystemColorSchemeReader`),
    /// not the environment's `colorScheme`, which the forced scheme itself overrides (reading it
    /// latched the first value, so live Light/Dark changes never reached the page).
    static func colorScheme(for theme: ReaderTheme, system: ColorScheme) -> ColorScheme {
        switch theme {
        case .paper, .sepia: .light
        case .night: .dark
        case .system: system
        }
    }
}

/// Reports the device's Light/Dark setting from the window scene's traits, which no view
/// controller's `overrideUserInterfaceStyle` (what `preferredColorScheme` sets) can change.
struct SystemColorSchemeReader: UIViewRepresentable {
    var onChange: (ColorScheme) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) { view.onChange = onChange }

    final class Probe: UIView {
        var onChange: ((ColorScheme) -> Void)?
        private weak var observed: UIWindowScene?
        private var registration: (any UITraitChangeRegistration)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, scene !== observed else { return }
            if let registration, let observed { observed.unregisterForTraitChanges(registration) }
            observed = scene
            registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (scene: UIWindowScene, _) in
                self?.report(scene)
            }
            report(scene)
        }

        private func report(_ scene: UIWindowScene) {
            let scheme: ColorScheme = scene.traitCollection.userInterfaceStyle == .dark ? .dark : .light
            print("[theme] system scheme \(scheme)")
            let onChange = onChange
            // Not during the layout pass that SwiftUI is running.
            DispatchQueue.main.async { onChange?(scheme) }
        }
    }
}

extension Color {
    init(_ uiColor: UIColor, _ unused: Void = ()) { self.init(uiColor: uiColor) }
}
