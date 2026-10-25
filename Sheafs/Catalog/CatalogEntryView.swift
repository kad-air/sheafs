import SwiftUI
import SwiftData
import SheafsKit
import os

/// Downloads one entry's EPUB and imports it into the library.
@Observable
final class EntryDownloadModel {
    enum State {
        case idle
        /// `nil` until the server states a length, so the bar stays indeterminate until then.
        case downloading(fraction: Double?)
        case imported(Book)
    }

    private(set) var state: State = .idle
    var errorMessage: String?
    /// Whether the entry screen is still on screen. A download outlives it, so a failure after
    /// the person went back is reported through the library's alert instead.
    var isVisible = true

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.sheafs.reader", category: "catalog")

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func start(link: OPDSLink, connection: CatalogConnection, library: LibraryStore) {
        guard !isDownloading else { return }
        state = .downloading(fraction: nil)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        let client = connection.client
        let catalogName = connection.name
        task = Task {
            defer { try? FileManager.default.removeItem(at: temporary) }
            let began = ContinuousClock.now
            do {
                let contentType = try await client.download(link.href, to: temporary) { fraction in
                    Task { @MainActor in self.report(fraction) }
                }
                // A login or error page served as a 200 is not worth importing.
                if let contentType, contentType.localizedCaseInsensitiveContains("html") {
                    throw OPDSError.notEPUB(contentType: contentType)
                }
                let book = try await library.importBook(from: temporary, sourceLink: link.href,
                                                        catalogName: catalogName)
                // The same bytes may already be in the library from elsewhere; remember where this
                // link leads so the catalog can mark the book.
                if book.sourceURL == nil {
                    book.sourceURL = link.href.absoluteString
                    book.catalogName = catalogName
                    library.save()
                }
                state = .imported(book)
                log.info("downloaded and imported in \(began.duration(to: .now).formatted())")
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .idle
                let message = error.catalogMessage
                log.error("download failed after \(began.duration(to: .now).formatted()): \(String(describing: error))")
                if isVisible {
                    errorMessage = message
                } else {
                    library.lastImportError = message
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func report(_ fraction: Double) {
        guard case .downloading(let current) = state else { return }
        state = .downloading(fraction: max(current ?? 0, fraction))
    }
}

/// One book: cover, details, and Download / Read.
struct CatalogEntryView: View {
    let entry: OPDSEntry
    let connection: CatalogConnection
    @Environment(LibraryStore.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Query private var existing: [Book]
    @State private var download = EntryDownloadModel()

    init(entry: OPDSEntry, connection: CatalogConnection) {
        self.entry = entry
        self.connection = connection
        let href = entry.epubLink?.href.absoluteString ?? ""
        _existing = Query(filter: #Predicate<Book> { $0.sourceURL == href })
    }

    /// The imported book, else one already in the library from this same link.
    private var book: Book? {
        if case .imported(let imported) = download.state, !imported.isDeleted, imported.modelContext != nil {
            return imported
        }
        return existing.first
    }

    private var justImported: Bool {
        if case .imported(let imported) = download.state { return imported === book }
        return false
    }

    var body: some View {
        GeometryReader { proxy in
            let division = proxy.divisions().first?.frame
            if let division, division.height > division.width {
                // A vertical fold: cover on one page, text on the other, nothing on the crease.
                HStack(spacing: 0) {
                    ScrollView { header.padding(24) }
                        .frame(width: max(division.minX - proxy.safeAreaInsets.leading, 0))
                    Spacer(minLength: division.width)
                    ScrollView { details.padding(24) }
                        .frame(width: max(proxy.size.width - division.maxX - proxy.safeAreaInsets.trailing, 0))
                }
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        details
                    }
                    .padding(20)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { download.isVisible = true }
        .onDisappear { download.isVisible = false }
        .alert("Download Failed", item: $download.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 16) {
            CatalogCoverView(title: entry.title, author: entry.authors.first,
                             url: entry.links.first(where: \.isImage)?.href ?? entry.thumbnailURL,
                             connection: connection)
                .frame(maxWidth: 240)
            VStack(spacing: 6) {
                Text(entry.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if !entry.authors.isEmpty {
                    Text(entry.authors.joined(separator: ", "))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !entry.categories.isEmpty {
                    Text(entry.categories.prefix(12).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 24) {
            action
            if let summary = entry.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Summary")
                        .font(.headline)
                    Text(summary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var action: some View {
        if case .downloading(let fraction) = download.state {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction)
                HStack {
                    Text(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Downloading…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel", systemImage: "xmark.circle", role: .cancel) { download.cancel() }
                        .font(.footnote)
                }
            }
        } else if let book {
            Button {
                navigation.open(book)
            } label: {
                Label(justImported ? "Read Now" : "In Library · Read", systemImage: "book")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else if let link = entry.epubLink {
            Button {
                download.start(link: link, connection: connection, library: library)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            unavailable
        }
    }

    /// No EPUB: say what the catalog does offer, since Sheafs only reads EPUB.
    private var unavailable: some View {
        let formats = Self.formatNames(of: entry.acquisitionLinks)
        return VStack(alignment: .leading, spacing: 6) {
            Label("No EPUB Available", systemImage: "book.closed")
                .font(.headline)
            if formats.isEmpty {
                Text("This catalog doesn’t offer a download for this book.")
                    .foregroundStyle(.secondary)
            } else {
                Text("This catalog offers it as \(formats.formatted(.list(type: .and))). Sheafs reads EPUB only.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Distinct, readable names for the formats of `links`, in the order offered.
    nonisolated static func formatNames(of links: [OPDSLink]) -> [String] {
        var names: [String] = []
        for link in links {
            guard let name = formatName(for: link.mediaType), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    nonisolated private static func formatName(for mediaType: String?) -> String? {
        guard let mediaType else { return nil }
        switch mediaType {
        case "application/pdf": return "PDF"
        case "application/x-mobipocket-ebook", "application/vnd.amazon.mobi8-ebook", "application/x-mobi8-ebook":
            return "MOBI"
        case "application/vnd.amazon.ebook", "application/x-azw3": return "AZW3"
        case "application/x-cbz", "application/vnd.comicbook+zip": return "CBZ"
        case "application/x-cbr", "application/vnd.comicbook-rar": return "CBR"
        case "application/fb2+zip", "application/x-fictionbook+xml", "application/x-fb2": return "FB2"
        case "text/plain": return "TXT"
        case "text/html", "application/xhtml+xml": return "HTML"
        case "application/epub+zip": return "EPUB"
        default:
            // "application/x-foo+zip" -> "FOO"
            let subtype = mediaType.split(separator: "/").last.map(String.init) ?? mediaType
            let core = subtype.split(whereSeparator: { "+-.".contains($0) }).filter { $0 != "x" && $0 != "vnd" }.first
            return core.map { String($0).uppercased() }
        }
    }
}
