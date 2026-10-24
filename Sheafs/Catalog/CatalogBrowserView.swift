import SwiftUI
import SwiftData
import SheafsKit

/// One OPDS feed: sub-catalogs as rows, books as a cover grid, with paging, search and refresh.
/// Sub-catalogs push another `CatalogBrowserView`; books push `CatalogEntryView`.
struct CatalogBrowserView: View {
    let title: String
    let connection: CatalogConnection
    @State private var model: CatalogFeedModel
    @State private var searchText = ""
    @Query private var books: [Book]

    init(url: URL, title: String, connection: CatalogConnection) {
        self.title = title
        self.connection = connection
        self.model = CatalogFeedModel(url: url, connection: connection)
    }

    private var navigationTitle: String {
        guard let feedTitle = model.browse?.feed.title, !feedTitle.isEmpty else { return title }
        return feedTitle
    }

    var body: some View {
        content
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.browse == nil)
                }
            }
            .modifier(FeedSearch(model: model, text: $searchText))
            .task { model.load() }
            .alert("Couldn’t Refresh", isPresented: Binding(
                get: { model.refreshError != nil },
                set: { if !$0 { model.refreshError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.refreshError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isSearching {
            ProgressView("Searching…")
        } else if let message = model.searchError {
            ContentUnavailableView {
                Label("Search Failed", systemImage: "magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", systemImage: "arrow.clockwise") { model.search(searchText) }
                    .buttonStyle(.borderedProminent)
            }
        } else if let listing = model.shown {
            if listing.isEmpty {
                empty
            } else {
                CatalogListingView(listing: listing, model: model, connection: connection,
                                   libraryURLs: Set(books.compactMap(\.sourceURL)))
            }
        } else if case .failed(let message) = model.phase {
            ContentUnavailableView {
                Label("Can’t Load Catalog", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", systemImage: "arrow.clockwise") { model.retry() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var empty: some View {
        if model.results != nil {
            ContentUnavailableView.search(text: model.query)
        } else {
            ContentUnavailableView("Nothing Here", systemImage: "tray",
                                   description: Text("This part of the catalog is empty."))
        }
    }
}

/// Adds a search field when the feed advertises a search link. Submitting runs the search;
/// emptying the field brings the feed back.
private struct FeedSearch: ViewModifier {
    let model: CatalogFeedModel
    @Binding var text: String

    func body(content: Content) -> some View {
        if model.searchLink != nil {
            content
                .searchable(text: $text, prompt: "Search this catalog")
                .onSubmit(of: .search) { model.search(text) }
                .onChange(of: text) { _, new in
                    if new.isEmpty { model.clearSearch() }
                }
        } else {
            content
        }
    }
}

// MARK: - Listing

/// The entries of a feed: a plain list for sub-catalog rows only, else a scrolling column of
/// rows (if any) above a cover grid.
private struct CatalogListingView: View {
    let listing: CatalogFeedModel.Listing
    let model: CatalogFeedModel
    let connection: CatalogConnection
    let libraryURLs: Set<String>

    var body: some View {
        if listing.books.isEmpty {
            List {
                ForEach(listing.rows) { item in
                    CatalogRow(entry: item.entry, connection: connection, showsChevron: false)
                }
                if listing.nextURL != nil {
                    PaginationFooter(listing: listing, model: model)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
            .scrollDismissesKeyboard(.immediately)
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let hasFold = !proxy.reservedRegions(kind: .division, options: [.includeInactive]).isEmpty
            let width = proxy.size.width - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing
            let columns = LibraryView.columnCount(for: width, evenRequired: hasFold)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(listing.rows) { item in
                        CatalogRow(entry: item.entry, connection: connection, showsChevron: true)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        Divider().padding(.leading, 20)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: columns),
                              alignment: .center, spacing: 24) {
                        ForEach(listing.books) { item in
                            NavigationLink {
                                CatalogEntryView(entry: item.entry, connection: connection)
                            } label: {
                                CatalogEntryCell(entry: item.entry, connection: connection,
                                                 inLibrary: isInLibrary(item.entry))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    if listing.nextURL != nil {
                        PaginationFooter(listing: listing, model: model)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                }
            }
            .refreshable { await model.refresh() }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func isInLibrary(_ entry: OPDSEntry) -> Bool {
        guard let href = entry.epubLink?.href.absoluteString else { return false }
        return libraryURLs.contains(href)
    }
}

/// Spinner at the end of a paged feed. It appearing is the signal to fetch the next page, and
/// `task(id:)` fires again when a page lands but the footer is still on screen (a short page).
/// A failed page swaps the spinner for a retry button so a bad server cannot loop.
private struct PaginationFooter: View {
    let listing: CatalogFeedModel.Listing
    let model: CatalogFeedModel

    var body: some View {
        Group {
            if let message = listing.loadMoreError {
                VStack(spacing: 8) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again", systemImage: "arrow.clockwise") { model.retryLoadMore() }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .task(id: listing.nextURL) { model.loadMore() }
    }
}

// MARK: - Rows and cells

/// A sub-catalog entry that pushes the next feed. An entry with no link to follow is shown but
/// does nothing.
private struct CatalogRow: View {
    let entry: OPDSEntry
    let connection: CatalogConnection
    let showsChevron: Bool

    var body: some View {
        if let link = entry.navigationLink {
            NavigationLink {
                CatalogBrowserView(url: link.href, title: entry.title, connection: connection)
            } label: {
                CatalogRowLabel(entry: entry, showsChevron: showsChevron)
            }
        } else {
            CatalogRowLabel(entry: entry, showsChevron: false)
        }
    }
}

private struct CatalogRowLabel: View {
    let entry: OPDSEntry
    /// A `List` adds its own disclosure indicator to a `NavigationLink`; outside one we draw it.
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A book in the grid: cover, title, author, and an "In Library" badge when it was downloaded.
private struct CatalogEntryCell: View {
    let entry: OPDSEntry
    let connection: CatalogConnection
    let inLibrary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CatalogCoverView(title: entry.title, author: entry.authors.first,
                             url: entry.thumbnailURL, connection: connection)
                .overlay(alignment: .bottomLeading) {
                    if inLibrary { InLibraryBadge().padding(6) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !entry.authors.isEmpty {
                    Text(entry.authors.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title), \(entry.authors.joined(separator: ", "))\(inLibrary ? ", in library" : "")")
    }
}
