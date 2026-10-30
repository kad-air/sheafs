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

/// Every highlight, note and pencil marking of the book, in reading order; tap to go there,
/// swipe to delete.
struct NotesListView: View {
    let session: BookSession
    let annotations: [Annotation]
    var sketches: [Sketch] = []
    var onSelect: (ReadingLocation) -> Void
    @Environment(LibraryStore.self) private var library
    @State private var editing: Annotation?

    /// A row of the list: a highlight (or note) or a pencil marking.
    enum Entry: Identifiable {
        case annotation(Annotation)
        case sketch(Sketch)

        var id: UUID {
            switch self {
            case .annotation(let annotation): annotation.id
            case .sketch(let sketch): sketch.id
            }
        }

        var location: ReadingLocation {
            switch self {
            case .annotation(let annotation): ReadingLocation(spineIndex: annotation.spineIndex, textOffset: annotation.startOffset)
            case .sketch(let sketch): sketch.location
            }
        }
    }

    /// Highlights and markings together in reading order (a highlight first where both start at one place).
    static func entries(annotations: [Annotation], sketches: [Sketch]) -> [Entry] {
        let all = annotations.map(Entry.annotation) + sketches.map(Entry.sketch)
        return all.enumerated().sorted { a, b in
            let x = a.element.location, y = b.element.location
            if x.spineIndex != y.spineIndex { return x.spineIndex < y.spineIndex }
            if x.textOffset != y.textOffset { return x.textOffset < y.textOffset }
            return a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        Group {
            if annotations.isEmpty && sketches.isEmpty {
                ContentUnavailableView("No Highlights Yet", systemImage: "highlighter",
                                       description: Text("Press and hold a word on the page to select text, then choose Highlight or Note. To write or draw on the page, tap Markup."))
            } else {
                List(Self.entries(annotations: annotations, sketches: sketches)) { entry in
                    Button {
                        onSelect(entry.location)
                    } label: {
                        switch entry {
                        case .annotation(let annotation): row(annotation)
                        case .sketch(let sketch): row(sketch)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        switch entry {
                        case .annotation(let annotation):
                            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(annotation) }
                            Button("Edit", systemImage: "pencil") { editing = annotation }
                                .tint(.accentColor)
                        case .sketch(let sketch):
                            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(sketch) }
                        }
                    }
                    .contextMenu {
                        switch entry {
                        case .annotation(let annotation):
                            Button("Edit", systemImage: "pencil") { editing = annotation }
                            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(annotation) }
                        case .sketch(let sketch):
                            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(sketch) }
                        }
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

    /// A pencil marking: the marking over its text as drawn, then the text it is on or beside.
    private func row(_ sketch: Sketch) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SketchThumbnail(data: sketch.thumbnail)
            VStack(alignment: .leading, spacing: 4) {
                Text(sketch.text.isEmpty ? "Pencil marking" : sketch.text)
                    .font(.system(.body, design: .serif))
                    .lineLimit(3)
                HStack {
                    Label("Markup", systemImage: "pencil.tip")
                        .labelStyle(.iconOnly)
                    if let title = session.chapterTitle(for: sketch.spineIndex) { Text(title).lineLimit(1) }
                    Spacer()
                    Text(sketch.createdAt, format: .dateTime.day().month().year())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Pencil marking: \(sketch.text)"))
    }

    /// What a pencil marking reads as in the Markdown export.
    static let sketchNote = "(Marked with Apple Pencil)"

    /// The highlights, notes and pencil markings, then the bookmarks, as Markdown, for the share sheet.
    static func markdown(book: Book, session: BookSession, annotations: [Annotation], bookmarks: [Bookmark] = [],
                         sketches: [Sketch] = []) -> String {
        let items = entries(annotations: annotations, sketches: sketches).map { entry -> (chapter: String?, text: String, note: String) in
            switch entry {
            case .annotation(let annotation): (session.chapterTitle(for: annotation.spineIndex), annotation.text, annotation.note)
            case .sketch(let sketch): (session.chapterTitle(for: sketch.spineIndex), sketch.text, sketchNote)
            }
        }
        return AnnotationExport.markdown(title: book.title, author: book.author, annotations: items,
                                         bookmarks: bookmarks.map { (session.chapterTitle(for: $0.spineIndex), $0.label) })
    }
}

/// A pencil marking's picture in the notes list: the page as it looked with the marking on it.
struct SketchThumbnail: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 96, height: 72)
        .background(.quaternary.opacity(0.4))
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .accessibilityHidden(true)
    }
}
