import Foundation
import Testing
@testable import SheafsKit

/// The reading companion's lookup: nothing past the reader's place reaches the model, names and
/// words find the passages that matter, and the context keeps to its budget.
@Suite("Reading companion")
struct CompanionTests {
    private static let converter = XHTMLConverter()

    private static func chapter(_ paragraphs: [String], heading: String? = nil) -> Chapter {
        let body = (heading.map { "<h2>\($0)</h2>" } ?? "") + paragraphs.map { "<p>\($0)</p>" }.joined()
        return converter.convert("<html><body>\(body)</body></html>")
    }

    private static let book: [Chapter] = [
        chapter([
            "The hobbits came at last to the inn at Bree, tired and wet.",
            "In a corner sat a strange-looking weather-beaten man. Strider, said the innkeeper, was his name among the Rangers.",
            "Frodo watched Strider for a long time across the room.",
        ], heading: "At the Sign of the Prancing Pony"),
        chapter([
            "They rode south toward Minas Tirith under a dark sky.",
            "Gandalf spoke little. Then he turned to Pippin and smiled.",
            "Beyond the river lay Minas Tirith, white and silent.",
        ], heading: "Minas Tirith"),
        chapter([
            "SPOILER-ONE: here the reader has not been yet.",
            "Strider was crowned SPOILER-TWO in the city.",
        ], heading: "The Steward and the King"),
    ]

