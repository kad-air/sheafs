import Foundation
import Observation
import SheafsKit
import os

/// State behind one catalog browser screen: the feed, its later pages, and search results.
///
/// Network work runs in tasks the model owns rather than in `.task` / `.refreshable`, so a
/// view that briefly disappears (a push, a pull-to-refresh re-render) cannot cancel a load.
@Observable
final class CatalogFeedModel {
    enum Phase {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct Item: Identifiable {
        struct ID: Hashable {
            let listing: Int
            let index: Int
        }

        let id: ID
        let entry: OPDSEntry
    }

    /// The entries of a feed and the pages appended after it, split into sub-catalog rows and
    /// books. Items get their own ids because servers do repeat entry ids across pages.
    struct Listing {
        let token: Int
        let kind: OPDSFeed.Kind
        /// The first page, for its title and search link.
        let feed: OPDSFeed
        private(set) var rows: [Item] = []
        private(set) var books: [Item] = []
        private(set) var nextURL: URL?
        var isLoadingMore = false
        var loadMoreError: String?
        private var requested: Set<URL> = []
        private var count = 0

        init(token: Int, feed: OPDSFeed, url: URL?) {
            self.token = token
            self.kind = feed.kind
            self.feed = feed
            if let url { requested.insert(url) }
            add(feed)
        }

        var isEmpty: Bool { rows.isEmpty && books.isEmpty }

        /// Notes that `url` is being fetched, so a server whose last page links back to an
        /// earlier one cannot loop the pagination.
        mutating func beginLoadingMore(_ url: URL) {
            requested.insert(url)
            isLoadingMore = true
            loadMoreError = nil
        }

        mutating func append(_ page: OPDSFeed) {
            add(page)
            isLoadingMore = false
        }

        private mutating func add(_ page: OPDSFeed) {
            for entry in page.entries {
                let item = Item(id: .init(listing: token, index: count), entry: entry)
                count += 1
                if isBook(entry) { books.append(item) } else { rows.append(item) }
            }
            if let next = page.nextURL, !requested.contains(next) {
                nextURL = next
            } else {
                nextURL = nil
            }
        }

        /// Books are entries that offer an acquisition; in an acquisition feed, so is anything
        /// that is not a sub-catalog. Everything else is a row.
        private func isBook(_ entry: OPDSEntry) -> Bool {
            if !entry.acquisitionLinks.isEmpty { return true }
            return kind == .acquisition && !entry.isNavigation
        }
    }

    let connection: CatalogConnection
    let rootURL: URL

    private(set) var phase: Phase = .idle
    /// The feed the screen was opened on.
    private(set) var browse: Listing?
    /// Results of the last successful search, shown in place of `browse`.
    private(set) var results: Listing?
    private(set) var isSearching = false
    private(set) var searchError: String?
    /// The query `results` / `searchError` belong to.
    private(set) var query = ""
    /// Set when a pull-to-refresh fails but there is still something on screen.
    var refreshError: String?

    @ObservationIgnored private var tokens = 0
    @ObservationIgnored private var searchToken = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.sheafs.reader", category: "catalog")

    init(url: URL, connection: CatalogConnection) {
        self.rootURL = url
        self.connection = connection
    }

    /// What the list should show: search results when there are any, else the feed.
    var shown: Listing? { results ?? browse }
    var searchLink: OPDSLink? { browse?.feed.searchLink }

    private func nextToken() -> Int {
        tokens += 1
        return tokens
    }

    // MARK: Loading

    /// Loads the feed once; later calls (a view reappearing) do nothing.
    func load() {
        if case .idle = phase { start() }
    }

    func retry() {
        if case .loading = phase { return }
        start()
    }

