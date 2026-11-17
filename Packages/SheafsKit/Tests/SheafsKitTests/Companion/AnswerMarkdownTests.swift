import Foundation
import Testing
@testable import SheafsKit

/// Ask's answers come back in markdown and the pane draws it (`AnswerMarkdown`): emphasis, lists and
/// paragraphs, and an answer still streaming in never shows a mark raw that later turns into style.
@Suite("Answer markdown")
struct AnswerMarkdownTests {
    typealias Run = AnswerMarkdown.Run
    typealias Block = AnswerMarkdown.Block

    /// Apple's on-device model's real answer (iPhone Duo simulator, Alice at 30 %, asked for "a
    /// numbered list with the names in bold"), as the app printed it: the shape answers come in.
    static let modelAnswer = """
    1. **Dinah** – Alice mentioned her cat Dinah, who she wished would be with her as she fell down the rabbit-hole; she also expressed wishing to see her again while talking to the Mouse.

    2. **White Rabbit** – The White Rabbit, with pink eyes, ran past Alice while she sat bored; she followed him down the rabbit-hole, and later he returned in a hurry, demanding gloves and a fan.

    3. **Mouse** – Alice met the Mouse while swimming in a pool of her own tears; they tried to avoid cats and dogs, and the Mouse began telling a sad tale about Fury and a mouse.

    4. **Caterpillar** – A large blue caterpillar was sitting on a mushroom; Alice spoke to it, and it asked who she was, giving her advice about keeping her temper.
    """

    /// Its answer to "Summarise what has happened so far as bullet points, with a few key words in
    /// italics" (the first three of eight bullets).
    static let modelBullets = """
    - Alice sat by her sister, bored, when a *White Rabbit* with pink eyes ran past and took a watch from its waistcoat-pocket, prompting her to follow it down a *rabbit-hole*.
    - She fell into a deep well filled with *cupboards* and *shelves*, found an empty jar of *orange marmalade*, and later discovered a *three-legged glass table* with a golden key.
    - Alice used the key to open a small door, entering a *garden* but unable to fit through, wishing she could *shut up like a telescope*.
    """

    /// Everything the pane handles in one answer: a heading, a paragraph with a line break, nested
    /// bullets, a numbered list, a quote, a rule, inline code and every emphasis.
    static let mixed = """
    ## Who Alice has met

    So far Alice has met *several* creatures.
    Each of them **puzzles** her.

    - The **White Rabbit**, always late
      - first by the *riverbank*
      - then in the hall
    - The ***Caterpillar*** on a mushroom
    * The Mouse, in the `pool of tears`

    1. She falls down the hole.
    2) She __shrinks__ and _grows_.

    > Curiouser and curiouser!

    ---
    That is all, so far.
    """

    @Test("emphasis: bold, italic, both, underscores, code; marks gone")
    func inline() {
        #expect(AnswerMarkdown.runs("a **bold** b") == [Run("a "), Run("bold", bold: true), Run(" b")])
        #expect(AnswerMarkdown.runs("an *italic* word") == [Run("an "), Run("italic", italic: true), Run(" word")])
        #expect(AnswerMarkdown.runs("***both***") == [Run("both", bold: true, italic: true)])
        #expect(AnswerMarkdown.runs("__bold__ and _it_") == [Run("bold", bold: true), Run(" and "), Run("it", italic: true)])
        #expect(AnswerMarkdown.runs("say `Drink Me` twice") == [Run("say "), Run("Drink Me", code: true), Run(" twice")])
        // Nested either way, and `***` closing an italic inside a bold.
        #expect(AnswerMarkdown.runs("*a **b** c*") == [Run("a ", italic: true), Run("b", bold: true, italic: true), Run(" c", italic: true)])
        #expect(AnswerMarkdown.runs("**bold *and italic***") == [Run("bold ", bold: true), Run("and italic", bold: true, italic: true)])
        // Bold across the line break inside a paragraph.
        #expect(AnswerMarkdown.runs("**two\nlines**") == [Run("two\nlines", bold: true)])
        // A name in quotes, italicised: the curly quotes are inside the marks.
        #expect(AnswerMarkdown.runs("*“Off with her head!”*") == [Run("“Off with her head!”", italic: true)])
    }

