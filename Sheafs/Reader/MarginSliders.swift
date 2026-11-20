import SwiftUI

extension EnvironmentValues {
    /// The fold gap of the spread the reader shows (`PageLayout.foldGap`), nil while it shows one
    /// page: the margin controls offer the Gutter only over a spread, and give it as the space
    /// between the two columns of text.
    @Entry var spreadFoldGap: CGFloat?
}

/// The three margin sliders, the same in the quick panel and the detailed sheet: Side margins, Top
/// and bottom margins and, only while two pages are side by side (`foldGap`), Gutter. Each moves
/// its own edges and nothing else, and the pages re-lay as it is dragged (one step = 2 pt a side).
struct MarginSliders: View {
    var foldGap: CGFloat?
    @Environment(ReaderSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        MarginSlider(title: "Side margins", value: $settings.sideMargin, range: ReaderSettings.marginRange,
                     points: settings.sideMargin)
        MarginSlider(title: "Top and bottom margins", value: $settings.verticalMargin,
                     range: ReaderSettings.verticalMarginRange, points: settings.verticalMargin)
        if let foldGap {
            // Shown as the whole space between the columns: the fold plus each page's gutter.
            MarginSlider(title: "Gutter", value: $settings.gutter, range: ReaderSettings.marginRange,
                         points: Double(foldGap) + 2 * settings.gutter)
        }
    }
}

/// A margin's name and size in points over its slider.
private struct MarginSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    /// The distance on the page this slider sets, for the label.
    var points: Double

    var body: some View {
        let shown = Int(points.rounded())
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(shown) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: ReaderSettings.marginGrid) { Text(title) }
                .accessibilityValue("\(shown) points")
        }
    }
}
