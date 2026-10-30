import Foundation

/// A summary of one chapter the reader has finished, made earlier by the on-device model.
public struct ChapterRecap: Hashable, Sendable {
    public var spineIndex: Int
    public var summary: String

    public init(spineIndex: Int, summary: String) {
        self.spineIndex = spineIndex
        self.summary = summary
    }
}

/// What one question is answered from: chapter summaries and passages, all from before the reading
/// limit, chosen to fit a character budget, and the text the model is shown.
public struct AskContext: Sendable {
    public struct Excerpt: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// Matched the question's words, or introduces a name it asks about.
            case found
            /// Just before the reader's place.
            case recent
        }
        public var passage: Passage
        public var kind: Kind
    }

    public var excerpts: [Excerpt]
    public var recaps: [ChapterRecap]
    /// The excerpts and summaries in reading order, grouped by chapter.
    public var text: String

    /// The excerpts `answer` draws on, best first, at most `count`: the passages the reader would
    /// look at to check it. Each excerpt (found or recent) scores the answer's words it shares,
    /// a word weighted by how few excerpts have it, and the question's own words at a quarter
    /// (every matched passage has those, so they say little about what the answer used). An
    /// excerpt needs two shared words that aren't the question's, and a third of the best score.
    /// An answer that shares nothing ("I can't tell from what you've read") cites nothing.
    public func citations(for answer: String, question: String, count: Int = 8) -> [Excerpt] {
        let answerWords = Set(PassageIndex.words(answer))
        let asked = Set(PassageIndex.words(question))
        guard !answerWords.isEmpty, !excerpts.isEmpty else { return [] }
        let excerptWords = excerpts.map { Set(PassageIndex.words($0.passage.text)) }
        var holding: [String: Int] = [:]
        for words in excerptWords {
            for word in words where answerWords.contains(word) { holding[word, default: 0] += 1 }
        }
        let total = Double(excerpts.count)
        var scored: [(index: Int, score: Double)] = []
        for (i, words) in excerptWords.enumerated() {
            let shared = words.intersection(answerWords)
            guard shared.subtracting(asked).count >= 2 else { continue }
            let score = shared.reduce(0.0) { sum, word in
                let weight = log(1 + total / Double(holding[word] ?? 1))
                return sum + (asked.contains(word) ? weight / 4 : weight)
            }
            scored.append((i, score))
        }
        guard let best = scored.map(\.score).max() else { return [] }
        // Pieces of one long paragraph share its range (a jump lands on the paragraph): cite it once.
        var seen = Set<Passage>()
        var result: [Excerpt] = []
        for entry in scored.filter({ $0.score >= best / 3 }).sorted(by: { $0.score > $1.score || ($0.score == $1.score && $0.index < $1.index) }) {
            let passage = excerpts[entry.index].passage
            let place = Passage(spineIndex: passage.spineIndex, range: passage.range, text: "")
            guard seen.insert(place).inserted else { continue }
            result.append(excerpts[entry.index])
            if result.count == count { break }
        }
        return result
    }
}

public enum AskContextBuilder {
    /// Builds the context for `terms` (the question's search words) within `budget` UTF-16 units:
    /// the passages just before the limit (about a fifth), passages that introduce or last mention
    /// each term and the best BM25 matches (about half), then chapter summaries, the latest
    /// chapters first, and more matches with whatever is left. 🔴 `recaps` past the index's limit
    /// are ignored (a summary made before the reader went back), so they can't leak.
    public static func build(index: PassageIndex, terms: [String], recaps: [ChapterRecap], limit: ReadingLimit,
                             budget: Int, chapterLabel: (Int) -> String) -> AskContext {
        var chosen: [Int: AskContext.Excerpt.Kind] = [:]
        var used = 0
        func indexCost(_ i: Int) -> Int { index.passages[i].text.utf16.count + 1 }
        func take(_ i: Int, as kind: AskContext.Excerpt.Kind, within cap: Int) -> Bool {
            guard chosen[i] == nil else { return true }
            let cost = indexCost(i)
            guard used + cost <= cap else { return false }
            chosen[i] = kind
            used += cost
            return true
        }

        // The reader's place: the last passages, newest first, up to a fifth.
        for i in index.passages.indices.reversed() {
            if !take(i, as: .recent, within: budget / 5) { break }
        }
        // Each term's introduction and latest appearance, then the best matches, up to seven tenths.
        let findCap = budget * 7 / 10
        for term in terms.prefix(6) {
            for i in index.firstMentions(of: term, count: 1) + index.lastMentions(of: term, count: 1) {
                _ = take(i, as: .found, within: findCap)
            }
        }
        let ranked = index.rank(terms, limit: 40)
        for i in ranked { _ = take(i, as: .found, within: findCap) }

        // Summaries of finished chapters, latest first, then more matches.
        var keptRecaps: [ChapterRecap] = []
        for recap in recaps.sorted(by: { $0.spineIndex > $1.spineIndex })
            where recap.spineIndex < limit.spineIndex && !recap.summary.isEmpty {
            let cost = recap.summary.utf16.count + chapterLabel(recap.spineIndex).utf16.count + 16
            guard used + cost <= budget else { continue }
            keptRecaps.append(recap)
            used += cost
        }
        for i in ranked { _ = take(i, as: .found, within: budget) }

        let excerpts = chosen.keys.sorted().map { AskContext.Excerpt(passage: index.passages[$0], kind: chosen[$0]!) }
        keptRecaps.sort { $0.spineIndex < $1.spineIndex }
        return AskContext(excerpts: excerpts, recaps: keptRecaps,
                          text: render(excerpts: excerpts, recaps: keptRecaps, chapterLabel: chapterLabel))
    }

    /// "## Chapter" headings in reading order; under each, its summary (if any) then its excerpts,
    /// gaps between non-adjacent excerpts marked with "…".
    static func render(excerpts: [AskContext.Excerpt], recaps: [ChapterRecap], chapterLabel: (Int) -> String) -> String {
        let spines = Set(excerpts.map(\.passage.spineIndex)).union(recaps.map(\.spineIndex)).sorted()
        var out: [String] = []
        for spine in spines {
            out.append("## " + chapterLabel(spine))
            if let recap = recaps.first(where: { $0.spineIndex == spine }) {
                out.append("Summary: " + recap.summary)
            }
            var lastEnd: Int?
            for excerpt in excerpts where excerpt.passage.spineIndex == spine {
                if let lastEnd, excerpt.passage.range.lowerBound > lastEnd + 1 { out.append("…") }
                out.append(excerpt.passage.text)
                lastEnd = excerpt.passage.range.upperBound
            }
        }
        return out.joined(separator: "\n")
    }
}

/// How a finished chapter is summarised in pieces small enough for the on-device model: its text
/// in parts of at most `maxLength` UTF-16 units, cut between passages.
public enum RecapPlan {
    public static func parts(of chapter: Chapter, spineIndex: Int, maxLength: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for passage in ReadSoFar.passages(of: chapter, spineIndex: spineIndex, targetLength: min(700, maxLength / 2)) {
            if !current.isEmpty, current.utf16.count + passage.text.utf16.count + 1 > maxLength {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + passage.text
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// A key that changes when the chapter's converted text does (a new edition of the file), so a
    /// stale summary is made again rather than used.
    public static func key(of chapter: Chapter, spineIndex: Int) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for block in chapter.blocks.prefix(40) {
            for unit in block.text.utf16.prefix(200) {
                hash ^= UInt64(unit)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return "\(spineIndex)-\(chapter.textLength)-\(String(hash, radix: 16))"
    }
}