    @Test("marks that aren't emphasis stay as typed")
    func literalMarks() {
        #expect(AnswerMarkdown.runs("5 * 3 = 15") == [Run("5 * 3 = 15")])
        #expect(AnswerMarkdown.runs("snake_case_name") == [Run("snake_case_name")])
        #expect(AnswerMarkdown.runs("an **unclosed bold") == [Run("an **unclosed bold")])
        #expect(AnswerMarkdown.runs("a lone * star") == [Run("a lone * star")])
        #expect(AnswerMarkdown.runs(#"not \*emphasis\*"#) == [Run("not *emphasis*")])
        #expect(AnswerMarkdown.runs("****") == [Run("****")])
        #expect(AnswerMarkdown.runs("`*code*`") == [Run("*code*", code: true)])
    }

    @Test("the model's numbered answer: one item per number, the names bold, no marks left")
    func modelAnswer() {
        let blocks = AnswerMarkdown.parse(Self.modelAnswer)
        #expect(blocks.count == 4)
        let names = ["Dinah", "White Rabbit", "Mouse", "Caterpillar"]
        for (number, (block, name)) in zip(blocks, names).enumerated() {
            guard case .item(let marker, let ordered, let depth, let runs) = block else {
                Issue.record("block \(number) is \(block)")
                continue
            }
            #expect(marker == "\(number + 1).")
            #expect(ordered && depth == 0)
            #expect(runs.first == Run(name, bold: true))
            #expect(runs.dropFirst().allSatisfy { !$0.bold && !$0.italic })
            #expect(!block.text.contains("*"))
            #expect(block.text.hasPrefix("\(name) – "))
        }

        let bullets = AnswerMarkdown.parse(Self.modelBullets)
        #expect(bullets.count == 3)
        #expect(bullets.allSatisfy { if case .item("•", false, 0, _) = $0 { true } else { false } })
        #expect(bullets.allSatisfy { !$0.text.contains("*") && !$0.text.hasPrefix("-") })
        #expect(bullets[0].runs.filter(\.italic).map(\.text) == ["White Rabbit", "rabbit-hole"])
        #expect(bullets[1].runs.filter(\.italic).map(\.text) == ["cupboards", "shelves", "orange marmalade", "three-legged glass table"])
        #expect(bullets[2].text.hasSuffix("wishing she could shut up like a telescope."))
    }