    private func start() {
        phase = .loading
        let url = rootURL
        let client = connection.client
        Task {
            let began = ContinuousClock.now
            do {
                let feed = try await client.feed(at: url)
                browse = Listing(token: nextToken(), feed: feed, url: url)
                phase = .loaded
                log.info("feed loaded: \(feed.entries.count) entries, \(feed.kind == .acquisition ? "acquisition" : "navigation"), next=\(feed.nextURL != nil), search=\(feed.searchLink != nil) in \(began.duration(to: .now).formatted())")
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.catalogMessage)
                log.error("feed failed after \(began.duration(to: .now).formatted()): \(String(describing: error))")
            }
        }
    }

    /// Reloads whatever is on screen: the search results while searching, else the feed. The
    /// old content stays up if this fails.
    func refresh() async {
        await Task { await reload() }.value
    }

    private func reload() async {
        if !query.isEmpty, results != nil {
            await runSearch(query, quiet: true)
            return
        }
        guard browse != nil else {
            retry()
            return
        }
        do {
            let feed = try await connection.client.feed(at: rootURL)
            browse = Listing(token: nextToken(), feed: feed, url: rootURL)
            log.info("feed refreshed: \(feed.entries.count) entries")
        } catch is CancellationError {
        } catch {
            refreshError = error.catalogMessage
            log.error("refresh failed: \(String(describing: error))")
        }
    }

    // MARK: Pagination

    /// Fetches the next page of what is shown, if there is one and none is on its way.
    func loadMore() {
        guard let listing = shown, !listing.isLoadingMore, listing.loadMoreError == nil,
              let next = listing.nextURL else { return }
        let token = listing.token
        update(token) { $0.beginLoadingMore(next) }
        let client = connection.client
        Task {
            do {
                let page = try await client.feed(at: next)
                update(token) { $0.append(page) }
                log.info("page loaded: +\(page.entries.count) entries")
            } catch is CancellationError {
                update(token) { $0.isLoadingMore = false }
            } catch {
                update(token) {
                    $0.isLoadingMore = false
                    $0.loadMoreError = error.catalogMessage
                }
                log.error("page failed: \(String(describing: error))")
            }
        }
    }

    func retryLoadMore() {
        guard let token = shown?.token else { return }
        update(token) { $0.loadMoreError = nil }
        loadMore()
    }

    /// Applies `change` to the listing with `token`, if it is still on screen (a refresh or a
    /// new search replaces listings while an old page request is in flight).
    private func update(_ token: Int, _ change: (inout Listing) -> Void) {
        if var listing = browse, listing.token == token {
            change(&listing)
            browse = listing
        } else if var listing = results, listing.token == token {
            change(&listing)
            results = listing
        }
    }

    // MARK: Search

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }
        searchTask?.cancel()
        searchTask = Task { await runSearch(trimmed, quiet: false) }
    }

    func clearSearch() {
        guard results != nil || isSearching || searchError != nil || !query.isEmpty else { return }
        searchTask?.cancel()
        searchTask = nil
        searchToken += 1
        results = nil
        searchError = nil
        isSearching = false
        query = ""
    }

    /// `quiet` keeps the current results on screen while re-running (pull to refresh).
    private func runSearch(_ text: String, quiet: Bool) async {
        guard let feed = browse?.feed, feed.searchLink != nil else { return }
        searchToken += 1
        let token = searchToken
        query = text
        if !quiet {
            isSearching = true
            searchError = nil
        }
        let began = ContinuousClock.now
        do {
            let found = try await connection.client.search(feed, query: text)
            guard token == searchToken else { return }
            results = Listing(token: nextToken(), feed: found, url: nil)
            searchError = nil
            isSearching = false
            log.info("search \"\(text, privacy: .private)\": \(found.entries.count) entries in \(began.duration(to: .now).formatted())")
        } catch is CancellationError {
            guard token == searchToken else { return }
            isSearching = false
        } catch {
            guard token == searchToken else { return }
            isSearching = false
            if quiet {
                refreshError = error.catalogMessage
            } else {
                results = nil
                searchError = error.catalogMessage
            }
            log.error("search failed: \(String(describing: error))")
        }
    }
}
