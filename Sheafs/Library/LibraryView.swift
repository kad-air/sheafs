import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author, added
    var id: Self { self }
    var title: String {
        switch self {
        case .recent: "Recently Read"
        case .title: "Title"
        case .author: "Author"
        case .added: "Date Added"
        }
    }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Query private var books: [Book]
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var sort: LibrarySort = .recent
    @State private var pendingDelete: Book?

    private var visibleBooks: [Book] {
        let filtered = searchText.isEmpty ? books : books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
                ($0.author ?? "").localizedCaseInsensitiveContains(searchText)
        }
        switch sort {
        case .recent:
            return filtered.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .title:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            return filtered.sorted { ($0.author ?? "").localizedStandardCompare($1.author ?? "") == .orderedAscending }
        case .added:
            return filtered.sorted { $0.addedAt > $1.addedAt }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView {
                        Label("No Books Yet", systemImage: "books.vertical")
                    } description: {
                        Text("Add an EPUB from Files, or download one from a catalog.")
                    } actions: {
                        Button("Add Book", systemImage: "plus") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                        Button("Browse Catalogs", systemImage: "square.grid.2x2") { navigation.selectedTab = .catalogs }
                    }
                } else {
                    grid
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Title or author")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Book", systemImage: "plus") { showImporter = true }
                }
                .visibilityPriority(.high)
                ToolbarItem(placement: .secondaryAction) {
                    Picker("Sort", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    for url in urls { await library.importFromOutside(url) }
                }
            }
            .confirmationDialog("Delete this book?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { book in
                Button("Delete \(book.title)", role: .destructive) { library.delete(book) }
            } message: { _ in
                Text("The file and your reading position will be removed from this device.")
            }
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let hasFold = !proxy.divisions().isEmpty
            let width = proxy.size.width - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing
            let columns = Self.columnCount(for: width, evenRequired: hasFold)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: columns),
                          alignment: .center, spacing: 24) {
                    ForEach(visibleBooks) { book in
                        BookCell(book: book)
                            .onTapGesture { navigation.open(book) }
                            .contextMenu { contextMenu(for: book) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// Columns for the width; an even count when a fold runs through the grid, so no cover
    /// sits on the crease.
    nonisolated static func columnCount(for width: CGFloat, evenRequired: Bool) -> Int {
        var count = max(2, Int(width / 150))
        if evenRequired, count % 2 == 1 { count += 1 }
        return count
    }

    @ViewBuilder
    private func contextMenu(for book: Book) -> some View {
        Button("Read", systemImage: "book") { navigation.open(book) }
        Button(book.isFinished ? "Mark as Unread" : "Mark as Finished",
               systemImage: book.isFinished ? "circle" : "checkmark.circle") {
            book.finishedAt = book.isFinished ? nil : .now
            library.save()
        }
        Button("Start Over", systemImage: "arrow.counterclockwise") {
            book.spineIndex = 0
            book.textOffset = 0
            book.progress = 0
            book.xpointer = nil
            book.finishedAt = nil
            library.save()
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = book }
    }
}

struct BookCell: View {
    let book: Book
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(book: book, url: book.hasCover ? library.coverURL(for: book) : nil)
                .overlay(alignment: .bottom) {
                    if book.progress > 0, !book.isFinished {
                        ProgressView(value: book.progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if book.isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.title3)
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.author ?? ""), \(book.percentLabel) read")
    }
}