    @Test("blocks: heading, paragraphs and line breaks, nested bullets, numbers, quote, rule")
    func blocks() {
        let blocks = AnswerMarkdown.parse(Self.mixed)
        let expected: [Block] = [
            .heading(level: 2, [Run("Who Alice has met")]),
            .paragraph([Run("So far Alice has met "), Run("several", italic: true), Run(" creatures.\nEach of them "),
                        Run("puzzles", bold: true), Run(" her.")]),
            .item(marker: "•", ordered: false, depth: 0, [Run("The "), Run("White Rabbit", bold: true), Run(", always late")]),
            .item(marker: "•", ordered: false, depth: 1, [Run("first by the "), Run("riverbank", italic: true)]),
            .item(marker: "•", ordered: false, depth: 1, [Run("then in the hall")]),
            .item(marker: "•", ordered: false, depth: 0, [Run("The "), Run("Caterpillar", bold: true, italic: true), Run(" on a mushroom")]),
            .item(marker: "•", ordered: false, depth: 0, [Run("The Mouse, in the "), Run("pool of tears", code: true)]),
            .item(marker: "1.", ordered: true, depth: 0, [Run("She falls down the hole.")]),
            .item(marker: "2)", ordered: true, depth: 0, [Run("She "), Run("shrinks", bold: true), Run(" and "), Run("grows", italic: true), Run(".")]),
            .quote([Run("Curiouser and curiouser!")]),
            .paragraph([Run("That is all, so far.")]),
        ]
        #expect(blocks.count == expected.count)
        for (got, want) in zip(blocks, expected) { #expect(got == want) }
    }

    @Test("a list right after a paragraph, a lazy continuation, an indented paragraph in an item")
    func listEdges() {
        let blocks = AnswerMarkdown.parse("""
        Alice has met:
        - the Rabbit,
        who is late
        • the Duchess

          who sneezes
        Done.
        """)
        #expect(blocks == [
            .paragraph([Run("Alice has met:")]),
            .item(marker: "•", ordered: false, depth: 0, [Run("the Rabbit,\nwho is late")]),
            .item(marker: "•", ordered: false, depth: 0, [Run("the Duchess\nwho sneezes\nDone.")]),
        ])
        // Plain text is one paragraph per blank-line gap, as before.
        #expect(AnswerMarkdown.parse("One.\n\n\nTwo.") == [.paragraph([Run("One.")]), .paragraph([Run("Two.")])])
        #expect(AnswerMarkdown.parse("") == [])
        #expect(AnswerMarkdown.parse("\n\n") == [])
    }

    /// 🔴 An answer streams in a few characters at a time. For EVERY prefix of it, what the pane
    /// shows must be the start of what the finished answer shows, character for character and in
    /// the same style and block: no "**" shown raw and then turned bold, no "1" shown as a paragraph
    /// that then becomes a numbered item, no "-" then a bullet.
    @Test("🔴 streaming: every prefix shows the start of the finished answer, in its final style")
    func streaming() {
        for answer in [Self.modelAnswer, Self.modelBullets, Self.mixed] {
            let final = Self.flatten(AnswerMarkdown.parse(answer))
            let characters = Array(answer)
            for end in 0 ... characters.count {
                let prefix = String(characters[..<end])
                let shown = Self.flatten(AnswerMarkdown.parse(prefix, streaming: true))
                let ok = shown.count <= final.count && zip(shown, final).allSatisfy { $0 == $1 }
                #expect(ok, "prefix \(end): \(prefix.suffix(30).debugDescription) shows \(Self.describe(shown.suffix(20)))")
                if !ok { break }
            }
            // Once it has all arrived, streaming or not makes no difference.
            #expect(AnswerMarkdown.parse(answer, streaming: true) == AnswerMarkdown.parse(answer))
        }
    }

    @Test("streaming: an open emphasis styles what has come, a mark at the very end waits")
    func streamingEnds() {
        #expect(AnswerMarkdown.parse("The **White Rab", streaming: true) == [.paragraph([Run("The "), Run("White Rab", bold: true)])])
        #expect(AnswerMarkdown.parse("The **", streaming: true) == [.paragraph([Run("The ")])])
        #expect(AnswerMarkdown.parse("The *", streaming: true) == [.paragraph([Run("The ")])])
        #expect(AnswerMarkdown.parse("The **White Rabbit*", streaming: true) == [.paragraph([Run("The "), Run("White Rabbit", bold: true)])])
        #expect(AnswerMarkdown.parse("Say `Drink", streaming: true) == [.paragraph([Run("Say "), Run("Drink", code: true)])])
        #expect(AnswerMarkdown.parse("Met:\n1", streaming: true) == [.paragraph([Run("Met:")])])
        #expect(AnswerMarkdown.parse("Met:\n12.", streaming: true) == [.paragraph([Run("Met:")])])
        #expect(AnswerMarkdown.parse("Met:\n-", streaming: true) == [.paragraph([Run("Met:")])])
        // The bullet comes with its first word, never as an empty dot.
        #expect(AnswerMarkdown.parse("Met:\n- ", streaming: true) == [.paragraph([Run("Met:")])])
        #expect(AnswerMarkdown.parse("Met:\n- T", streaming: true) == [.paragraph([Run("Met:")]), .item(marker: "•", ordered: false, depth: 0, [Run("T")])])
        #expect(AnswerMarkdown.parse("Met:\n--", streaming: true) == [.paragraph([Run("Met:")])])
        // Finished, the same unclosed marks are text.
        #expect(AnswerMarkdown.parse("The **White Rab") == [.paragraph([Run("The **White Rab")])])
        #expect(AnswerMarkdown.parse("Met:\n1") == [.paragraph([Run("Met:\n1")])])
    }

    /// The answer as the pane draws it, one entry per character: the character, its style and
    /// which block (and kind of block) it is in; block boundaries are entries too.
    struct Shown: Equatable {
        var character: Character
        var bold = false, italic = false, code = false
        var block = 0
        var kind = ""
    }

    static func flatten(_ blocks: [Block]) -> [Shown] {
        var out: [Shown] = []
        for (index, block) in blocks.enumerated() {
            let kind: String = switch block {
            case .paragraph: "p"
            case .heading(let level, _): "h\(level)"
            case .item(let marker, _, let depth, _): "item \(marker) \(depth)"
            case .quote: "quote"
            }
            out.append(Shown(character: "¶", block: index, kind: kind))
            for run in block.runs {
                for character in run.text {
                    out.append(Shown(character: character, bold: run.bold, italic: run.italic, code: run.code, block: index, kind: kind))
                }
            }
        }
        return out
    }

    static func describe(_ shown: ArraySlice<Shown>) -> String {
        shown.map { "\($0.character)\($0.bold ? "B" : "")\($0.italic ? "I" : "")" }.joined()
    }
}
