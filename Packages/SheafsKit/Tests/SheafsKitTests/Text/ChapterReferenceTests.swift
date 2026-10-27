import Foundation
import SheafsKit
import Testing

/// Cross-checks the converter against `chapter-reference.json`, which Python's `html.parser`
/// produced from the same fixtures (see `scripts/gen_chapter_reference.py`).
@Suite("Chapter reference (second source)")
struct ChapterReferenceTests {
    @Test("the reference covers every spine document of all three fixtures")
    func referenceIsComplete() throws {
        let reference = try ChapterReference.load()
        #expect(reference.sampleStride == 37)
        // Known facts about the fixtures, independent of the generator: the number of XHTML/HTML
        // itemrefs in each spine, and the 900 identical <p> of the hub fixture.
        #expect(reference.epubs["alice-epub3.epub"]?.documents.count == 15)
        #expect(reference.epubs["pride-epub2.epub"]?.documents.count == 17)
        #expect(reference.epubs["hub-fixture.epub"]?.documents.count == 1)
        #expect(reference.epubs["hub-fixture.epub"]?.documents.first?.paragraphCount == 900)
        #expect(ChapterReference.cases.count == 33)
        // Alice chapter I: 26 paragraphs, all directly under div.chapter.
        let alice1 = try #require(reference.epubs["alice-epub3.epub"]?.documents.first {
            $0.path.hasSuffix("11-h-1.htm.xhtml")
        })
        #expect(alice1.paragraphCount == 26)
        #expect(alice1.samples.first?.path == "/body/div[1]/p[1]")
    }

    @Test("regenerating the reference is byte-identical to the committed file")
    func referenceIsUpToDate() throws {
        #if os(macOS)
        // This file lives at <repo>/Packages/SheafsKit/Tests/SheafsKitTests/Text/.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let script = root.appendingPathComponent("scripts/gen_chapter_reference.py")
        let committed = root.appendingPathComponent("Packages/SheafsKit/Tests/SheafsKitTests/Fixtures/chapter-reference.json")
        #expect(FileManager.default.fileExists(atPath: script.path), "missing \(script.path)")

        let regenerated = FileManager.default.temporaryDirectory
            .appendingPathComponent("chapter-reference-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: regenerated) }
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "-I", script.path, "--output", regenerated.path]
        python.standardOutput = FileHandle.nullDevice
        python.standardError = FileHandle.nullDevice
        try python.run()
        python.waitUntilExit()
        #expect(python.terminationStatus == 0, "gen_chapter_reference.py failed")
        let fresh = try Data(contentsOf: regenerated)
        #expect(fresh == (try Data(contentsOf: committed)), "chapter-reference.json is stale: rerun scripts/gen_chapter_reference.py")
        #else
        throw TextFixture.Failure(description: "regenerating the reference needs python3, run on macOS")
        #endif
    }

    /// Run with and without the fixtures' stylesheets: none of their rules hides anything, so the
    /// stylesheets must change neither a path nor a character.
    @Test("every <p> becomes a block with the reference path and text",
          arguments: ChapterReference.cases, [false, true])
    func paragraphsMatchReference(_ testCase: ChapterReference.Case, stylesheets: Bool) throws {
        let document = testCase.document
        let chapter = try TextTesting.convert(document.path, in: testCase.epub, stylesheets: stylesheets)

        // Paragraph count. A <p> yields one block per run of text between images, all sharing its
        // path, so count distinct paths. The converter drops <p> with no text (the page-number
        // anchors in the Gutenberg books), which the reference counts separately.
        let paragraphPaths = Set(chapter.blocks.map(\.elementPath).filter { TextTesting.lastStep(of: $0).hasPrefix("p[") })
        #expect(paragraphPaths.count == document.nonEmptyParagraphCount, "\(testCase.testDescription)")
        #expect(document.nonEmptyParagraphCount <= document.paragraphCount)

        // Sampled paragraphs: found by path, same text. Python joins the text nodes of a
        // paragraph with " ", so "text<i>x</i>" has a space the converter correctly does not
        // add. Compare with whitespace collapsed first; only where that differs compare with
        // all whitespace removed. The number of such cases is capped so a real word-spacing bug
        // cannot hide behind the fallback.
        var relaxedComparisons = 0
        for sample in document.samples {
            let block = chapter.block(atElementPath: sample.path)
            if sample.text.isEmpty {
                #expect(block == nil, "empty <p> \(sample.path) should produce no block")
                continue
            }
            let found = try #require(block, "no block at \(sample.path) in \(testCase.testDescription)")
            #expect(found.kind == .paragraph || found.kind == .blockquote, "\(sample.path)")
            let actual = TextTesting.normalizedWhitespace(found.text)
            if actual != sample.text {
                relaxedComparisons += 1
                #expect(
                    TextTesting.withoutWhitespace(actual) == TextTesting.withoutWhitespace(sample.text),
                    "text differs at \(sample.path) in \(testCase.testDescription)"
                )
            }
        }
        #expect(relaxedComparisons <= max(3, document.samples.count / 4), "\(relaxedComparisons) relaxed comparisons")
    }

    @Test("titles and element ids match the reference", arguments: ChapterReference.cases, [false, true])
    func titlesAndIdsMatchReference(_ testCase: ChapterReference.Case, stylesheets: Bool) throws {
        let chapter = try TextTesting.convert(testCase.document.path, in: testCase.epub, stylesheets: stylesheets)

        #expect(TextTesting.normalizedWhitespace(chapter.title ?? "") == (testCase.document.title ?? ""))
        #expect(Set(chapter.anchorOffsets.keys) == Set(testCase.document.ids), "\(testCase.testDescription)")
        for (id, offset) in chapter.anchorOffsets {
            #expect((0...chapter.textLength).contains(offset), "anchor \(id) at \(offset)")
        }
    }

    @Test("anchors that sit on a paragraph land on that paragraph's first character")
    func anchorsOnParagraphs() throws {
        // Alice chapter I carries the id "chap01" on an <a/> inside the first heading.
        let data = try TextFixture.entry("OEBPS/4040227324556390537_11-h-1.htm.xhtml", in: "alice-epub3.epub")
        let chapter = XHTMLConverter().convert(data)
        let heading = try #require(chapter.blocks.first)
        #expect(heading.kind == .heading(level: 2))
        #expect(heading.text == "CHAPTER I.\u{2028}Down the Rabbit-Hole")
        #expect(chapter.anchorOffsets["chap01"] == heading.textOffset)
        #expect(chapter.title.map(TextTesting.normalizedWhitespace) == "CHAPTER I. Down the Rabbit-Hole")
    }
}
