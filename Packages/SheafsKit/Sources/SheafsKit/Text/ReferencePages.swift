import Foundation

/// Page numbers that belong to the BOOK, not to the screen: the same for a position whatever the
/// display, the pose, the font or the text size, and known as soon as the chapters are converted.
/// The reader's screen pages are cut by TextKit and anchored at the reading position, so they change
/// with every fold or font change; the folio and "N of M" show these instead.
///
/// - From the book's page list when it has a usable one (the print edition's page markers): each
///   marker's target resolved to a chapter and a UTF-16 offset of its converted text (the offsets
///   contract), labelled as the book labels it ("xiv", "212").
/// - Otherwise synthetic: a page per `charactersPerPage` (1,024) UTF-16 units of each chapter's
///   converted text, every spine item starting a new page (at least one each), numbered 1… through
///   the book. That is the Adobe RMSDK / Readium positions convention, counted on our own chapter
///   text so it needs no typesetting.
///
/// A page is found by position: the last page that starts at or before it. 🔴 Nothing stores these
/// numbers; positions, highlights and bookmarks are offsets and pointers.
public struct ReferencePages: Sendable, Equatable {
    public enum Source: String, Sendable {
        case pageList
        case synthetic
    }

    public struct Page: Sendable, Equatable {
        public var label: String
        public var spineIndex: Int
        public var offset: Int

        public init(label: String, spineIndex: Int, offset: Int) {
            self.label = label
            self.spineIndex = spineIndex
            self.offset = offset
        }
    }

    /// Why a page list was not used (nil when it was, or the book has none).
    public enum Rejection: Error, Equatable, Sendable, CustomStringConvertible {
        /// Fewer than `minimumResolved` entries, or under `minimumResolvedShare` of the labelled
        /// entries, point at a place in the converted chapters.
        case tooFewResolved(resolved: Int, of: Int)
        /// Entry `index` (among the resolved) points before the one listed before it.
        case backwards(index: Int, label: String)

        public var description: String {
            switch self {
            case let .tooFewResolved(resolved, total): "only \(resolved) of \(total) page-list entries resolve"
            case let .backwards(index, label): "page-list entry \(index) (\(label)) goes back in reading order"
            }
        }
    }

    public static let charactersPerPage = 1024
    /// A page list is used only when at least this share of its labelled entries resolve...
    public static let minimumResolvedShare = 0.9
    /// ...and at least this many.
    public static let minimumResolved = 2

    public let source: Source
    /// Every page in reading order (non-decreasing chapter and offset).
    public let pages: [Page]
    /// The M of "N of M": the page count for synthetic pages; for a page list the highest whole
    /// number among its labels (the print edition's last numbered page; roman front matter doesn't
    /// count), or the number of entries when none is a number.
    public let total: Int
    /// Set when the book has a page list that was not used.
    public let rejection: Rejection?

    /// The page that `offset` of chapter `spineIndex` falls in: the last one starting at or before
    /// it. Nil before the first page (front matter ahead of a page list's first marker).
    public func page(spineIndex: Int, offset: Int) -> Page? {
        var low = 0, high = pages.count
        while low < high {
            let mid = (low + high) / 2
            let page = pages[mid]
            if page.spineIndex < spineIndex || (page.spineIndex == spineIndex && page.offset <= offset) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? pages[low - 1] : nil
    }

    // MARK: Making them

    /// The book's page list if it is usable, else synthetic pages.
    public init(book: EPUBBook, chapters: [Chapter]) {
        let synthetic = ReferencePages(chapterLengths: chapters.map(\.textLength))
        guard !book.pageList.isEmpty else {
            self = synthetic
            return
        }
        switch Self.resolve(book.pageList, chapters: chapters, spineIndex: book.spineIndex(forPath:)) {
        case .success(let pages):
            self = pages
        case .failure(let rejection):
            self = ReferencePages(source: .synthetic, pages: synthetic.pages, total: synthetic.total, rejection: rejection)
        }
    }

    /// Synthetic pages for chapters of these lengths (UTF-16 units of converted text).
    public init(chapterLengths: [Int]) {
        var pages: [Page] = []
        for (spine, length) in chapterLengths.enumerated() {
            let count = max(1, (length + Self.charactersPerPage - 1) / Self.charactersPerPage)
            for index in 0 ..< count {
                pages.append(Page(label: "\(pages.count + 1)", spineIndex: spine, offset: index * Self.charactersPerPage))
            }
        }
        self.init(source: .synthetic, pages: pages, total: pages.count, rejection: nil)
    }

    private init(source: Source, pages: [Page], total: Int, rejection: Rejection?) {
        self.source = source
        self.pages = pages
        self.total = total
        self.rejection = rejection
    }

    /// Resolves each entry to a chapter (`spineIndex` of its path) and the offset its fragment's
    /// element starts at (`Chapter.anchorOffsets`; no fragment = the chapter's start). Entries
    /// without a label are ignored; ones that don't resolve are left out. 🔴 The list is unusable
    /// when fewer than 90 % of the labelled entries (or fewer than 2) resolve, or when any resolved
    /// entry lies before the one before it: a list like that numbers pages wrongly, and synthetic
    /// pages are better than wrong ones. Two markers at one place (a blank or plate page) are fine;
    /// the later one names the text there.
    public static func resolve(_ entries: [PageListEntry], chapters: [Chapter],
                               spineIndex: (String) -> Int?) -> Result<ReferencePages, Rejection> {
        var pages: [Page] = []
        var labelled = 0
        for entry in entries {
            let label = cleanLabel(entry.label)
            guard !label.isEmpty else { continue }
            labelled += 1
            guard let path = entry.path, let spine = spineIndex(path), spine >= 0, spine < chapters.count else { continue }
            let offset: Int
            if let fragment = entry.fragment {
                guard let found = chapters[spine].anchorOffsets[fragment] else { continue }
                offset = found
            } else {
                offset = 0
            }
            if let last = pages.last, spine < last.spineIndex || (spine == last.spineIndex && offset < last.offset) {
                return .failure(.backwards(index: pages.count, label: label))
            }
            pages.append(Page(label: label, spineIndex: spine, offset: offset))
        }
        guard pages.count >= minimumResolved, Double(pages.count) >= minimumResolvedShare * Double(labelled) else {
            return .failure(.tooFewResolved(resolved: pages.count, of: labelled))
        }
        let total = pages.compactMap { Int($0.label) }.max() ?? pages.count
        return .success(ReferencePages(source: .pageList, pages: pages, total: total, rejection: nil))
    }

    /// The label as the book gives it, whitespace trimmed, without ONE pair of brackets around the
    /// whole of it: Project Gutenberg writes its page markers "{475}" and "[12]" (they float in the
    /// margin of its HTML), and a folio of "{475}" would read as a typo.
    public static func cleanLabel(_ raw: String) -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]
        guard label.count > 2, let first = label.first, let last = label.last, pairs[first] == last else { return label }
        let inner = label.dropFirst().dropLast()
        guard !inner.contains(where: { "{}[]()".contains($0) }) else { return label }
        return inner.trimmingCharacters(in: .whitespaces)
    }
}
