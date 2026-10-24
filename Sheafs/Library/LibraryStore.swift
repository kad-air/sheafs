import Foundation
import SwiftData
import SheafsKit
import os

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

    init(inMemory: Bool = false) {
        let schema = Schema([Book.self, Catalog.self, Annotation.self])
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
        context.delete(book)
        try? context.save()
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

    func save() {
        do { try context.save() } catch { log.error("save failed: \(error)") }
    }
}
