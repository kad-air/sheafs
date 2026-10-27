import Foundation

/// One match of a search: a run of one chapter's text.
///
/// `range` is in UTF-16 units of the chapter's plain text, the same contract as a reading
/// position or a highlight (`Block`), so `range.lowerBound` is directly a `textOffset` and the
/// range an `NSRange` of the typeset chapter. A match always covers whole characters (grapheme
/// clusters): a search for "e" that matches the "é" of "cafe\u{301}" covers both scalars.
public struct SearchHit: Hashable, Sendable {
    public var spineIndex: Int
    public var range: Range<Int>

    public init(spineIndex: Int, range: Range<Int>) {
        self.spineIndex = spineIndex
        self.range = range
    }

    public var textOffset: Int { range.lowerBound }
    public var length: Int { range.count }
}

/// A few words either side of a match, from the block that holds it.
public struct SearchSnippet: Hashable, Sendable {
    public var before: String
    public var match: String
    public var after: String
    /// The block goes on before `before` / after `after` (the list shows an ellipsis).
    public var isCutBefore: Bool
    public var isCutAfter: Bool

    public init(before: String, match: String, after: String, isCutBefore: Bool, isCutAfter: Bool) {
        self.before = before
        self.match = match
        self.after = after
        self.isCutBefore = isCutBefore
        self.isCutAfter = isCutAfter
    }

    /// The snippet as one line, ellipses included.
    public var text: String {
        (isCutBefore ? "…" : "") + before + match + after + (isCutAfter ? "…" : "")
    }
}

/// What a search found: the first `limit` hits in book order, and how many there are in all.
public struct BookSearchResult: Sendable {
    public var query: String
    /// In book order (chapter, then offset); at most the search's `limit`.
    public var hits: [SearchHit]
    /// Every match per spine index, including those past the limit.
    public var countsBySpine: [Int: Int]
    public var totalCount: Int

    public var isTruncated: Bool { hits.count < totalCount }
}

/// Find-in-book over converted chapters: case-, diacritic- and width-insensitive, typographic
/// quotes match straight ones, runs of whitespace match any run, soft hyphens and other invisible
/// characters are skipped. Each chapter's text is folded once (`init`, a few hundred ms for a long
/// book, so build it off the main actor); every search after that is a scan of the folded text.
public struct BookSearchIndex: Sendable {
    public let chapters: [Chapter]
    private let texts: [FoldedText]

    public init(chapters: [Chapter]) {
        self.chapters = chapters
        texts = chapters.map(FoldedText.init(chapter:))
    }

    /// The hits for `query` in book order, at most `limit` of them (all are counted). Nil for a
    /// query that is empty once folded, or when `isCancelled` says so (checked between chapters).
    public func search(_ query: String, limit: Int = 500, isCancelled: () -> Bool = { false }) -> BookSearchResult? {
        let needle = SearchFolding.foldQuery(query)
        guard !needle.isEmpty else { return nil }
        var hits: [SearchHit] = []
        var counts: [Int: Int] = [:]
        var total = 0
        for (spine, text) in texts.enumerated() {
            if isCancelled() { return nil }
            let ranges = text.matches(of: needle)
            guard !ranges.isEmpty else { continue }
            counts[spine] = ranges.count
            total += ranges.count
            for range in ranges where hits.count < limit {
                hits.append(SearchHit(spineIndex: spine, range: range))
            }
        }
        return BookSearchResult(query: query, hits: hits, countsBySpine: counts, totalCount: total)
    }

    /// Every hit for `query` in one chapter (the reader paints those on the page it shows).
    public func hits(of query: String, inSpine spine: Int) -> [SearchHit] {
        let needle = SearchFolding.foldQuery(query)
        guard !needle.isEmpty, spine >= 0, spine < texts.count else { return [] }
        return texts[spine].matches(of: needle).map { SearchHit(spineIndex: spine, range: $0) }
    }

