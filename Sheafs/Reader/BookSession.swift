import Foundation
import SwiftUI
import UIKit
import SheafsKit
import os

/// A position in a book: a chapter (spine index) and a UTF-16 offset into its plain text.
struct ReadingLocation: Hashable, Sendable {
    var spineIndex: Int
    var textOffset: Int
    static let start = ReadingLocation(spineIndex: 0, textOffset: 0)
}

/// One open book: the parsed EPUB, its converted chapters, and the typeset/paginated caches for
/// the current style and page size. Main-actor; the heavy parsing happens in a detached task.
@Observable
final class BookSession {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let book: Book
    let fileURL: URL
    private(set) var state: State = .loading
    private(set) var epub: EPUBBook?
    private(set) var chapters: [Chapter] = []
    private(set) var toc: [TOCEntry] = []
    private(set) var flatTOC: [TOCEntry] = []
    /// Cumulative plain-text offsets of each chapter's start; `chapterStarts[count] == totalLength`.
    private(set) var chapterStarts: [Int] = []
    private(set) var totalLength: Int = 0
    var location: ReadingLocation

    private(set) var style: TypesetStyle?
    private(set) var textSize: CGSize = .zero
    private var paginated: [Int: PaginatedChapter] = [:]
    private var images: [Int: ChapterImages] = [:]
    private let log = Logger(subsystem: "io.sheafs.reader", category: "session")

    init(book: Book, fileURL: URL) {
        self.book = book
        self.fileURL = fileURL
        self.location = ReadingLocation(spineIndex: book.spineIndex, textOffset: book.textOffset)
    }

    var isReady: Bool { state == .ready }

    // MARK: Loading

    struct Loaded: Sendable {
        var epub: EPUBBook
        var chapters: [Chapter]
    }