    @Test("🔴 no passage holds text at or after the limit, in this chapter or a later one")
    func spoilerWall() {
        // The limit falls inside chapter 2's second paragraph ("Gandalf spoke little. Then he…").
        let second = Self.book[1].blocks[2]
        let limit = ReadingLimit(spineIndex: 1, textOffset: second.textOffset + 22)
        let passages = ReadSoFar.passages(chapters: Self.book, limit: limit, targetLength: 60)
        let all = passages.map(\.text).joined(separator: "\n")
        #expect(!all.contains("SPOILER"))
        #expect(!all.contains("Pippin"))
        #expect(!all.contains("white and silent"))
        #expect(all.contains("Gandalf spoke little."))
        #expect(all.contains("Frodo watched Strider"))
        for passage in passages {
            #expect(limit.admits(spineIndex: passage.spineIndex, offset: passage.range.lowerBound))
            if passage.spineIndex == limit.spineIndex { #expect(passage.range.upperBound <= limit.textOffset) }
        }
    }

    @Test("a limit at the start of a chapter leaves all of that chapter out")
    func limitAtChapterStart() {
        let passages = ReadSoFar.passages(chapters: Self.book, limit: ReadingLimit(spineIndex: 2, textOffset: 0))
        #expect(passages.allSatisfy { $0.spineIndex < 2 })
        #expect(!passages.isEmpty)
    }

    @Test("🔴 a real book cut mid-chapter: every passage starts before the limit and the text after it is absent")
    func fixtureBook() throws {
        let epub = try EPUBBook(url: TextFixture.epubURL("alice-epub3.epub"))
        let chapters = try epub.spine.map { Self.converter.convert(try epub.data(for: $0.item)) }
        let spine = try #require(chapters.indices.first { chapters[$0].textLength > 8000 })
        let limit = ReadingLimit(spineIndex: spine, textOffset: chapters[spine].textLength / 2)
        let passages = ReadSoFar.passages(chapters: chapters, limit: limit)
        #expect(passages.allSatisfy { $0.spineIndex <= spine })
        let lastBlock = try #require(chapters[spine].blocks.last { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(lastBlock.textOffset > limit.textOffset)
        let tail = String(lastBlock.text.prefix(60)).trimmingCharacters(in: .whitespaces)
        #expect(!passages.filter { $0.spineIndex == spine }.contains { $0.text.contains(tail) })
        for passage in passages where passage.spineIndex == spine {
            #expect(passage.range.upperBound <= limit.textOffset)
        }
    }

    @Test("passages keep near the target length and long paragraphs split at sentences")
    func passageLengths() {
        let long = Array(repeating: "Sam carried the Ring up the mountain.", count: 60).joined(separator: " ")
        let passages = ReadSoFar.passages(of: Self.chapter([long]), spineIndex: 0, targetLength: 300)
        #expect(passages.count > 3)
        #expect(passages.allSatisfy { $0.text.count <= 460 })
        #expect(passages.allSatisfy { $0.text.hasSuffix(".") })
    }

    @Test("search words fold case and accents and drop possessives, plurals and stop words")
    func words() {
        #expect(PassageIndex.words("Who is Théoden's heir?") == ["theoden", "heir"])
        #expect(PassageIndex.words("the Hobbits of the Shire") == ["hobbit", "shire"])
    }

    @Test("names are capitalised mid-sentence; sentence-initial words are not")
    func names() {
        let index = PassageIndex(passages: ReadSoFar.passages(chapters: Self.book, limit: ReadingLimit(spineIndex: 2, textOffset: 0)))
        #expect(index.names["Strider"] != nil)
        #expect(index.names["Minas Tirith"] != nil)
        #expect(index.names["Then"] == nil)
        #expect(index.names["The"] == nil)
    }

    @Test("terms a model suggests are kept only when the text so far has them")
    func presentTerms() {
        let index = PassageIndex(passages: ReadSoFar.passages(chapters: Self.book, limit: ReadingLimit(spineIndex: 2, textOffset: 0)))
        #expect(index.presentTerms(["Strider", "Elessar", "Minas Tirith", "strider"]) == ["Strider", "Minas Tirith"])
    }

    @Test("ranking and first mentions find the passage that introduces a name")
    func lookup() throws {
        let passages = ReadSoFar.passages(chapters: Self.book, limit: ReadingLimit(spineIndex: 2, textOffset: 0), targetLength: 40)
        let index = PassageIndex(passages: passages)
        let first = try #require(index.firstMentions(of: "Strider", count: 1).first)
        #expect(index.passages[first].text.contains("innkeeper"))
        let best = index.rank(["Strider"], limit: 5)
        #expect(!best.isEmpty)
        #expect(best.allSatisfy { index.passages[$0].text.contains("Strider") })
        #expect(index.rank(["Mordor"], limit: 5).isEmpty)
    }

    @Test("🔴 the context keeps to its budget and leaves out summaries of chapters past the limit")
    func contextBudget() {
        let limit = ReadingLimit(spineIndex: 2, textOffset: 0)
        let index = PassageIndex(passages: ReadSoFar.passages(chapters: Self.book, limit: limit, targetLength: 40))
        let recaps = [
            ChapterRecap(spineIndex: 0, summary: "The hobbits reach Bree and meet Strider."),
            ChapterRecap(spineIndex: 2, summary: "SPOILER-RECAP"),
        ]
        let context = AskContextBuilder.build(index: index, terms: ["Strider"], recaps: recaps, limit: limit,
                                              budget: 400, chapterLabel: { "Chapter \($0 + 1)" })
        #expect(!context.text.contains("SPOILER"))
        #expect(context.excerpts.reduce(0) { $0 + $1.passage.text.utf16.count + 1 }
            + context.recaps.reduce(0) { $0 + $1.summary.utf16.count + 24 } <= 400)
        #expect(context.excerpts.contains { $0.kind == .recent })
        #expect(context.excerpts.contains { $0.kind == .found && $0.passage.text.contains("Strider") })
        #expect(context.text.hasPrefix("## Chapter 1"))
    }

    @Test("recap parts cover the chapter within the size limit")
    func recapParts() {
        let paragraphs = (1 ... 40).map { "Paragraph \($0) tells of the long road and the people met upon it." }
        let chapter = Self.chapter(paragraphs)
        let parts = RecapPlan.parts(of: chapter, spineIndex: 0, maxLength: 500)
        #expect(parts.count > 4)
        #expect(parts.allSatisfy { $0.utf16.count <= 500 })
        #expect(parts.joined(separator: "\n").contains("Paragraph 40 tells"))
        #expect(RecapPlan.key(of: chapter, spineIndex: 3) == RecapPlan.key(of: chapter, spineIndex: 3))
        #expect(RecapPlan.key(of: chapter, spineIndex: 3) != RecapPlan.key(of: Self.chapter(["Other text."]), spineIndex: 3))
    }
}
