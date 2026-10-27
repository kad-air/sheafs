import SwiftUI
import SheafsKit
import os

/// Find-in-book for one open book: folds the chapters once (`BookSearchIndex`, off the main
/// actor, when the sheet first opens), then searches as the user types, debounced, each search
/// off the main actor and cancelled by the next. Lives as long as the reader, so reopening the
/// sheet shows the last query and its results.
@Observable
final class BookSearchModel {
    let session: BookSession
    var query = ""
    private(set) var sections: [SearchSection] = []
    /// The query the sections answer (nil before the first search finishes).
    private(set) var searchedQuery: String?
    private(set) var totalCount = 0
    private(set) var isSearching = false

    /// At most this many results are listed (every one is counted).
    static let limit = 500

    @ObservationIgnored private var index: BookSearchIndex?
    @ObservationIgnored private var indexTask: Task<BookSearchIndex, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Found?, Never>?
    private let log = Logger(subsystem: "io.sheafs.reader", category: "search")

    init(session: BookSession) {
        self.session = session
    }

    /// Starts folding the book's text, once.
    func prepare() {
        guard indexTask == nil, session.isReady else { return }
        let chapters = session.chapters
        let log = log
        indexTask = Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            let index = BookSearchIndex(chapters: chapters)
            log.info("index: \(chapters.count) chapters in \(ContinuousClock.now - started)")
            return index
        }
    }

    /// Searches for `query` after a short pause (`immediately` for the keyboard's Search key).
    func search(immediately: Bool = false) {
        pending?.cancel()
        running?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sections = []
            searchedQuery = nil
            totalCount = 0
            isSearching = false
            return
        }
        prepare()
        isSearching = true
        pending = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let self, let indexTask = self.indexTask else { return }
            let index = await indexTask.value
            self.index = index
            guard !Task.isCancelled else { return }
            let limit = Self.limit
            let started = ContinuousClock.now
            let work = Task.detached(priority: .userInitiated) { () -> Found? in
                guard let result = index.search(text, limit: limit, isCancelled: { Task.isCancelled }) else { return nil }
                var snippets: [SearchHit: SearchSnippet] = [:]
                for hit in result.hits {
                    if Task.isCancelled { return nil }
                    snippets[hit] = index.snippet(for: hit)
                }
                return Found(result: result, snippets: snippets)
            }
            self.running = work
            let found = await work.value
            guard !Task.isCancelled else { return }
            self.isSearching = false
            guard let found else {
                self.sections = []
                self.searchedQuery = text
                self.totalCount = 0
                return
            }
            self.apply(found)
            let elapsed = ContinuousClock.now - started
            self.log.info("\"\(text, privacy: .private)\": \(found.result.totalCount) hits in \(found.result.countsBySpine.count) chapters, \(elapsed)")
            print("[search] \"\(text)\": \(found.result.totalCount) hits in \(found.result.countsBySpine.count) chapters (\(found.result.hits.count) listed) in \(elapsed)")
        }
    }

    private func apply(_ found: Found) {
        var sections: [SearchSection] = []
        for hit in found.result.hits {
            let row = SearchRow(hit: hit, snippet: found.snippets[hit] ?? SearchSnippet(before: "", match: "", after: "",
                                                                                         isCutBefore: false, isCutAfter: false))
            if sections.last?.spineIndex == hit.spineIndex {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append(SearchSection(spineIndex: hit.spineIndex,
                                              title: session.chapterTitle(for: hit.spineIndex) ?? "Section \(hit.spineIndex + 1)",
                                              count: found.result.countsBySpine[hit.spineIndex] ?? 0, rows: [row]))
            }
        }
        self.sections = sections
        searchedQuery = found.result.query
        totalCount = found.result.totalCount
    }

    /// Every hit of the searched query in one chapter, for the pages to paint.
    func hits(inSpine spine: Int) -> [SearchHit] {
        guard let index, let searchedQuery else { return [] }
        return index.hits(of: searchedQuery, inSpine: spine)
    }

    var listedCount: Int { sections.reduce(0) { $0 + $1.rows.count } }

    nonisolated struct Found: Sendable {
        var result: BookSearchResult
        var snippets: [SearchHit: SearchSnippet]
    }
}

struct SearchSection: Identifiable {
    var spineIndex: Int
    var title: String
    /// Every hit in the chapter, including any past the listing limit.
    var count: Int
    var rows: [SearchRow]
    var id: Int { spineIndex }
}

struct SearchRow: Identifiable {
    var hit: SearchHit
    var snippet: SearchSnippet
    var id: SearchHit { hit }

    /// The snippet with the match in the primary colour and bold, the context secondary.
    var attributed: AttributedString {
        var before = AttributedString((snippet.isCutBefore ? "…" : "") + snippet.before)
        var match = AttributedString(snippet.match)
        var after = AttributedString(snippet.after + (snippet.isCutAfter ? "…" : ""))
        before.foregroundColor = .secondary
        after.foregroundColor = .secondary
        match.foregroundColor = .primary
        match.inlinePresentationIntent = .stronglyEmphasized
        return before + match + after
    }
}

/// The search sheet: a search field over the results, grouped by chapter with a snippet each.
struct BookSearchView: View {
    @Bindable var model: BookSearchModel
    var onSelect: (SearchHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search in Book")
                .searchFocused($fieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(of: .search) { model.search(immediately: true) }
                .onChange(of: model.query) { model.search() }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear {
                    model.prepare()
                    if model.query.isEmpty { fieldFocused = true }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let typed = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !typed {
            ContentUnavailableView("Search This Book", systemImage: "magnifyingglass",
                                   description: Text("Find a word or phrase in every chapter."))
        } else if model.sections.isEmpty, model.isSearching || model.searchedQuery == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sections.isEmpty {
            ContentUnavailableView.search(text: model.searchedQuery ?? model.query)
        } else {
            List {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            Button {
                                onSelect(row.hit)
                            } label: {
                                Text(row.attributed)
                                    .font(.subheadline)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title)
                                .lineLimit(1)
                            Spacer()
                            Text("\(section.count)")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .opacity(model.isSearching ? 0.6 : 1)
        }
    }

    private var summary: String {
        let total = model.totalCount
        let noun = total == 1 ? "result" : "results"
        let chapters = model.sections.count == 1 ? "1 chapter" : "\(model.sections.count) chapters"
        if model.listedCount < total {
            return "\(total.formatted()) \(noun), the first \(model.listedCount.formatted()) shown"
        }
        return "\(total.formatted()) \(noun) in \(chapters)"
    }
}
