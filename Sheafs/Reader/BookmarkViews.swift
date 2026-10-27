import SwiftUI

/// Every bookmark of the book, in reading order: the page's first words, its chapter and when it
/// was made; tap to go there (`jump(to:)`, so "Back to page N" returns), swipe to delete.
struct BookmarksListView: View {
    let session: BookSession
    let bookmarks: [Bookmark]
    var onSelect: (ReadingLocation) -> Void
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if bookmarks.isEmpty {
            ContentUnavailableView("No Bookmarks Yet", systemImage: "bookmark",
                                   description: Text("Tap the bookmark button in the toolbar to mark the page you’re on."))
        } else {
            List(bookmarks) { bookmark in
                Button {
                    onSelect(bookmark.location)
                } label: {
                    row(bookmark)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { library.delete(bookmark) }
                }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { library.delete(bookmark) }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
                .imageScale(.small)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.label.isEmpty ? "Bookmark" : bookmark.label)
                    .font(.system(.body, design: .serif))
                    .lineLimit(2)
                HStack {
                    if let title = session.chapterTitle(for: bookmark.spineIndex) { Text(title).lineLimit(1) }
                    Spacer()
                    Text(bookmark.createdAt, format: .dateTime.day().month().year())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