    /// Up to about `context` UTF-16 units of the hit's block either side of it, cut at spaces.
    public func snippet(for hit: SearchHit, context: Int = 40) -> SearchSnippet {
        guard hit.spineIndex >= 0, hit.spineIndex < chapters.count else {
            return SearchSnippet(before: "", match: "", after: "", isCutBefore: false, isCutAfter: false)
        }
        return BookSearchIndex.snippet(for: hit.range, in: chapters[hit.spineIndex], context: context)
    }

    static func snippet(for range: Range<Int>, in chapter: Chapter, context: Int) -> SearchSnippet {
        guard let block = chapter.block(containing: range.lowerBound) else {
            return SearchSnippet(before: "", match: "", after: "", isCutBefore: false, isCutAfter: false)
        }
        if case .table(let table) = block.kind {
            // The hit is a whole row: its text, nothing marked (the match is somewhere in it).
            let row = table.plainText(atOffset: range.lowerBound - block.textOffset)
            let cut = row.count > context * 3
            return SearchSnippet(before: cut ? String(row.prefix(context * 3)) : row, match: "", after: "",
                                 isCutBefore: false, isCutAfter: cut)
        }
        let text = block.text as NSString
        let length = text.length
        let lower = max(0, min(length, range.lowerBound - block.textOffset))
        let upper = max(lower, min(length, range.upperBound - block.textOffset))

        // Before: back up `context` units, then forward to the start of a word. A space right
        // before the match counts (the snippet then starts at the match); with no space in reach
        // the word is longer than the context, so nothing before the match is shown.
        var start = max(0, lower - context)
        if start > 0, text.character(at: start - 1) != 0x20 {
            let space = text.range(of: " ", options: [], range: NSRange(location: start, length: lower - start))
            start = space.location != NSNotFound ? space.location + 1 : lower
        }
        start = composedBoundary(text, at: start, forward: true)
        // After: a little more after than before (the eye reads on), back to the end of a word,
        // by the same rules (a space right after the match counts; none in reach shows nothing).
        var end = min(length, upper + context * 3 / 2)
        if end < length, text.character(at: end) != 0x20 {
            let space = text.range(of: " ", options: .backwards, range: NSRange(location: upper, length: end - upper))
            end = space.location != NSNotFound ? space.location : upper
        }
        end = composedBoundary(text, at: end, forward: false)
        start = min(start, lower)
        end = max(end, upper)
        return SearchSnippet(
            before: text.substring(with: NSRange(location: start, length: lower - start)),
            match: text.substring(with: NSRange(location: lower, length: upper - lower)),
            after: text.substring(with: NSRange(location: upper, length: end - upper)),
            isCutBefore: start > 0,
            isCutAfter: end < length
        )
    }

    /// `offset` moved to a character boundary (never inside a surrogate pair or a combining sequence).
    private static func composedBoundary(_ text: NSString, at offset: Int, forward: Bool) -> Int {
        guard offset > 0, offset < text.length else { return offset }
        let sequence = text.rangeOfComposedCharacterSequence(at: offset)
        guard sequence.location < offset else { return offset }
        return forward ? NSMaxRange(sequence) : sequence.location
    }
}

/// One chapter's plain text folded for matching, with each folded UTF-16 unit mapped back to the
/// character (grapheme cluster) of the original it came from.
struct FoldedText: Sendable {
    var units: [UInt16] = []
    /// UTF-16 offset in the chapter's plain text where the character behind `units[i]` starts…
    var starts: [Int32] = []
    /// …and ends.
    var ends: [Int32] = []
    /// The unit comes from a table row's text, which all maps to the row's one object character:
    /// several matches in one row are several hits on that character.
    var inObject: [Bool] = []

    init(chapter: Chapter) {
        units.reserveCapacity(chapter.textLength)
        starts.reserveCapacity(chapter.textLength)
        ends.reserveCapacity(chapter.textLength)
        var offset = 0
        for block in chapter.blocks {
            offset = block.textOffset
            if case .table(let table) = block.kind {
                // A table's cells are not in the plain text: search each row's (and the caption's)
                // text, every match landing on that row's object; matches never cross rows.
                for object in stride(from: 0, to: block.textLength, by: 2) {
                    let start = block.textOffset + object
                    for character in table.plainText(atOffset: object) {
                        append(SearchFolding.fold(character), from: start, to: start + 1, inObject: true)
                    }
                    append([0x0A], from: start, to: start + 1, inObject: true)
                }
                continue
            }
            for character in block.text {
                let width = character.utf16.count
                append(SearchFolding.fold(character), from: offset, to: offset + width)
                offset += width
            }
            // The block separator: matches never run from one block into the next.
            append([0x0A], from: offset, to: offset + 1)
        }
    }

