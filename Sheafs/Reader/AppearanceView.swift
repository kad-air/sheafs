import SwiftUI

/// Theme, font, size, spacing and margin controls for the reading surface.
struct AppearanceView: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.spreadFoldGap) private var readerFoldGap
    @State private var windowFoldGap: CGFloat?

    /// True when pushed inside an existing navigation stack (Settings): no stack and no Done button.
    var embedded = false
    /// Opens scrolled to the margins (`-SheafsAppearance full-margins`, for screenshots).
    var scrollsToMargins = false

    /// Over the reader: the spread it shows. In Settings (no reader up): the spread the reader
    /// would lay out in this window (the Duo's inner display, an iPad in landscape).
    private var foldGap: CGFloat? { embedded ? windowFoldGap : readerFoldGap }

    var body: some View {
        if embedded {
            form
                .background {
                    GeometryReader { window in
                        Color.clear.onChange(of: PageLayout.foldGap(window: window), initial: true) { _, new in
                            windowFoldGap = new
                        }
                    }
                    .ignoresSafeArea()
                }
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
        ScrollViewReader { scroller in
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
                Section {
                    Picker("Light", systemImage: "sun.max", selection: $settings.lightTheme) {
                        ForEach(ReaderTheme.fixed) { Text($0.title).tag($0) }
                    }
                    Picker("Dark", systemImage: "moon", selection: $settings.darkTheme) {
                        ForEach(ReaderTheme.fixed) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Automatic")
                } footer: {
                    Text("The themes Automatic uses while the device is in Light and Dark mode.")
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
                }
                Section {
                    MarginSliders(foldGap: foldGap)
                } header: {
                    Text("Margins")
                } footer: {
                    if foldGap == nil {
                        Text("Gutter, the space between two pages, appears while two pages are side by side.")
                    }
                }
                .id("margins")
                Section("Paragraphs") {
                    Picker("Style", selection: $settings.paragraphStyle) {
                        ForEach(ParagraphStyleChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Justify", isOn: $settings.justified)
                    Toggle("Hyphenate", isOn: $settings.hyphenate)
                }
                Section {
                    Picker("Page Turn", selection: $settings.pageTurn) {
                        ForEach(PageTurnStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Tap edges to turn pages", isOn: $settings.tapToTurn)
                    Toggle("Volume buttons turn pages", isOn: $settings.volumeButtonsTurn)
                    Picker("Keep screen awake", selection: $settings.screenAwake) {
                        ForEach(ScreenAwakeWindow.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Reading")
                } footer: {
                    Text(settings.screenAwake == .off
                         ? "The screen locks with Auto-Lock, as in any other app."
                         : "The screen stays on for \(settings.screenAwake.rawValue) minutes after the last page turn or touch, then locks with Auto-Lock.")
                }
            }
            .onAppear {
                guard scrollsToMargins else { return }
                DispatchQueue.main.async { scroller.scrollTo("margins", anchor: .top) }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
