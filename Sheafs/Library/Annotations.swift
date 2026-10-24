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
}

/// Notes and highlights as Markdown, for sharing.
enum AnnotationExport {
    nonisolated static func markdown(title: String, author: String?, annotations: [(chapter: String?, text: String, note: String)]) -> String {
        var lines = ["# \(title)"]
        if let author, !author.isEmpty { lines.append("*\(author)*") }
        var currentChapter: String?? = .some(nil)
        for item in annotations {
            if currentChapter != .some(item.chapter) {
                currentChapter = .some(item.chapter)
                if let chapter = item.chapter, !chapter.isEmpty {
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
        return lines.joined(separator: "\n") + "\n"
    }
}