    private mutating func append(_ folded: [UInt16], from start: Int, to end: Int, inObject: Bool = false) {
        if folded == [SearchFolding.space], units.last == SearchFolding.space || units.last == 0x0A || units.isEmpty {
            return // runs of whitespace fold to one space
        }
        for unit in folded {
            units.append(unit)
            starts.append(Int32(start))
            ends.append(Int32(end))
            self.inObject.append(inObject)
        }
    }

    /// Non-overlapping matches of a folded needle, as ranges of the original text.
    func matches(of needle: [UInt16]) -> [Range<Int>] {
        let n = units.count, m = needle.count
        guard m > 0, n >= m else { return [] }
        var result: [Range<Int>] = []
        units.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                let first = pin[0]
                var i = 0
                while i <= n - m {
                    if hay[i] == first {
                        var j = 1
                        while j < m, hay[i + j] == pin[j] { j += 1 }
                        if j == m {
                            let range = Int(starts[i]) ..< Int(ends[i + m - 1])
                            // One character folded to several units ("ß" → "ss") can match twice.
                            if let last = result.last, range.lowerBound < last.upperBound, !inObject[i] {
                                i += 1
                                continue
                            }
                            result.append(range)
                            i += m
                            continue
                        }
                    }
                    i += 1
                }
            }
        }
        return result
    }
}

/// How text and queries are folded before they are compared. Both go through `fold`, one
/// character at a time, so whatever it does, a query matches the text it was typed from.
enum SearchFolding {
    static let space: UInt16 = 0x20

    /// A typed query, folded, with whitespace trimmed and runs collapsed.
    static func foldQuery(_ query: String) -> [UInt16] {
        var result: [UInt16] = []
        for character in query {
            let folded = fold(character)
            if folded == [space] {
                if result.isEmpty || result.last == space { continue }
            }
            result += folded
        }
        while result.last == space { result.removeLast() }
        return result
    }

    /// One character → the UTF-16 units it is compared as (none for invisible characters).
    static func fold(_ character: Character) -> [UInt16] {
        if let ascii = character.asciiValue {
            switch ascii {
            case 0x41 ... 0x5A: return [UInt16(ascii) + 0x20]
            case 0x09 ... 0x0D: return [space] // a newline only ever comes from a query: the text's separators are added apart
            case 0x60: return [0x27] // ` → '
            default: return [UInt16(ascii)]
            }
        }
        if character.isWhitespace { return [space] }
        // Invisible characters (soft hyphen, zero-width space/joiners, BOM) disappear; a joiner
        // inside an emoji sequence goes too, from the text and the query alike.
        let visible = String(String.UnicodeScalarView(character.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }))
        guard !visible.isEmpty else { return [] }
        if visible.unicodeScalars.count == 1, let scalar = visible.unicodeScalars.first, let quote = quotes[scalar.value] {
            return [quote]
        }
        let folded = visible.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.unicodeScalars.flatMap { scalar -> [UInt16] in
            if let quote = quotes[scalar.value] { return [quote] }
            return Array(String(scalar).utf16)
        }
    }

    /// Typographic quotes and primes → the straight ones a keyboard types.
    private static let quotes: [UInt32: UInt16] = [
        0x2018: 0x27, 0x2019: 0x27, 0x201A: 0x27, 0x201B: 0x27, 0x2032: 0x27, 0x02BC: 0x27, 0x00B4: 0x27,
        0x201C: 0x22, 0x201D: 0x22, 0x201E: 0x22, 0x201F: 0x22, 0x2033: 0x22, 0x00AB: 0x22, 0x00BB: 0x22,
    ]
}
