import SwiftUI

/// Theme, font, size and spacing controls for the reading surface.
struct AppearanceView: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// True when pushed inside an existing navigation stack (Settings): no stack and no Done button.
    var embedded = false

    var body: some View {
        if embedded {
            form
        } else {
            NavigationStack {
                form
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
            }
        }
    }

    @ViewBuilder private var form: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section("Type") {
                NavigationLink {
                    FontList(selection: $settings.font)
                } label: {
                    LabeledContent("Font") {
                        Text(settings.font.title)
                            .font(Font(settings.font.font(size: 17)))
                    }
                }
                HStack {
                    Text("A").font(.system(size: 13))
                    Slider(value: $settings.fontSize, in: ReaderSettings.fontSizeRange, step: ReaderSettings.fontSizeGrid)
                    Text("A").font(.system(size: 24))
                }
                .accessibilityLabel("Text size")
                HStack {
                    Image(systemName: "text.alignleft").imageScale(.small)
                    Slider(value: $settings.lineHeight, in: ReaderSettings.lineHeightRange, step: ReaderSettings.lineHeightGrid)
                    Image(systemName: "text.alignleft")
                }
                .accessibilityLabel("Line spacing")
                HStack {
                    Image(systemName: "rectangle.compress.vertical").rotationEffect(.degrees(90))
                    Slider(value: $settings.margin, in: ReaderSettings.marginRange, step: ReaderSettings.marginGrid)
                    Image(systemName: "rectangle.expand.vertical").rotationEffect(.degrees(90))
                }
                .accessibilityLabel("Margins")
            }
            Section("Paragraphs") {
                Picker("Style", selection: $settings.paragraphStyle) {
                    ForEach(ParagraphStyleChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Justify", isOn: $settings.justified)
                Toggle("Hyphenate", isOn: $settings.hyphenate)
            }
            Section("Reading") {
                Picker("Page Turn", selection: $settings.pageTurn) {
                    ForEach(PageTurnStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Tap edges to turn pages", isOn: $settings.tapToTurn)
                Toggle("Keep screen awake", isOn: $settings.keepScreenAwake)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
