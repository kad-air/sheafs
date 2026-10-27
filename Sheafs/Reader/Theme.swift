import SwiftUI
import UIKit

/// The colors of a reading theme.
struct ReaderPalette: Hashable, Sendable {
    var background: UIColor
    var text: UIColor
    var secondary: UIColor
    var link: UIColor
    /// What the page stands on in the tabletop pose (`TabletopBaseView`, the deck): a shade
    /// darker than the paper, so the page reads as a sheet with an edge rather than a colour
    /// that runs out at the fold.
    var surface: UIColor
    var isDark: Bool

    static let paper = ReaderPalette(
        background: UIColor(red: 0.985, green: 0.975, blue: 0.955, alpha: 1),
        text: UIColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1),
        secondary: UIColor(red: 0.52, green: 0.50, blue: 0.47, alpha: 1),
        link: UIColor(red: 0.45, green: 0.30, blue: 0.18, alpha: 1),
        surface: UIColor(red: 0.905, green: 0.893, blue: 0.870, alpha: 1),
        isDark: false)

    static let sepia = ReaderPalette(
        background: UIColor(red: 0.96, green: 0.925, blue: 0.85, alpha: 1),
        text: UIColor(red: 0.24, green: 0.19, blue: 0.13, alpha: 1),
        secondary: UIColor(red: 0.56, green: 0.49, blue: 0.40, alpha: 1),
        link: UIColor(red: 0.50, green: 0.32, blue: 0.16, alpha: 1),
        surface: UIColor(red: 0.872, green: 0.832, blue: 0.752, alpha: 1),
        isDark: false)

    static let night = ReaderPalette(
        background: UIColor(red: 0.07, green: 0.07, blue: 0.075, alpha: 1),
        text: UIColor(red: 0.82, green: 0.81, blue: 0.79, alpha: 1),
        secondary: UIColor(red: 0.50, green: 0.50, blue: 0.49, alpha: 1),
        link: UIColor(red: 0.78, green: 0.64, blue: 0.45, alpha: 1),
        surface: UIColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1),
        isDark: true)

    /// Pure black for OLED: the unlit pixels are the page. The text is dimmed a little further than
    /// Night's so white-on-black does not glare in the dark.
    static let black = ReaderPalette(
        background: UIColor(red: 0, green: 0, blue: 0, alpha: 1),
        text: UIColor(red: 0.74, green: 0.73, blue: 0.71, alpha: 1),
        secondary: UIColor(red: 0.45, green: 0.45, blue: 0.44, alpha: 1),
        link: UIColor(red: 0.72, green: 0.59, blue: 0.42, alpha: 1),
        surface: UIColor(red: 0, green: 0, blue: 0, alpha: 1),
        isDark: true)

    /// The colours of `theme` while the device is in `system` mode; Automatic stands for `light` or
    /// `dark` (the user's picks in the appearance settings).
    static func resolve(_ theme: ReaderTheme, system: ColorScheme, light: ReaderTheme, dark: ReaderTheme) -> ReaderPalette {
        switch theme {
        case .paper: .paper
        case .sepia: .sepia
        case .night: .night
        case .black: .black
        case .system: resolve(system == .dark ? dark : light, system: system, light: .paper, dark: .night)
        }
    }

    /// The colour scheme the reader runs in, so its bars and sheets match the page: the palette's
    /// own, so Automatic with Night as its Light-mode theme still gets dark bars.
    /// 🔴 Always a value, never nil. `preferredColorScheme(nil)` does NOT undo an earlier forced
    /// scheme on the presentation: after Night, choosing Automatic kept the reader dark in Light
    /// mode. And the system's scheme must come from the window scene (`SystemColorSchemeReader`),
    /// not the environment's `colorScheme`, which the forced scheme itself overrides (reading it
    /// latched the first value, so live Light/Dark changes never reached the page).
    var colorScheme: ColorScheme { isDark ? .dark : .light }
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
