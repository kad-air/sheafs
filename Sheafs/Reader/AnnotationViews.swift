import SwiftUI
import SwiftData

/// Edits one highlight: its colour or underline, its note, and where it is in the book.
struct AnnotationEditorView: View {
    @Bindable var annotation: Annotation
    let session: BookSession
    /// Pushed inside another navigation stack (the notes list) rather than shown as its own sheet.
    var embedded = false
    var onJump: (ReadingLocation) -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        if embedded {
            form
        } else {
            NavigationStack {
                form
                    .navigationTitle(annotation.hasNote ? "Note" : "Highlight")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(uiColor: annotation.color.base))
                        .frame(width: 4)
                    Text(annotation.text)
                        .font(.system(.body, design: .serif))
                        .lineLimit(8)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let title = session.chapterTitle(for: annotation.spineIndex), !title.isEmpty {
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Color") {
                HStack(spacing: 18) {
                    ForEach(HighlightColor.allCases) { option in
                        Button {
                            annotation.color = option
                            settings.highlightColor = option
                            touch()
                        } label: {
                            Circle()
                                .fill(Color(uiColor: option.base))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if annotation.color == option {
                                        Image(systemName: "checkmark")
                                            .font(.footnote.bold())
                                            .foregroundStyle(.black.opacity(0.7))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                    }
                    Spacer()
                }
                Toggle("Underline", isOn: Binding(
                    get: { annotation.isUnderline },
                    set: { annotation.isUnderline = $0; touch() }
                ))
            }
            Section("Note") {
                TextEditor(text: Binding(get: { annotation.note }, set: { annotation.note = $0; touch() }))
                    .frame(minHeight: 120)
            }
            Section {
                Button("Show in Book", systemImage: "book") {
                    onJump(ReadingLocation(spineIndex: annotation.spineIndex, textOffset: annotation.startOffset))
                }
                Button("Delete Highlight", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete this highlight?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(annotation)
                dismiss()
            }
        } message: {
            Text(annotation.hasNote ? "The note goes with it." : "")
        }
        .onDisappear { library.save() }
    }

    private func touch() {
        annotation.modifiedAt = .now
    }
}

/// Every highlight and note of the book, in reading order; tap to go there, swipe to delete.
struct NotesListView: View {
    let session: BookSession
    let annotations: [Annotation]
    var onSelect: (ReadingLocation) -> Void
    @Environment(LibraryStore.self) private var library
    @State private var editing: Annotation?

    var body: some View {
        Group {
            if annotations.isEmpty {
                ContentUnavailableView("No Highlights Yet", systemImage: "highlighter",
                                       description: Text("Press and hold a word on the page to select text, then choose Highlight or Note."))
            } else {
                List(annotations) { annotation in
                    Button {
                        onSelect(ReadingLocation(spineIndex: annotation.spineIndex, textOffset: annotation.startOffset))
                    } label: {
                        row(annotation)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { library.delete(annotation) }
                        Button("Edit", systemImage: "pencil") { editing = annotation }
                            .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = annotation }
                        Button("Delete", systemImage: "trash", role: .destructive) { library.delete(annotation) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationDestination(item: $editing) { annotation in
            AnnotationEditorView(annotation: annotation, session: session, embedded: true) { location in
                editing = nil
                onSelect(location)
            }
            .navigationTitle(annotation.hasNote ? "Note" : "Highlight")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ annotation: Annotation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(uiColor: annotation.color.base))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(annotation.text)
                    .font(.system(.body, design: .serif))
                    .lineLimit(3)
                if annotation.hasNote {
                    Text(annotation.note)
                        .font(.subheadline)
                        .lineLimit(4)
                }
                HStack {
                    if let title = session.chapterTitle(for: annotation.spineIndex) { Text(title).lineLimit(1) }
                    Spacer()
                    Text(annotation.createdAt, format: .dateTime.day().month().year())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The whole list as Markdown, for the share sheet.
    static func markdown(book: Book, session: BookSession, annotations: [Annotation]) -> String {
        AnnotationExport.markdown(title: book.title, author: book.author, annotations: annotations.map {
            (session.chapterTitle(for: $0.spineIndex), $0.text, $0.note)
        })
    }
}
