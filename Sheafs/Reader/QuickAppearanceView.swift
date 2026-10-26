import SwiftUI

/// The small appearance panel that floats over the bottom of the page, so the text being adjusted
/// stays in view (Books' "Themes & Settings"). Everything with a visible effect on the page is here;
/// "All Settings" steps through to the detailed `AppearanceView` sheet.
struct QuickAppearanceView: View {
    var onMore: () -> Void
    var onClose: () -> Void
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var showFonts = false

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ReaderTheme.allCases) { theme in
                    swatch(theme)
                }
                Spacer(minLength: 4)
                Button("All Settings", systemImage: "slider.horizontal.3", action: onMore)
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: Circle())
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: Circle())
            }
            HStack(spacing: 8) {
                StepPill(caption: "Size", display: "\(Int(settings.fontSize))",
                         decrease: ("Smaller Text", "textformat.size.smaller"),
                         increase: ("Larger Text", "textformat.size.larger"),
                         value: $settings.fontSize, steps: 1,
                         grid: ReaderSettings.fontSizeGrid, range: ReaderSettings.fontSizeRange)
                fontMenu
            }
            HStack(spacing: 8) {
                StepPill(caption: "Spacing", display: settings.lineHeight.formatted(.number.precision(.fractionLength(1 ... 2))),
                         decrease: ("Tighter Lines", "minus"), increase: ("Looser Lines", "plus"),
                         value: $settings.lineHeight, steps: 2,
                         grid: ReaderSettings.lineHeightGrid, range: ReaderSettings.lineHeightRange)
                StepPill(caption: "Margins", display: "\(Int(settings.margin))",
                         decrease: ("Narrower Margins", "minus"), increase: ("Wider Margins", "plus"),
                         value: $settings.margin, steps: 2,
                         grid: ReaderSettings.marginGrid, range: ReaderSettings.marginRange)
            }
            HStack(spacing: 8) {
                Chip(title: "Justify", systemImage: "text.justify", isOn: $settings.justified)
                Chip(title: "Hyphenate", systemImage: "character.text.justify", isOn: $settings.hyphenate)
                Chip(title: "Indent", systemImage: "increase.indent", isOn: Binding(
                    get: { settings.paragraphStyle == .indented },
                    set: { settings.paragraphStyle = $0 ? .indented : .spaced }))
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: 420)
        .glassEffect(in: .rect(cornerRadius: 26))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.snappy, value: settings.theme)
    }

    private var fontMenu: some View {
        @Bindable var settings = settings
        return Button {
            showFonts = true
        } label: {
            HStack(spacing: 4) {
                Text(settings.font.title)
                    .font(Font(settings.font.font(size: 17)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(Capsule())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Font, \(settings.font.title)")
        .popover(isPresented: $showFonts) {
            FontList(selection: $settings.font)
                .frame(idealWidth: 280, idealHeight: 470)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func swatch(_ theme: ReaderTheme) -> some View {
        let selected = settings.theme == theme
        // Automatic shows its two halves: the Light-mode theme over the Dark-mode one.
        let light = settings.palette(.system, system: .light), dark = settings.palette(.system, system: .dark)
        let fill: AnyShapeStyle = theme == .system
            ? AnyShapeStyle(LinearGradient(stops: [.init(color: Color(uiColor: light.background), location: 0.5),
                                                   .init(color: Color(uiColor: dark.background), location: 0.5)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(Color(uiColor: settings.palette(theme, system: colorScheme).background))
        let ink = Color(uiColor: settings.palette(theme, system: colorScheme).text)
        return Button {
            settings.theme = theme
        } label: {
            // Mid grey reads on both halves of the Automatic swatch.
            Text("Aa")
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(theme == .system ? Color(white: 0.5) : ink)
                .frame(width: 36, height: 36)
                .background(fill, in: Circle())
                .overlay(Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5))
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5).padding(-4))
                .padding(4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// [−] caption/value [+], moving a setting along its slider grid.
private struct StepPill: View {
    var caption: String
    var display: String
    var decrease: (title: String, image: String)
    var increase: (title: String, image: String)
    @Binding var value: Double
    var steps: Int
    var grid: Double
    var range: ClosedRange<Double>

    init(caption: String, display text: String, decrease: (String, String), increase: (String, String),
         value: Binding<Double>, steps: Int, grid: Double, range: ClosedRange<Double>) {
        self.caption = caption
        self.display = text
        self.decrease = decrease
        self.increase = increase
        _value = value
        self.steps = steps
        self.grid = grid
        self.range = range
    }

    var body: some View {
        let down = ReaderSettings.step(value, by: -steps, grid: grid, in: range)
        let up = ReaderSettings.step(value, by: steps, grid: grid, in: range)
        HStack(spacing: 0) {
            Button(decrease.title, systemImage: decrease.image) { value = down }
                .disabled(down == value)
                .frame(width: 44, height: 44)
            VStack(spacing: 0) {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
                Text(display).font(.subheadline.monospacedDigit().weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Button(increase.title, systemImage: increase.image) { value = up }
                .disabled(up == value)
                .frame(width: 44, height: 44)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.primary)
        .background(.fill.tertiary, in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(caption)
    }
}

/// A toggle drawn as a capsule that fills with the tint when on.
private struct Chip: View {
    var title: String
    var systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(isOn ? Color.white : .primary)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
