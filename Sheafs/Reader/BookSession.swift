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
    /// The book's highlights, for the pages to paint (kept here so every spread sees the same list).
    var marks: [HighlightMark] = []
    /// The book's bookmarks, for the pages to draw their ribbons (same arrangement as `marks`).
    var bookmarks: [BookmarkMark] = []

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
                // Parsed once per file and shared by every chapter that links it.
                let stylesheets = StylesheetLibrary(book: epub)
                let spine = epub.spine
                let chapters = await withTaskGroup(of: (Int, Chapter).self, returning: [Chapter].self) { group in
                    for (index, item) in spine.enumerated() {
                        group.addTask {
                            let data = (try? epub.data(for: item.item)) ?? Data()
                            return (index, converter.convert(data, documentPath: item.item.path, stylesheets: stylesheets))
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
            reanchorPosition()
            state = .ready
            log.info("opened \(self.book.title, privacy: .public): \(self.chapters.count) chapters, \(total) chars")
        } catch {
            log.error("open failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    /// The saved offset is only right for the chapter as it converted when it was saved; the
    /// saved pointer names the element itself. When the chapter converts differently now (a
    /// stylesheet hides front matter, so the text after it moved up), follow the pointer.
    private func reanchorPosition() {
        let spine = location.spineIndex
        guard spine < chapters.count,
              let moved = chapters[spine].reanchoredOffset(location.textOffset, pointer: book.xpointer, spineIndex: spine) else { return }
        log.info("reanchored position \(spine):\(self.location.textOffset) → \(moved) by \(self.book.xpointer ?? "", privacy: .public)")
        location = clamp(ReadingLocation(spineIndex: spine, textOffset: moved))
        book.textOffset = location.textOffset
    }

    /// Puts highlights whose stored offsets no longer hold their text where their pointers say,
    /// when the text is there (see `Chapter.reanchoredRange`); others are left as they are.
    /// Returns how many moved.
    @discardableResult
    func reanchor(_ annotations: [Annotation]) -> Int {
        var moved = 0
        for annotation in annotations where annotation.spineIndex >= 0 && annotation.spineIndex < chapters.count {
            let stored = annotation.startOffset ..< max(annotation.startOffset, annotation.endOffset)
            guard let range = chapters[annotation.spineIndex].reanchoredRange(
                stored, text: annotation.text, startPointer: annotation.startPointer, endPointer: annotation.endPointer
            ) else { continue }
            log.info("reanchored highlight \(annotation.id, privacy: .public) \(annotation.spineIndex):\(stored.lowerBound)..<\(stored.upperBound) → \(range.lowerBound)..<\(range.upperBound)")
            annotation.startOffset = range.lowerBound
            annotation.endOffset = range.upperBound
            moved += 1
        }
        return moved
    }

    /// Puts bookmarks where their pointers say when that is another offset in the same chapter
    /// (see `reanchorPosition`). Returns how many moved.
    @discardableResult
    func reanchor(_ bookmarks: [Bookmark]) -> Int {
        var moved = 0
        for bookmark in bookmarks where bookmark.spineIndex >= 0 && bookmark.spineIndex < chapters.count {
            guard let offset = chapters[bookmark.spineIndex].reanchoredOffset(
                bookmark.textOffset, pointer: bookmark.xpointer, spineIndex: bookmark.spineIndex
            ) else { continue }
            log.info("reanchored bookmark \(bookmark.id, privacy: .public) \(bookmark.spineIndex):\(bookmark.textOffset) → \(offset)")
            bookmark.textOffset = offset
            moved += 1
        }
        return moved
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
        guard location.spineIndex >= 0, location.spineIndex < chapters.count else { return nil }
        return chapters[location.spineIndex].pointer(at: location.textOffset, spineIndex: location.spineIndex)
    }

    /// A location for a pointer written by this or another reader; nil when the chapter can't be found.
    func location(for pointer: XPointer) -> ReadingLocation? {
        guard pointer.spineIndex >= 0, pointer.spineIndex < chapters.count else { return nil }
        let offset = chapters[pointer.spineIndex].offset(of: pointer) ?? 0
        return clamp(ReadingLocation(spineIndex: pointer.spineIndex, textOffset: offset))
    }

    // MARK: Typesetting and pagination

    /// Sets the style and page text size; drops caches when either changed.
    func configure(style: TypesetStyle, textSize: CGSize) {
        guard style != self.style || textSize != self.textSize else { return }
        self.style = style
        self.textSize = textSize
        paginated.removeAll()
    }

    /// The paginated chapter for the current style and size, laid out on demand. The first layout
    /// of a chapter after a size or style change forces a page break at `anchor` (the reading
    /// position), so what was at the top of the page stays at the top; a cached layout is reused as is.
    func paginatedChapter(_ spineIndex: Int, anchor: Int? = nil) -> PaginatedChapter? {
        guard isReady, let style, textSize.width > 10, textSize.height > 10,
              spineIndex >= 0, spineIndex < chapters.count else { return nil }
        if let cached = paginated[spineIndex] { return cached }
        let chapter = chapters[spineIndex]
        let chapterImages = loadImages(for: spineIndex)
        let attributed = Typesetter.attributedString(for: chapter, style: style, images: chapterImages, pageSize: textSize)
        let result = PaginatedChapter(spineIndex: spineIndex, attributedString: attributed, pageSize: textSize, anchor: anchor)
        paginated[spineIndex] = result
        return result
    }

    /// Where to jump so that `offset` of chapter `spineIndex` is on the page shown (the right page
    /// of a spread): the start of the page that holds it. A chapter not laid out yet is laid out
    /// anchored at the start of the paragraph holding the offset (what jumping to that paragraph
    /// would do), so its pages break at a paragraph and not mid-line at the offset. For actions
    /// (a search result tapped), never from view code: see `laidOutChapter`.
    func pageStart(showing offset: Int, inSpine spineIndex: Int) -> ReadingLocation {
        let fallback = clamp(ReadingLocation(spineIndex: spineIndex, textOffset: offset))
        guard spineIndex >= 0, spineIndex < chapters.count else { return fallback }
        let paragraph = chapters[spineIndex].block(containing: offset)?.textOffset ?? offset
        guard let chapter = paginated[spineIndex] ?? paginatedChapter(spineIndex, anchor: paragraph) else { return fallback }
        let page = chapter.range(ofPage: chapter.pageIndex(containing: offset))
        return clamp(ReadingLocation(spineIndex: spineIndex, textOffset: page.location))
    }

    /// The chapter's layout if it is already cached; never lays one out. For callers that run while
    /// a view is drawn: an unanchored layout there would re-cut the pages around the position.
    func laidOutChapter(_ spineIndex: Int) -> PaginatedChapter? { paginated[spineIndex] }

    /// Book-wide page numbers like Books shows them: exact for chapters already laid out at this
    /// size, estimated from their text length for the rest (so the total settles as you read).
    func bookPages(spineIndex: Int, page: Int) -> (page: Int, total: Int) {
        guard !chapters.isEmpty else { return (1, 1) }
        var laidOutChars = 0, laidOutPages = 0
        for (index, chapter) in paginated {
            laidOutChars += chapters[index].textLength
            laidOutPages += chapter.pageCount
        }
        let perPage = laidOutPages > 0 ? max(200, Double(laidOutChars) / Double(laidOutPages)) : 1500
        func count(_ index: Int) -> Int {
            paginated[index]?.pageCount ?? max(1, Int((Double(chapters[index].textLength) / perPage).rounded(.up)))
        }
        var before = 0
        for index in 0 ..< min(spineIndex, chapters.count) { before += count(index) }
        var total = 0
        for index in chapters.indices { total += count(index) }
        return (before + page + 1, max(total, before + page + 1))
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

    // MARK: Pictures

    /// The image block whose attachment is at `textOffset` of chapter `spineIndex`.
    func imageBlock(spineIndex: Int, textOffset: Int) -> (source: String, alt: String?)? {
        guard spineIndex >= 0, spineIndex < chapters.count,
              let block = chapters[spineIndex].block(containing: textOffset),
              case .image(let source, let alt) = block.kind else { return nil }
        return (source, alt)
    }

    /// Every picture in the book, in reading order (for `-SheafsOpenImage`).
    func imageLocations() -> [ReadingLocation] {
        chapters.enumerated().flatMap { spine, chapter in
            chapter.blocks.compactMap { block -> ReadingLocation? in
                guard case .image = block.kind, block.textLength == 1 else { return nil }
                return ReadingLocation(spineIndex: spine, textOffset: block.textOffset)
            }
        }
    }

    /// The picture `source` of chapter `spineIndex` at its own resolution, for the full-screen viewer
    /// (the page's attachment is downsampled to the page). Decoded off the main actor; a huge one is
    /// held to 4096 px on its long side.
    func fullImage(source: String, spineIndex: Int) async -> UIImage? {
        guard let epub, spineIndex >= 0, spineIndex < epub.spine.count else { return nil }
        let path = EPUBPath.resolve(EPUBPath.split(source).path, relativeTo: epub.spine[spineIndex].item.path)
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? epub.data(at: path) else { return nil }
            return ImageViewerLayout.decode(data, maxPixelSize: 4096)
        }.value
    }
}
