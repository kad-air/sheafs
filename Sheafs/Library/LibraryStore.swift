import Foundation
import SwiftData
import SheafsKit
import os
import WidgetKit

/// Owns the model container and the on-disk library (EPUB files and cover thumbnails).
@Observable
final class LibraryStore {
    let container: ModelContainer
    let booksDirectory: URL
    let coversDirectory: URL
    /// Set when an import fails, for the UI to surface.
    var lastImportError: String?
    /// Imports in flight, keyed by source URL (for progress UI in catalogs).
    var importing: Set<URL> = []

    private let log = Logger(subsystem: "io.sheafs.reader", category: "library")
    /// What the widget was last handed, so a page turn that doesn't change it reloads nothing.
    private var publishedRecent: RecentBook?
    private var hasPublished = false

    init(inMemory: Bool = false) {
        let schema = Schema([Book.self, Catalog.self, Annotation.self, Bookmark.self, Sketch.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create the model container: \(error)")
        }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        booksDirectory = support.appending(path: "Books", directoryHint: .isDirectory)
        coversDirectory = support.appending(path: "Covers", directoryHint: .isDirectory)
        for dir in [booksDirectory, coversDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var context: ModelContext { container.mainContext }

    func fileURL(for book: Book) -> URL {
        booksDirectory.appending(path: "\(book.id.uuidString).epub")
    }

    func coverURL(for book: Book) -> URL {
        coversDirectory.appending(path: "\(book.id.uuidString).jpg")
    }

    // MARK: Import

    /// Imports a file handed to the app from outside (Files, Share sheet, AirDrop).
    func importFromOutside(_ url: URL) async {
        do {
            _ = try await importBook(from: url)
        } catch {
            log.error("import failed for \(url.lastPathComponent, privacy: .public): \(error)")
            lastImportError = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Copies an EPUB into the library, reads its metadata and cover, computes the sync key,
    /// and returns the new (or already-present) book.
    @discardableResult
    func importBook(from sourceURL: URL, sourceLink: URL? = nil, catalogName: String? = nil) async throws -> Book {
        importing.insert(sourceURL)
        defer { importing.remove(sourceURL) }

        let id = UUID()
        let destination = booksDirectory.appending(path: "\(id.uuidString).epub")
        let staged = try await Task.detached(priority: .userInitiated) {
            try LibraryStore.stage(sourceURL, to: destination)
        }.value

        // Same bytes already in the library? Keep the existing book.
        let key: String? = staged.partialMD5
        let fetch = FetchDescriptor<Book>(predicate: #Predicate { $0.partialMD5 == key })
        if let existing = try context.fetch(fetch).first {
            try? FileManager.default.removeItem(at: destination)
            log.info("import: already in library as \(existing.title, privacy: .public)")
            return existing
        }

        let book = Book(id: id, title: staged.title, author: staged.author, language: staged.language,
                        fileSize: staged.fileSize, partialMD5: staged.partialMD5, hasCover: false,
                        sourceURL: sourceLink?.absoluteString, catalogName: catalogName)
        if let cover = staged.coverJPEG {
            try? cover.write(to: coverURL(for: book), options: .atomic)
            book.hasCover = true
        }
        context.insert(book)
        try context.save()
        publishRecentBook()
        log.info("imported \(book.title, privacy: .public) (\(staged.fileSize) bytes, key \(staged.partialMD5, privacy: .public))")
        return book
    }

    struct Staged: Sendable {
        var title: String
        var author: String?
        var language: String?
        var fileSize: Int
        var partialMD5: String
        var coverJPEG: Data?
    }

    /// Everything that doesn't need the main actor: copy, parse, hash, thumbnail.
    nonisolated static func stage(_ sourceURL: URL, to destination: URL) throws -> Staged {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { readURL in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }

        let epub = try EPUBBook(url: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let key = try PartialMD5.digest(fileAt: destination)
        var cover: Data?
        if let data = try? epub.coverImageData() {
            cover = ImageUtilities.jpegThumbnail(from: data, maxPixelSize: 800)
        }
        let title = epub.metadata.title.isEmpty ? destination.deletingPathExtension().lastPathComponent : epub.metadata.title
        let author = epub.metadata.authors.isEmpty ? nil : epub.metadata.authors.joined(separator: ", ")
        return Staged(title: title, author: author, language: epub.metadata.language, fileSize: size,
                      partialMD5: key, coverJPEG: cover)
    }

    // MARK: Catalog copies

    /// Records which catalog entry `book` came from (its id and `updated`, and the link), so the
    /// catalog finds the book again after the server renames the file and can offer Update when
    /// the server's file changes. Only fills in what a book downloaded from elsewhere lacks: a
    /// book already tied to an entry keeps that entry.
    func remember(_ entry: OPDSEntry, link: URL, catalogName: String?, on book: Book) {
        let tiedElsewhere = book.sourceEntryID != nil && book.sourceEntryID != entry.id
        if !tiedElsewhere, book.sourceURL == nil || entry.matches(book.catalogCopy) {
            book.sourceURL = link.absoluteString
            book.catalogName = catalogName ?? book.catalogName
            book.sourceEntryID = entry.id
            book.sourceUpdated = entry.updated
        }
        save()
    }

    nonisolated enum ReplaceError: LocalizedError {
        /// The new file's bytes are another book's.
        case alreadyInLibrary(title: String)

        var errorDescription: String? {
            switch self {
            case .alreadyInLibrary(let title): "That file is already in your library as “\(title)”."
            }
        }
    }

    nonisolated enum ReplaceOutcome: Equatable, Sendable {
        /// The bytes were the same as the copy's; only the record of the entry was refreshed.
        case unchanged
        /// The file, sync key, title, author and cover are the new file's.
        case replaced
    }

    /// Swaps `book`'s file for the one at `url` (the catalog's newer copy) IN PLACE: same book,
    /// same id, so the reading position (`spineIndex` + `textOffset` + `xpointer`), highlights,
    /// notes and bookmarks all stay. The title, author, language, size, cover and the sync key
    /// (partial MD5) become the new file's.
    ///
    /// 🔴 The sync key changes with the bytes. A server that knows the file was edited (one that
    /// keeps the old key as an alias of the new) hands back the same position under either key;
    /// any other just has nothing under the new key yet, and the next saved position is pushed
    /// there. Positions are exact when the chapters are unchanged (a new cover or title); a
    /// revised text may land a highlight near, not on, its words.
    func replaceFile(of book: Book, with url: URL) async throws -> ReplaceOutcome {
        let incoming = booksDirectory.appending(path: "\(book.id.uuidString).incoming.epub")
        defer { try? FileManager.default.removeItem(at: incoming) }
        let staged = try await Task.detached(priority: .userInitiated) {
            try LibraryStore.stage(url, to: incoming)
        }.value
        if staged.partialMD5 == book.partialMD5 {
            log.info("update: \(book.title, privacy: .public) is unchanged")
            return .unchanged
        }
        let key: String? = staged.partialMD5
        let ownID = book.id
        let fetch = FetchDescriptor<Book>(predicate: #Predicate { $0.partialMD5 == key && $0.id != ownID })
        if let other = try context.fetch(fetch).first {
            throw ReplaceError.alreadyInLibrary(title: other.title)
        }

        let file = fileURL(for: book)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: incoming)
        } else {
            try FileManager.default.moveItem(at: incoming, to: file)
        }
        let previousKey = book.partialMD5
        book.partialMD5 = staged.partialMD5
        book.title = staged.title
        book.author = staged.author
        book.language = staged.language
        book.fileSize = staged.fileSize
        let cover = coverURL(for: book)
        if let jpeg = staged.coverJPEG {
            try? jpeg.write(to: cover, options: .atomic)
            book.hasCover = true
        } else {
            try? FileManager.default.removeItem(at: cover)
            book.hasCover = false
        }
        CoverCache.shared.forget(cover)
        try context.save()
        // The widget may show this book: its cover and title changed even if its progress didn't.
        hasPublished = false
        publishRecentBook()
        log.info("update: \(book.title, privacy: .public) key \(previousKey ?? "-", privacy: .public) → \(staged.partialMD5, privacy: .public)")
        return .replaced
    }

    /// Imports any EPUBs dropped into the app's Documents folder (Files app, Finder, iTunes file
    /// sharing), then removes the originals so they aren't imported twice.
    func importFromDocuments() async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) else { return }
        for url in items where url.pathExtension.lowercased() == "epub" {
            do {
                _ = try await importBook(from: url)
                try? FileManager.default.removeItem(at: url)
            } catch {
                log.error("documents import failed for \(url.lastPathComponent, privacy: .public): \(error)")
                lastImportError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Delete

    func delete(_ book: Book) {
        try? FileManager.default.removeItem(at: fileURL(for: book))
        try? FileManager.default.removeItem(at: coverURL(for: book))
        for annotation in annotations(for: book) { context.delete(annotation) }
        for bookmark in bookmarks(for: book) { context.delete(bookmark) }
        for sketch in sketches(for: book) { context.delete(sketch) }
        RecapStore.delete(bookID: book.id)
        AskHistoryStore.delete(bookID: book.id)
        context.delete(book)
        try? context.save()
        publishRecentBook()
    }

    // MARK: Widget

    /// The book the widget shows: the most recently read, else the most recently added (the
    /// library's own order).
    func mostRecentBook() -> Book? {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        return books.max { ($0.lastOpenedAt ?? $0.addedAt) < ($1.lastOpenedAt ?? $1.addedAt) }
    }

    /// Hands the most recent book to the "Continue Reading" widget and control through the app
    /// group, and reloads them only when what they show changed (progress is rounded to whole
    /// percents).
    func publishRecentBook() {
        guard let shelf = RecentBookShelf.shared else {
            log.error("widget: app group \(RecentBookShelf.appGroup, privacy: .public) unavailable")
            return
        }
        let book = mostRecentBook()
        let recent = book.map {
            RecentBook(id: $0.id, title: $0.title, author: $0.author,
                       progress: ($0.progress * 100).rounded() / 100, hasCover: $0.hasCover)
        }
        if hasPublished, publishedRecent == recent { return }
        let coverChanged = !hasPublished || recent?.id != publishedRecent?.id
        var cover: Data?
        if let book, book.hasCover, coverChanged, let data = try? Data(contentsOf: coverURL(for: book)) {
            // Widgets live under a tight memory limit: a small thumbnail is plenty for the tile.
            cover = ImageUtilities.jpegThumbnail(from: data, maxPixelSize: 480)
        }
        do {
            try shelf.write(recent, cover: cover)
            publishedRecent = recent
            hasPublished = true
            WidgetCenter.shared.reloadTimelines(ofKind: RecentBookShelf.widgetKind)
            ControlCenter.shared.reloadControls(ofKind: RecentBookShelf.controlKind)
            log.info("widget: now \(recent?.title ?? "empty", privacy: .public) \(recent?.progress ?? 0)")
        } catch {
            log.error("widget: write failed: \(error)")
        }
    }

    // MARK: Annotations

    /// The book's highlights and notes in reading order.
    func annotations(for book: Book) -> [Annotation] {
        let id = book.id
        let fetch = FetchDescriptor<Annotation>(predicate: #Predicate { $0.bookID == id },
                                                sortBy: [SortDescriptor(\.spineIndex), SortDescriptor(\.startOffset)])
        return (try? context.fetch(fetch)) ?? []
    }

    func add(_ annotation: Annotation) {
        context.insert(annotation)
        save()
    }

    func delete(_ annotation: Annotation) {
        context.delete(annotation)
        save()
    }

    // MARK: Bookmarks

    /// The book's bookmarks in reading order.
    func bookmarks(for book: Book) -> [Bookmark] {
        let id = book.id
        let fetch = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.bookID == id },
                                              sortBy: [SortDescriptor(\.spineIndex), SortDescriptor(\.textOffset)])
        return (try? context.fetch(fetch)) ?? []
    }

    func add(_ bookmark: Bookmark) {
        context.insert(bookmark)
        save()
    }

    func delete(_ bookmark: Bookmark) {
        context.delete(bookmark)
        save()
    }

    // MARK: Pencil markings

    /// The book's pencil markings in reading order.
    func sketches(for book: Book) -> [Sketch] {
        let id = book.id
        let fetch = FetchDescriptor<Sketch>(predicate: #Predicate { $0.bookID == id },
                                            sortBy: [SortDescriptor(\.spineIndex), SortDescriptor(\.startOffset)])
        return (try? context.fetch(fetch)) ?? []
    }

    func add(_ sketch: Sketch) {
        context.insert(sketch)
        save()
    }

    func delete(_ sketch: Sketch) {
        context.delete(sketch)
        save()
    }

    /// Writes what a markup session saved or removed for `book`.
    func apply(_ edits: [SketchEdit], for book: Book) {
        guard !edits.isEmpty else { return }
        let existing = Dictionary(sketches(for: book).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for edit in edits {
            switch edit {
            case .delete(let id):
                if let sketch = existing[id] { context.delete(sketch) }
            case .save(let save):
                let mark = save.mark
                let drawing = mark.drawing.dataRepresentation()
                let anchors = mark.anchors.encoded()
                if let sketch = existing[mark.id] {
                    sketch.spineIndex = mark.spineIndex
                    sketch.startOffset = save.range.location
                    sketch.endOffset = NSMaxRange(save.range)
                    sketch.startPointer = save.startPointer
                    sketch.endPointer = save.endPointer
                    sketch.text = save.text
                    sketch.drawing = drawing
                    sketch.anchors = anchors
                    if let thumbnail = save.thumbnail { sketch.thumbnail = thumbnail }
                    sketch.modifiedAt = mark.version
                } else {
                    context.insert(Sketch(id: mark.id, bookID: book.id, spineIndex: mark.spineIndex,
                                          startOffset: save.range.location, endOffset: NSMaxRange(save.range),
                                          startPointer: save.startPointer, endPointer: save.endPointer, text: save.text,
                                          drawing: drawing, anchors: anchors, thumbnail: save.thumbnail, modifiedAt: mark.version))
                }
            }
        }
        save()
    }

    func save() {
        do { try context.save() } catch { log.error("save failed: \(error)") }
    }
}
