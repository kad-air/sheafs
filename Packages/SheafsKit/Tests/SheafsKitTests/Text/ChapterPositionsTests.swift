import Foundation
import Testing
import SheafsKit

/// Offsets saved before a stylesheet hid part of a chapter are put right through the pointers
/// saved with them; offsets that still hold are left alone.
@Suite("Chapter positions and re-anchoring")
struct ChapterPositionsTests {
    typealias T = TextTesting

    static let body = """
        <div class="front"><p>Front matter that a stylesheet hides.</p></div>
        <p>Alpha beta gamma.</p><p>Delta epsilon zeta.</p>
        """
    /// As saved: converted without the stylesheet (before stylesheets were honoured).
    static let before = T.convert(body)
    /// As now: the stylesheet hides the front matter.
    static let after = T.convert(body, head: "<style>.front { display: none }</style>")

    /// Where `word` starts in a chapter's plain text (found independently of the code under test).
    static func start(of word: String, in chapter: Chapter) throws -> Int {
        let range = (chapter.plainText as NSString).range(of: word)
        try #require(range.location != NSNotFound)
        return range.location
    }

    @Test("the hiding stylesheet really moved the text")
    func premise() throws {
        #expect(Self.before.blockTexts.count == 3 && Self.after.blockTexts.count == 2)
        #expect(try Self.start(of: "epsilon", in: Self.before) != Self.start(of: "epsilon", in: Self.after))
        #expect(Self.before.text(in: 0 ..< Self.before.textLength) == Self.before.plainText)
        #expect(Self.before.text(in: 0 ..< Self.before.textLength + 1) == nil)
    }

    @Test("a highlight saved before follows its pointers to the same words")
    func highlight() throws {
        let old = try Self.start(of: "epsilon zeta", in: Self.before)
        let range = old ..< old + 12
        let startPointer = Self.before.pointer(at: range.lowerBound, spineIndex: 4).serialized
        let endPointer = Self.before.pointer(at: range.upperBound, spineIndex: 4).serialized
        // Unchanged chapter: nothing to do.
        #expect(Self.before.reanchoredRange(range, text: "epsilon zeta", startPointer: startPointer, endPointer: endPointer) == nil)
        // The text moved: the pointers find it.
        let new = try Self.start(of: "epsilon zeta", in: Self.after)
        #expect(Self.after.reanchoredRange(range, text: "epsilon zeta", startPointer: startPointer, endPointer: endPointer)
                == new ..< new + 12)
        // Neither the offsets nor the pointers hold the quoted text: left alone.
        #expect(Self.after.reanchoredRange(range, text: "nowhere", startPointer: startPointer, endPointer: endPointer) == nil)
        #expect(Self.after.reanchoredRange(range, text: "epsilon zeta", startPointer: nil, endPointer: endPointer) == nil)
    }

    @Test("a reading position saved before follows its pointer")
    func position() throws {
        let old = try Self.start(of: "Delta", in: Self.before) + 2
        let pointer = Self.before.pointer(at: old, spineIndex: 4).serialized
        #expect(Self.before.reanchoredOffset(old, pointer: pointer, spineIndex: 4) == nil)
        #expect(Self.after.reanchoredOffset(old, pointer: pointer, spineIndex: 4) == (try Self.start(of: "Delta", in: Self.after)) + 2)
        // A pointer for another chapter, or into what is hidden now, leaves the offset alone.
        #expect(Self.after.reanchoredOffset(old, pointer: pointer, spineIndex: 5) == nil)
        let hidden = Self.before.pointer(at: 3, spineIndex: 4).serialized
        #expect(hidden.contains("div[1]/p[1]"))
        #expect(Self.after.reanchoredOffset(3, pointer: hidden, spineIndex: 4) == nil)
        #expect(Self.after.reanchoredOffset(3, pointer: nil, spineIndex: 4) == nil)
    }
}
