import Foundation

/// A passage the reader picked to ask about (a selection in the book): the subject of one question.
/// `range` is in UTF-16 units of the chapter plain text (the position contract, `Block`).
public struct AskSubject: Hashable, Sendable {
    public var spineIndex: Int
    public var range: Range<Int>

    public init(spineIndex: Int, range: Range<Int>) {
        self.spineIndex = spineIndex
        self.range = range
    }

    /// The longest subject quoted to the model, in UTF-16 units: about 400 tokens of the 4096 the
    /// on-device model has for everything.
    public static let maxLength = 1200

    /// 🔴 The spoiler wall for a picked passage, like `ReadSoFar`'s: its text up to `limit` only.
    /// A selection that runs past the limit is cut before it, back to a whole word; one that starts
    /// at or past it gives nil. Read as the reader sees it (a table row is its cells' text), cleaned
    /// like a passage, and at most `maxLength` units (cut at a word, "…" after).
    public func text(in chapters: [Chapter], limit: ReadingLimit, maxLength: Int = AskSubject.maxLength) -> String? {
        guard chapters.indices.contains(spineIndex), !range.isEmpty,
              limit.admits(spineIndex: spineIndex, offset: range.lowerBound) else { return nil }
        var end = range.upperBound
        var cut = false
        if spineIndex == limit.spineIndex, end > limit.textOffset {
            end = limit.textOffset
            cut = true
        }
        var text = chapters[spineIndex].displayText(in: range.lowerBound ..< end)
        if cut { text = ReadSoFar.cutToWord(text) }
        text = ReadSoFar.clean(text)
        if text.utf16.count > maxLength {
            var units = 0
            let head = text.prefix { character in
                units += character.utf16.count
                return units <= maxLength
            }
            text = ReadSoFar.cutToWord(String(head)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text.isEmpty ? nil : text
    }
}
