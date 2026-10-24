import SwiftUI

/// The reading fonts, each named in its own face. A system `Menu` (or a menu-style `Picker`) draws
/// every item in the system font whatever the label asks for, so the font choice lives here instead:
/// a popover from the quick panel, a pushed page from the detailed sheet. Picking dismisses either.
struct FontList: View {
    @Binding var selection: ReaderFont
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(ReaderFont.allCases) { font in
            Button {
                selection = font
                dismiss()
            } label: {
                HStack {
                    Text(font.title)
                        .font(Font(font.font(size: 19)))
                    Spacer()
                    if font == selection {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityAddTraits(font == selection ? .isSelected : [])
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}
