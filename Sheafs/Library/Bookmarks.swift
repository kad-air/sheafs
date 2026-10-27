import Foundation
import SwiftData

/// A marked page. Stored like the reading position: the chapter (spine index) and the UTF-16
/// offset of the first character of the page that held the position when it was made (the
/// right-hand page of a spread), with the CREngine pointer of that place alongside. The anchor is
/// an offset, never a page number: after a text-size change the bookmark is on whichever page now
/// holds that character. Keyed by book id like `Annotation`, so `LibraryStore.delete(book)`
/// deletes them by hand.
@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var spineIndex: Int
    var textOffset: Int
    var xpointer: String?
    /// The page's first words, for the list.
    var label: String
    var createdAt: Date

    init(id: UUID = UUID(), bookID: UUID, spineIndex: Int, textOffset: Int, xpointer: String? = nil, label: String = "") {
        self.id = id
        self.bookID = bookID
        self.spineIndex = spineIndex
        self.textOffset = textOffset
        self.xpointer = xpointer
        self.label = label
        self.createdAt = .now
    }

    var location: ReadingLocation { ReadingLocation(spineIndex: spineIndex, textOffset: textOffset) }
    var mark: BookmarkMark { BookmarkMark(id: id, spineIndex: spineIndex, textOffset: textOffset) }

    /// The first words from `offset` in a chapter's text, on one line: a page that starts inside a
    /// hyphenated word starts the label at that word, images and line breaks are spaces, and the
    /// label stops at a word boundary before `maxLength` characters, with an ellipsis.
    nonisolated static func label(in text: NSString, at offset: Int, maxLength: Int = 60) -> String {
        guard text.length > 0 else { return "" }
        var start = max(0, min(offset, text.length - 1))
        let letters = CharacterSet.alphanumerics
        func isLetter(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return letters.contains(scalar)
        }
        var back = 0
        while start > 0, back < 40, isLetter(start - 1), isLetter(start) { start -= 1; back += 1 }
        let window = text.substring(with: NSRange(location: start, length: min(text.length - start, maxLength * 4)))
        let words = window.replacingOccurrences(of: "\u{FFFC}", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        var label = ""
        for word in words {
            let next = label.isEmpty ? String(word) : label + " " + word
            if next.count > maxLength {
                if label.isEmpty { label = String(word.prefix(maxLength)) }
                return label + "…"
            }
            label = next
        }
        return label
    }
}

/// What a page needs to draw a bookmark ribbon: a value, so the pager can tell "nothing changed".
struct BookmarkMark: Hashable, Sendable {
    var id: UUID
    var spineIndex: Int
    var textOffset: Int
}

extension PaginatedChapter {
    /// The bookmarks among `marks` that lie on `page` of this chapter: those whose offset falls in
    /// the page's character range, whatever page they were made on.
    func bookmarks(_ marks: [BookmarkMark], onPage page: Int) -> [BookmarkMark] {
        marks.filter { $0.spineIndex == spineIndex && pageIndex(containing: $0.textOffset) == page }
    }
}
