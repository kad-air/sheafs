import Foundation

/// Looks passages up by the words of a question (BM25), and knows the names the text uses, so the
/// reading companion can hand a small model the few paragraphs that matter out of a whole book.
/// Built once per reading limit, off the main actor (a long book's read part takes well under a second).
public struct PassageIndex: Sendable {
    public let passages: [Passage]
    private let terms: [[String: Int]]
    private let lengths: [Int]
    private let documentFrequency: [String: Int]
    private let averageLength: Double
    /// Proper names (a word or two, capitalised mid-sentence somewhere) → how often they occur.
    public let names: [String: Int]

    public init(passages: [Passage]) {
        self.passages = passages
        var terms: [[String: Int]] = []
        var lengths: [Int] = []
        var frequency: [String: Int] = [:]
        terms.reserveCapacity(passages.count)
        for passage in passages {
            var counts: [String: Int] = [:]
            let words = Self.words(passage.text)
            for word in words { counts[word, default: 0] += 1 }
            for word in counts.keys { frequency[word, default: 0] += 1 }
            terms.append(counts)
            lengths.append(words.count)
        }
        self.terms = terms
        self.lengths = lengths
        documentFrequency = frequency
        averageLength = lengths.isEmpty ? 1 : max(1, Double(lengths.reduce(0, +)) / Double(lengths.count))
        names = NameFinder.names(in: passages.map(\.text))
    }

    /// The `count` most frequent names, most frequent first (ties alphabetically, so it's stable).
    public func topNames(_ count: Int) -> [String] {
        names.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(count).map(\.key)
    }

    /// The terms (words or phrases) of which every word occurs somewhere in the passages: what a
    /// model's suggested search words are cut down to, so a name it knows from elsewhere (a later
    /// title, a name not met yet) never steers the lookup.
    public func presentTerms(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        return candidates.filter { term in
            let words = Self.words(term)
            guard !words.isEmpty, words.allSatisfy({ documentFrequency[$0] != nil }) else { return false }
            return seen.insert(words.joined(separator: " ")).inserted
        }
    }

    /// Passage indices by BM25 score for `query` (its words; repeated words weigh more), best first,
    /// zero scores left out.
    public func rank(_ query: [String], limit: Int) -> [Int] {
        var weights: [String: Double] = [:]
        for term in query {
            for word in Self.words(term) { weights[word, default: 0] += 1 }
        }
        guard !weights.isEmpty else { return [] }
        let n = Double(passages.count)
        let k1 = 1.2, b = 0.75
        var scored: [(Int, Double)] = []
        for (index, counts) in terms.enumerated() {
            var score = 0.0
            for (word, weight) in weights {
                guard let tf = counts[word].map(Double.init), let df = documentFrequency[word].map(Double.init) else { continue }
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let norm = tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(lengths[index]) / averageLength))
                score += weight * idf * norm
            }
            if score > 0 { scored.append((index, score)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.prefix(limit).map(\.0)
    }

    /// The first `count` passages (in reading order) holding every word of `term`: where a
    /// character or place is introduced, which is what "who is…" needs.
    public func firstMentions(of term: String, count: Int) -> [Int] {
        let words = Self.words(term)
        guard !words.isEmpty else { return [] }
        var found: [Int] = []
        for (index, counts) in terms.enumerated() where words.allSatisfy({ counts[$0] != nil }) {
            found.append(index)
            if found.count == count { break }
        }
        return found
    }

    /// The last `count` passages holding every word of `term`: where it was last seen.
    public func lastMentions(of term: String, count: Int) -> [Int] {
        let words = Self.words(term)
        guard !words.isEmpty else { return [] }
        var found: [Int] = []
        for index in terms.indices.reversed() where words.allSatisfy({ terms[index][$0] != nil }) {
            found.append(index)
            if found.count == count { break }
        }
        return found.reversed()
    }

    /// Search words: case and diacritics folded (Théoden = Theoden), split at anything that is not
    /// a letter or digit, possessive and plural "s" dropped, stop words and single letters left out.
    public static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result: [String] = []
        var current = ""
        func finish() {
            defer { current = "" }
            guard current.count > 1, !stopWords.contains(current) else { return }
            result.append(stem(current))
        }
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                finish()
            }
        }
        finish()
        return result
    }

    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    static let stopWords: Set<String> = [
        "a", "about", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at", "be", "been", "before",
        "being", "but", "by", "can", "could", "did", "do", "does", "doing", "done", "for", "from", "had", "has", "have",
        "he", "her", "here", "him", "his", "how", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not", "now",
        "of", "on", "or", "our", "out", "she", "so", "some", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "those", "to", "up", "upon", "us", "was", "we", "were", "what", "when", "where", "which",
        "while", "who", "whom", "why", "will", "with", "would", "you", "your", "happen", "happened", "happens", "tell",
        "story", "book", "chapter", "far", "going", "know", "remind", "explain", "said", "say",
    ]
}

/// Proper names in running text: words written with a capital where a sentence does not start
/// (so "Gandalf" counts and "Then" doesn't), each counted wherever it appears capitalised, plus
/// two-word names ("Minas Tirith") seen at least twice.
enum NameFinder {
    static func names(in texts: [String]) -> [String: Int] {
        var midSentence = Set<String>()
        var counts: [String: Int] = [:]
        var pairs: [String: Int] = [:]
        for text in texts {
            for line in text.split(whereSeparator: \.isNewline) {
                var sentenceStart = true
                var previous: String?
                for raw in line.split(whereSeparator: \.isWhitespace) {
                    let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                    let stripped = word.hasSuffix("’s") || word.hasSuffix("'s") ? String(word.dropLast(2)) : word
                    let capitalised = stripped.count > 1 && (stripped.first?.isUppercase ?? false)
                        && stripped.dropFirst().contains(where: \.isLowercase)
                    if capitalised, !commonCapitals.contains(stripped) {
                        counts[stripped, default: 0] += 1
                        if !sentenceStart { midSentence.insert(stripped) }
                        if let previous, !sentenceStart { pairs[previous + " " + stripped, default: 0] += 1 }
                        previous = stripped
                    } else {
                        previous = nil
                    }
                    // A word that ends a sentence, or an opening quote, starts the next one.
                    let last = raw.last.map { String($0) } ?? ""
                    let ending = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"”’'»)]"))
                    sentenceStart = ending.hasSuffix(".") || ending.hasSuffix("!") || ending.hasSuffix("?")
                        || ending.hasSuffix(":") || ending.hasSuffix("…") || last == "“"
                    if sentenceStart || raw.hasSuffix(",") || raw.hasSuffix(";") { previous = nil }
                }
            }
        }
        var result: [String: Int] = [:]
        for (name, count) in counts where midSentence.contains(name) && count >= 2 { result[name] = count }
        for (pair, count) in pairs where count >= 2 { result[pair] = count }
        return result
    }

    /// Capitalised mid-sentence for reasons other than being a name.
    static let commonCapitals: Set<String> = [
        "I", "I’m", "I'm", "I’ll", "I'll", "I’d", "I'd", "I’ve", "I've", "Mr", "Mrs", "Ms", "Dr", "Sir", "Lady", "Lord",
        "The", "A", "An", "And", "But", "Or", "Of", "In", "On", "To", "It", "He", "She", "They", "We", "You", "My",
        "Chapter", "Book", "Part", "Oh", "O", "Yes", "No", "Well",
    ]
}
