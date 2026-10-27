import Foundation
import SwiftData
import UIKit

/// The colours a highlight can take; the fill is translucent so the glyphs stay crisp.
enum HighlightColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case yellow, green, blue, pink, purple
    var id: Self { self }

    var title: String { rawValue.capitalized }

    nonisolated var base: UIColor {
        switch self {
        case .yellow: UIColor(red: 1.0, green: 0.84, blue: 0.2, alpha: 1)
        case .green: UIColor(red: 0.45, green: 0.84, blue: 0.45, alpha: 1)
        case .blue: UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1)
        case .pink: UIColor(red: 1.0, green: 0.55, blue: 0.7, alpha: 1)
        case .purple: UIColor(red: 0.74, green: 0.6, blue: 1.0, alpha: 1)
        }
    }

    nonisolated func fill(dark: Bool) -> UIColor { base.withAlphaComponent(dark ? 0.36 : 0.42) }
    nonisolated func underline(dark: Bool) -> UIColor { base.withAlphaComponent(dark ? 0.95 : 0.9) }
}

/// A highlight, with an optional note, over a run of one chapter's text. Offsets follow the same
/// contract as the reading position: UTF-16 units into the chapter's plain text. The CREngine
/// pointers for both ends are kept alongside, for export and for other readers.
@Model
final class Annotation {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var spineIndex: Int
    var startOffset: Int
    var endOffset: Int
    var startPointer: String?
    var endPointer: String?
    /// The highlighted text, as it reads on the page.
    var text: String
    var note: String
    var colorRaw: String
    var isUnderline: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(id: UUID = UUID(), bookID: UUID, spineIndex: Int, startOffset: Int, endOffset: Int,
         startPointer: String? = nil, endPointer: String? = nil, text: String, note: String = "",
         color: HighlightColor, isUnderline: Bool = false) {
        self.id = id
        self.bookID = bookID
        self.spineIndex = spineIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.startPointer = startPointer
        self.endPointer = endPointer
        self.text = text
        self.note = note
        self.colorRaw = color.rawValue
        self.isUnderline = isUnderline
        self.createdAt = .now
        self.modifiedAt = .now
    }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    var range: NSRange { NSRange(location: startOffset, length: max(0, endOffset - startOffset)) }
    var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var mark: HighlightMark { HighlightMark(id: id, spineIndex: spineIndex, range: range, color: color, isUnderline: isUnderline) }
}

/// What a page needs to paint a highlight: a value, so the pager can tell "nothing changed".
struct HighlightMark: Hashable, Sendable {
    var id: UUID
    var spineIndex: Int
    var range: NSRange
    var color: HighlightColor
    var isUnderline: Bool
    /// A search hit (`BookSearchModel`), painted until the next page turn or tap; not tappable.
    var isFound = false
}

/// Notes and highlights (by chapter, then the bookmarks as their own "## Bookmarks" list) as
/// Markdown, and single quotes as plain text, for sharing. Both credit their source through
/// `Credit`, so the book's title, author and chapter read the same in each.
enum AnnotationExport {
    /// Where a quote comes from, cleaned once for every export: names trimmed, runs of whitespace
    /// folded, blanks dropped.
    struct Credit: Equatable, Sendable {
        var title: String
        var author: String?
        var chapter: String?

        nonisolated init(title: String, author: String?, chapter: String?) {
            self.title = Self.clean(title) ?? ""
            self.author = Self.clean(author)
            self.chapter = Self.clean(chapter)
        }

        /// `— Author, Title, Chapter`, leaving out whatever is unknown, and the chapter when it only
        /// repeats the book's title (a one-file book, a TOC naming the book). Only here: the
        /// Markdown export still heads such a chapter (a collection named after one of its stories).
        nonisolated var attribution: String {
            let chapter = chapter?.caseInsensitiveCompare(title) == .orderedSame ? nil : chapter
            return "— " + [author, title.isEmpty ? nil : title, chapter].compactMap { $0 }.joined(separator: ", ")
        }

        /// Trimmed, with runs of whitespace (a title's line breaks) folded to one space; nil if blank.
        nonisolated static func clean(_ value: String?) -> String? {
            let words = (value ?? "").split(whereSeparator: { $0.isWhitespace })
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
    }

    /// A quote as it is shared: the text, then the credit on its own line. The text is never
    /// shortened; only image placeholders (U+FFFC) and blank lines are dropped and every line
    /// trimmed, so a selection that swept up a paragraph break or an illustration reads cleanly.
    nonisolated static func quote(_ text: String, credit: Credit) -> String {
        quoteText(text) + "\n" + credit.attribution
    }

    /// The text of a quote, cleaned as `quote` cleans it (the share card draws the same text).
    nonisolated static func quoteText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated static func markdown(title: String, author: String?, annotations: [(chapter: String?, text: String, note: String)],
                                     bookmarks: [(chapter: String?, label: String)] = []) -> String {
        let book = Credit(title: title, author: author, chapter: nil)
        var lines = ["# \(book.title)"]
        if let author = book.author { lines.append("*\(author)*") }
        var currentChapter: String?? = .some(nil)
        for item in annotations {
            let chapter = Credit.clean(item.chapter)
            if currentChapter != .some(chapter) {
                currentChapter = .some(chapter)
                if let chapter {
                    lines.append("")
                    lines.append("## \(chapter)")
                }
            }
            lines.append("")
            for quoted in item.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(quoted)")
            }
            let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                lines.append("")
                lines.append(note)
            }
        }
        if !bookmarks.isEmpty {
            lines.append("")
            lines.append("## Bookmarks")
            lines.append("")
            for bookmark in bookmarks {
                let parts = [Credit.clean(bookmark.chapter), Credit.clean(bookmark.label)].compactMap { $0 }
                lines.append("- " + (parts.isEmpty ? "Bookmark" : parts.joined(separator: " — ")))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
