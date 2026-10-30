import Foundation

/// A stretch of one chapter's text, a paragraph or a few: the unit the reading companion looks
/// things up in and quotes to the model. `range` is in UTF-16 units of the chapter plain text
/// (the position contract, `Block`), so its lower bound is a `textOffset` to jump to.
public struct Passage: Hashable, Sendable {
    public var spineIndex: Int
    public var range: Range<Int>
    public var text: String

    public init(spineIndex: Int, range: Range<Int>, text: String) {
        self.spineIndex = spineIndex
        self.range = range
        self.text = text
    }
}

/// Where the reader has got to: nothing at or after it is ever handed to the model.
public struct ReadingLimit: Hashable, Sendable {
    public var spineIndex: Int
    /// UTF-16 offset in that chapter; text from here on is unread.
    public var textOffset: Int

    public init(spineIndex: Int, textOffset: Int) {
        self.spineIndex = spineIndex
        self.textOffset = textOffset
    }

    /// Whether `spine`/`offset` comes before the limit.
    public func admits(spineIndex spine: Int, offset: Int) -> Bool {
        spine < spineIndex || (spine == spineIndex && offset < textOffset)
    }
}

/// 🔴 The spoiler wall. The book's text up to `ReadingLimit` cut into passages; everything the
/// reading companion shows the model (excerpts, and the chapter summaries made from them) comes
/// from here, so nothing past the limit can reach it. A block that runs over the limit is cut
/// before it, back to the last whole word.
public enum ReadSoFar {
    /// Passages of about `targetLength` UTF-16 units: whole paragraphs gathered until the length is
    /// reached, a heading starting a new passage, a paragraph longer than twice the target split at
    /// sentence ends. Pictures and rules carry no text and are skipped; a table reads as its rows.
    public static func passages(chapters: [Chapter], limit: ReadingLimit, targetLength: Int = 700) -> [Passage] {
        var result: [Passage] = []
        for spine in 0 ... min(limit.spineIndex, chapters.count - 1) where spine >= 0 {
            result += passages(of: chapters[spine], spineIndex: spine, limit: limit, targetLength: targetLength)
        }
        return result
    }

    /// One chapter's passages (all of it when the limit is past the chapter).
    public static func passages(of chapter: Chapter, spineIndex: Int, limit: ReadingLimit? = nil, targetLength: Int = 700) -> [Passage] {
        var result: [Passage] = []
        var pending: (start: Int, end: Int, text: String)?

        func flush() {
            if let open = pending, !open.text.isEmpty {
                result.append(Passage(spineIndex: spineIndex, range: open.start ..< open.end, text: open.text))
            }
            pending = nil
        }

        for block in chapter.blocks {
            if let limit, !limit.admits(spineIndex: spineIndex, offset: block.textOffset) { break }
            switch block.kind {
            case .image, .horizontalRule: continue
            default: break
            }
            var end = block.textOffset + block.textLength
            var text = chapter.displayText(in: block.textOffset ..< end)
            if let limit, limit.spineIndex == spineIndex, end > limit.textOffset {
                end = limit.textOffset
                text = cutToWord(chapter.displayText(in: block.textOffset ..< end))
            }
            text = clean(text)
            guard !text.isEmpty else { continue }

            if case .heading = block.kind {
                flush()
                pending = (block.textOffset, end, text)
                continue
            }
            if text.utf16.count > targetLength * 2 {
                flush()
                for piece in split(text, near: targetLength) {
                    // Pieces keep the paragraph's range: a jump lands on the paragraph.
                    result.append(Passage(spineIndex: spineIndex, range: block.textOffset ..< end, text: piece))
                }
                continue
            }
            if var open = pending {
                open.text += "\n" + text
                open.end = end
                pending = open
            } else {
                pending = (block.textOffset, end, text)
            }
            if let open = pending, open.text.utf16.count >= targetLength { flush() }
        }
        flush()
        return result
    }

    /// Whitespace runs to one space per line, lines trimmed, empty lines dropped; the object
    /// character of a picture inside a paragraph goes too.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: " ")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// `text` without a word cut in half at its end.
    static func cutToWord(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace, !last.isPunctuation else { return text }
        guard let space = text.lastIndex(where: \.isWhitespace) else { return "" }
        return String(text[..<space])
    }

    /// `text` in pieces of about `length` UTF-16 units, cut after a sentence end (else a space).
    static func split(_ text: String, near length: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > length * 3 / 2 {
            let window = rest.index(rest.startIndex, offsetBy: length, limitedBy: rest.endIndex) ?? rest.endIndex
            let head = rest[..<window]
            let cut = head.lastIndex(where: { ".!?…".contains($0) }).map { rest.index(after: $0) }
                ?? head.lastIndex(where: \.isWhitespace)
                ?? window
            let piece = rest[..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...].drop(while: \.isWhitespace)
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
