import Foundation

/// The markdown Ask's answers come back in (models write **bold**, *italics*, "- " bullets and
/// numbered lists), parsed into blocks of styled runs for the Ask pane to draw. A small, tolerant
/// subset: paragraphs (a blank line apart; a single line break stays a line break, as the answer
/// was always shown), "-", "*", "+" and "•" bullets and "1." / "1)" items, nested by indent,
/// "#" headings, "> " quotes, rules (dropped); inline `**bold**` / `__bold__`, `*italic*` /
/// `_italic_` (not inside a word), `***both***`, `` `code` `` and backslash escapes. Anything else
/// stays text, and an emphasis mark with no partner is shown as typed.
///
/// `streaming`: the answer is still arriving, so its end may stop mid-markup. 🔴 Nothing may show
/// raw and then change: an emphasis opened and not yet closed styles what has come so far, a mark
/// with nothing after it yet is held back, and so is a last line that is only a list marker or a
/// "#" so far. Every prefix's visible text is a prefix of the whole answer's (`AnswerMarkdownTests`).
public enum AnswerMarkdown {
    public struct Run: Hashable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false

        public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
        }
    }

    public enum Block: Hashable, Sendable {
        case paragraph([Run])
        case heading(level: Int, [Run])
        /// `marker`: "•" for a bullet, the number as written ("3." or "3)") for a numbered item.
        /// `depth`: how deeply it is nested, 0 for the outermost list (at most 3).
        case item(marker: String, ordered: Bool, depth: Int, [Run])
        case quote([Run])

        public var runs: [Run] {
            switch self {
            case .paragraph(let runs), .heading(_, let runs), .item(_, _, _, let runs), .quote(let runs): runs
            }
        }

        /// The block's text as read, emphasis marks gone ("\n" where a line breaks inside it).
        public var text: String { runs.map(\.text).joined() }
    }

    public static func parse(_ markdown: String, streaming: Bool = false) -> [Block] {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        // The last line of an answer still arriving that is only a list marker or a heading's "#"
        // so far: what it is becomes clear with the next words.
        if streaming, let last = lines.last, isBareMarker(last) { lines.removeLast() }

        var pending: [Pending] = []
        var open = false              // the last pending block takes the next text line
        var afterBlank = false
        var listIndents: [Int] = []   // indents of the enclosing list items, outermost first

        for line in lines {
            switch classify(line) {
            case .blank:
                open = false
                afterBlank = true
                continue
            case .heading(let level, let text):
                pending.append(Pending(kind: .heading(level), lines: [text]))
                open = false
                listIndents = []
            case .rule:
                open = false
                listIndents = []
            case .item(let indent, let marker, let ordered, let text):
                while let last = listIndents.last, last > indent { listIndents.removeLast() }
                if listIndents.last != indent { listIndents.append(indent) }
                pending.append(Pending(kind: .item(marker: marker, ordered: ordered, depth: min(3, listIndents.count - 1)), lines: [text]))
                open = true
            case .quote(let text):
                if open, !afterBlank, case .quote = pending.last?.kind {
                    pending[pending.count - 1].lines.append(text)
                } else {
                    pending.append(Pending(kind: .quote, lines: [text]))
                    listIndents = []
                }
                open = true
            case .text(let indent, let text):
                if open, !afterBlank, !pending.isEmpty {
                    // A line break inside the paragraph, item or quote (an item's lazy continuation).
                    pending[pending.count - 1].lines.append(text)
                } else if afterBlank, indent >= 2, let last = pending.last, case .item = last.kind {
                    // An indented paragraph after a blank line belongs to the item above it.
                    pending[pending.count - 1].lines.append(text)
                } else {
                    pending.append(Pending(kind: .paragraph, lines: [text]))
                    listIndents = []
                }
                open = true
            }
            afterBlank = false
        }

        return pending.enumerated().map { index, block in
            let runs = runs(block.lines.joined(separator: "\n"), openEnded: streaming && index == pending.count - 1)
            switch block.kind {
            case .paragraph: return .paragraph(runs)
            case .heading(let level): return .heading(level: level, runs)
            case .item(let marker, let ordered, let depth): return .item(marker: marker, ordered: ordered, depth: depth, runs)
            case .quote: return .quote(runs)
            }
        }
    }

    /// Inline markup in one block's text. `openEnded`: the text is the end of an answer still
    /// arriving (see `parse`).
    public static func runs(_ text: String, openEnded: Bool = false) -> [Run] {
        let characters = Array(text)
        var out: [Run] = []
        inline(characters, 0 ..< characters.count, style: Style(), openEnded: openEnded, into: &out)
        // Adjacent runs in one style read as one.
        var merged: [Run] = []
        for run in out where !run.text.isEmpty {
            if let last = merged.last, last.bold == run.bold, last.italic == run.italic, last.code == run.code {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    // MARK: Blocks

    private struct Pending {
        enum Kind: Equatable {
            case paragraph, heading(Int), item(marker: String, ordered: Bool, depth: Int), quote
        }
        var kind: Kind
        var lines: [String]
    }

    private enum Line {
        case blank, rule
        case heading(level: Int, text: String)
        case item(indent: Int, marker: String, ordered: Bool, text: String)
        case quote(String)
        case text(indent: Int, String)
    }

    /// Leading spaces (a tab counts 4) and the rest of the line.
    private static func indentation(_ line: Substring) -> (indent: Int, rest: Substring) {
        var indent = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        return (indent, line[index...])
    }

    private static func classify(_ line: Substring) -> Line {
        let (indent, rest) = indentation(line)
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        let chars = Array(rest)
        if indent < 4, chars[0] == "#" {
            let level = chars.prefix { $0 == "#" }.count
            if level <= 6, level == chars.count || chars[level] == " " {
                var text = String(chars[level...]).trimmingCharacters(in: .whitespaces)
                // A closing run of #s is decoration.
                while text.hasSuffix("#") { text.removeLast() }
                return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
            }
        }
        if indent < 4, let mark = trimmed.first, "-*_".contains(mark),
           trimmed.allSatisfy({ $0 == mark || $0 == " " }), trimmed.filter({ $0 == mark }).count >= 3 {
            return .rule
        }
        if "-*+•".contains(chars[0]), chars.count >= 2, chars[1] == " " || chars[1] == "\t" {
            return .item(indent: indent, marker: "•", ordered: false, text: String(chars[2...]).trimmingCharacters(in: .whitespaces))
        }
        let digits = chars.prefix { $0.isASCII && $0.isNumber }.count
        if (1 ... 3).contains(digits), chars.count > digits + 1, chars[digits] == "." || chars[digits] == ")",
           chars[digits + 1] == " " || chars[digits + 1] == "\t" {
            return .item(indent: indent, marker: String(chars[...digits]), ordered: true,
                         text: String(chars[(digits + 2)...]).trimmingCharacters(in: .whitespaces))
        }
        if indent < 4, chars[0] == ">" {
            var text = chars.dropFirst()
            if text.first == " " { text = text.dropFirst() }
            return .quote(String(text))
        }
        return .text(indent: indent, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// "-", "*", "+", "•", "12", "12.", "###" or "--" alone: a line that is so far only a marker
    /// (or a rule on its way).
    private static func isBareMarker(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if ["+", "•"].contains(trimmed) { return true }
        let marks = Set(trimmed.filter { $0 != " " })
        if marks.count == 1, let mark = marks.first, "-*_".contains(mark) { return true }
        if trimmed.allSatisfy({ $0 == "#" }) { return trimmed.count <= 6 }
        var digits = Substring(trimmed)
        if digits.last == "." || digits.last == ")" { digits = digits.dropLast() }
        return (1 ... 3).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: Inline

    private struct Style {
        var bold = false, italic = false
    }

    private static func inline(_ c: [Character], _ range: Range<Int>, style: Style, openEnded: Bool, into out: inout [Run]) {
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { out.append(Run(buffer, bold: style.bold, italic: style.italic)) }
            buffer = ""
        }
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let ch = c[i]
            if ch == "\\", i + 1 < end, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                buffer.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "`" {
                if let close = (i + 1 ..< end).first(where: { c[$0] == "`" }) {
                    flush()
                    out.append(Run(String(c[(i + 1) ..< close]), bold: style.bold, italic: style.italic, code: true))
                    i = close + 1
                    continue
                }
                if openEnded {
                    flush()
                    out.append(Run(String(c[(i + 1) ..< end]), bold: style.bold, italic: style.italic, code: true))
                    return
                }
            }
            if ch == "*" || ch == "_" {
                var n = 1
                while i + n < end, c[i + n] == ch { n += 1 }
                if n <= 3, canOpen(c, at: i, count: n, end: end) {
                    var inner = style
                    if n >= 2 { inner.bold = true }
                    if n != 2 { inner.italic = true }
                    if let close = closer(c, ch, count: n, from: i + n, end: end) {
                        flush()
                        inline(c, (i + n) ..< close, style: inner, openEnded: false, into: &out)
                        i = close + n
                        continue
                    }
                    if openEnded {
                        // Its partner hasn't arrived yet: what has come so far is in its style.
                        flush()
                        inline(c, (i + n) ..< end, style: inner, openEnded: true, into: &out)
                        return
                    }
                } else if openEnded, n <= 3, i + n == end {
                    // The very end of an answer still arriving: the next character decides.
                    flush()
                    return
                }
                buffer += String(repeating: ch, count: n)
                i += n
                continue
            }
            buffer.append(ch)
            i += 1
        }
        flush()
    }

    /// A run of `count` marks at `i` can open emphasis: something other than a space follows it,
    /// and an underscore is not inside a word.
    private static func canOpen(_ c: [Character], at i: Int, count: Int, end: Int) -> Bool {
        guard i + count < end, !c[i + count].isWhitespace else { return false }
        if c[i] == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return false }
        return true
    }

    /// Where the run that closes `count` marks of `mark` starts (from `start`, before `end`): one
    /// of the same length after something other than a space (an underscore not inside a word).
    /// `***` also closes one or two marks (its last ones), as in `**bold *and italic***`. Code
    /// spans are skipped whole.
    private static func closer(_ c: [Character], _ mark: Character, count: Int, from start: Int, end: Int) -> Int? {
        var j = start
        while j < end {
            if c[j] == "`", let close = (j + 1 ..< end).first(where: { c[$0] == "`" }) {
                j = close + 1
                continue
            }
            guard c[j] == mark else {
                j += 1
                continue
            }
            var m = 1
            while j + m < end, c[j + m] == mark { m += 1 }
            let closes = j > start && !c[j - 1].isWhitespace
                && (mark != "_" || j + m >= c.count || !(c[j + m].isLetter || c[j + m].isNumber))
            if closes, m == count { return j }
            if closes, m == 3, count < 3 { return j + m - count }
            j += m
        }
        return nil
    }
}