    func load() async {
        let url = fileURL
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> Loaded in
                let epub = try EPUBBook(url: url)
                let converter = XHTMLConverter()
                let spine = epub.spine
                let chapters = await withTaskGroup(of: (Int, Chapter).self, returning: [Chapter].self) { group in
                    for (index, item) in spine.enumerated() {
                        group.addTask {
                            let data = (try? epub.data(for: item.item)) ?? Data()
                            return (index, converter.convert(data))
                        }
                    }
                    var result = Array(repeating: Chapter(blocks: [], textLength: 0, anchorOffsets: [:]), count: spine.count)
                    for await (index, chapter) in group { result[index] = chapter }
                    return result
                }
                return Loaded(epub: epub, chapters: chapters)
            }.value
            epub = loaded.epub
            chapters = loaded.chapters
            toc = loaded.epub.toc
            flatTOC = loaded.epub.flattenedTOC
            var starts: [Int] = []
            var total = 0
            for chapter in chapters {
                starts.append(total)
                total += chapter.textLength
            }
            starts.append(total)
            chapterStarts = starts
            totalLength = total
            location = clamp(location)
            state = .ready
            log.info("opened \(self.book.title, privacy: .public): \(self.chapters.count) chapters, \(total) chars")
        } catch {
            log.error("open failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    func clamp(_ loc: ReadingLocation) -> ReadingLocation {
        guard !chapters.isEmpty else { return .start }
        let spine = max(0, min(loc.spineIndex, chapters.count - 1))
        let offset = max(0, min(loc.textOffset, max(0, chapters[spine].textLength - 1)))
        return ReadingLocation(spineIndex: spine, textOffset: offset)
    }

    // MARK: Positions

    /// Fraction of the whole book's text that comes before `location`.
    func progress(for location: ReadingLocation) -> Double {
        guard totalLength > 0, location.spineIndex < chapterStarts.count - 1 else { return 0 }
        let absolute = chapterStarts[location.spineIndex] + location.textOffset
        return min(1, max(0, Double(absolute) / Double(totalLength)))
    }

    func location(forProgress fraction: Double) -> ReadingLocation {
        guard totalLength > 0 else { return .start }
        let absolute = Int(Double(totalLength) * min(1, max(0, fraction)))
        var spine = 0
        while spine + 1 < chapterStarts.count - 1, chapterStarts[spine + 1] <= absolute { spine += 1 }
        return clamp(ReadingLocation(spineIndex: spine, textOffset: absolute - chapterStarts[spine]))
    }

    /// The table-of-contents title that names a chapter: its own first entry when it has one,
    /// otherwise the entry of the nearest preceding chapter (a section spanning several files).
    func chapterTitle(for spineIndex: Int) -> String? {
        guard let epub, spineIndex < epub.spine.count else { return nil }
        var preceding: TOCEntry?
        for entry in flatTOC {
            guard let path = entry.path, let index = epub.spineIndex(forPath: path) else { continue }
            if index == spineIndex { return entry.title }
            if index < spineIndex { preceding = entry } else { break }
        }
        return preceding?.title ?? chapters[spineIndex].title
    }

    func location(for entry: TOCEntry) -> ReadingLocation? {
        guard let epub, let path = entry.path, let spine = epub.spineIndex(forPath: path) else { return nil }
        let offset = entry.fragment.flatMap { chapters[spine].anchorOffsets[$0] } ?? 0
        return clamp(ReadingLocation(spineIndex: spine, textOffset: offset))
    }

    /// Resolves an in-book link (as written in a chapter) to a location.
    func location(forHref href: String, fromSpine spine: Int) -> ReadingLocation? {
        guard let epub, spine < epub.spine.count else { return nil }
        let (rawPath, fragment) = EPUBPath.split(href)
        let targetSpine: Int
        if rawPath.isEmpty {
            targetSpine = spine
        } else {
            let resolved = EPUBPath.resolve(rawPath, relativeTo: epub.spine[spine].item.path)
            guard let index = epub.spineIndex(forPath: resolved) else { return nil }
            targetSpine = index
        }
        let offset = fragment.flatMap { chapters[targetSpine].anchorOffsets[$0] } ?? 0
        return clamp(ReadingLocation(spineIndex: targetSpine, textOffset: offset))
    }

    /// The CREngine pointer for a location, for the sync server.
    func xpointer(for location: ReadingLocation) -> XPointer? {
        guard location.spineIndex < chapters.count else { return nil }
        let chapter = chapters[location.spineIndex]
        guard let block = chapter.block(containing: location.textOffset) else {
            return XPointer(spineIndex: location.spineIndex, elementPath: "/body")
        }
        let offset = max(0, min(location.textOffset - block.textOffset, block.textLength))
        return XPointer(spineIndex: location.spineIndex, elementPath: block.elementPath, textNodeIndex: 1, characterOffset: offset)
    }

    /// A location for a pointer written by this or another reader; nil when the chapter can't be found.
    func location(for pointer: XPointer) -> ReadingLocation? {
        guard pointer.spineIndex >= 0, pointer.spineIndex < chapters.count else { return nil }
        let chapter = chapters[pointer.spineIndex]
        guard let block = chapter.block(atElementPath: pointer.elementPath) ?? chapter.block(nearestElementPath: pointer.elementPath) else {
            return ReadingLocation(spineIndex: pointer.spineIndex, textOffset: 0)
        }
        let within = min(pointer.characterOffset ?? 0, block.textLength)
        return clamp(ReadingLocation(spineIndex: pointer.spineIndex, textOffset: block.textOffset + within))
    }

    // MARK: Typesetting and pagination

    /// Sets the style and page text size; drops caches when either changed.
    func configure(style: TypesetStyle, textSize: CGSize) {
        guard style != self.style || textSize != self.textSize else { return }
        self.style = style
        self.textSize = textSize
        paginated.removeAll()
    }

    /// The paginated chapter for the current style and size, laid out on demand.
    func paginatedChapter(_ spineIndex: Int) -> PaginatedChapter? {
        guard isReady, let style, textSize.width > 10, textSize.height > 10,
              spineIndex >= 0, spineIndex < chapters.count else { return nil }
        if let cached = paginated[spineIndex] { return cached }
        let chapter = chapters[spineIndex]
        let chapterImages = loadImages(for: spineIndex)
        let attributed = Typesetter.attributedString(for: chapter, style: style, images: chapterImages, pageSize: textSize)
        let result = PaginatedChapter(spineIndex: spineIndex, attributedString: attributed, pageSize: textSize)
        paginated[spineIndex] = result
        return result
    }

    /// Lays out the neighbours of `spineIndex` soon, so page turns don't wait.
    func prefetch(around spineIndex: Int) {
        for index in [spineIndex + 1, spineIndex - 1] where index >= 0 && index < chapters.count && paginated[index] == nil {
            Task { @MainActor [weak self] in
                _ = self?.paginatedChapter(index)
            }
        }
    }

    private func loadImages(for spineIndex: Int) -> ChapterImages {
        if let cached = images[spineIndex] { return cached }
        var result = ChapterImages()
        guard let epub, spineIndex < epub.spine.count else { return result }
        let basePath = epub.spine[spineIndex].item.path
        let scale = UITraitCollection.current.displayScale
        for block in chapters[spineIndex].blocks {
            guard case .image(let source, _) = block.kind, result.images[source] == nil else { continue }
            let path = EPUBPath.resolve(EPUBPath.split(source).path, relativeTo: basePath)
            guard let data = try? epub.data(at: path) else { continue }
            let maxPixels = max(textSize.width, textSize.height) * scale
            if let image = ImageUtilities.downsampled(data, maxPixelSize: max(400, maxPixels)) {
                // Points, not pixels: the attachment is sized in points.
                let pointImage = UIImage(cgImage: image.cgImage!, scale: scale, orientation: .up)
                result.images[source] = pointImage
            }
        }
        images[spineIndex] = result
        return result
    }

    var chapterCount: Int { chapters.count }
}
