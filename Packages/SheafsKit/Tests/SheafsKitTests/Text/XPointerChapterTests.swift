import Foundation
import SheafsKit
import Testing

/// `XPointer` parsing and serialization, and how pointers find blocks of a converted chapter.
@Suite("XPointer and chapter lookup")
struct XPointerChapterTests {
    @Test("parse and serialize round trips")
    func roundTrips() throws {
        let simple = try #require(XPointer(parsing: "/body/DocFragment[12]/body/div/p[3]/text().0"))
        #expect(simple.spineIndex == 11)
        #expect(simple.elementPath == "/body/div/p[3]")
        #expect(simple.textNodeIndex == 1)
        #expect(simple.characterOffset == 0)
        #expect(simple.serialized == "/body/DocFragment[12]/body/div/p[3]/text().0")

        let indexed = try #require(XPointer(parsing: "/body/DocFragment[7]/body/section[1]/p[44]/text()[2].186"))
        #expect(indexed.spineIndex == 6)
        #expect(indexed.elementPath == "/body/section[1]/p[44]")
        #expect(indexed.textNodeIndex == 2)
        #expect(indexed.characterOffset == 186)
        #expect(indexed.serialized == "/body/DocFragment[7]/body/section[1]/p[44]/text()[2].186")

        let bare = try #require(XPointer(parsing: "/body/DocFragment/body/p[2]"))
        #expect(bare.spineIndex == 0)
        #expect(bare.elementPath == "/body/p[2]")
        #expect(bare.textNodeIndex == nil && bare.characterOffset == nil)
        #expect(bare.serialized == "/body/DocFragment[1]/body/p[2]")

        for string in [simple.serialized, indexed.serialized, bare.serialized] {
            #expect(XPointer(parsing: string)?.serialized == string)
        }
        #expect(XPointer(parsing: "/html/body/p") == nil)
        #expect(XPointer(parsing: "/body/DocFragment[0]/body/p") == nil)
    }

    @Test("sampled alice paragraphs are found by exact, indexless and deeper pointers")
    func aliceLookup() throws {
        let reference = try ChapterReference.load()
        let documents = try #require(reference.epubs["alice-epub3.epub"]).documents
        var checked = 0
        for document in documents where !document.samples.isEmpty {
            let chapter = XHTMLConverter().convert(try TextFixture.entry(document.path, in: "alice-epub3.epub"))
            for sample in document.samples where !sample.text.isEmpty {
                let pointer = XPointer(spineIndex: document.spineIndex, elementPath: sample.path)
                let exact = try #require(chapter.block(atElementPath: pointer.elementPath), "\(sample.path)")
                #expect(TextTesting.lastStep(of: exact.elementPath) == TextTesting.lastStep(of: sample.path))

                // A pointer into an inline child (".../p[3]/span[1]") resolves to the same block.
                let deeper = chapter.block(nearestElementPath: pointer.elementPath + "/span[1]")
                #expect(deeper?.id == exact.id, "nearest for \(sample.path)")
                let deepest = chapter.block(nearestElementPath: pointer.elementPath + "/span[2]/i[1]")
                #expect(deepest?.id == exact.id)

                // An omitted index on a sole sibling means [1]: ".../div/p[3]" matches ".../div[1]/p[3]".
                let indexless = sample.path.replacingOccurrences(of: "div[1]", with: "div")
                    .replacingOccurrences(of: "section[1]", with: "section")
                #expect(chapter.block(atElementPath: indexless)?.id == exact.id, "indexless \(indexless)")

                // And through a full serialized pointer.
                let parsed = try #require(XPointer(parsing: pointer.serialized + "/text().0"))
                #expect(parsed.spineIndex == document.spineIndex)
                #expect(chapter.block(atElementPath: parsed.elementPath)?.id == exact.id)
                checked += 1
            }
        }
        #expect(checked > 30, "only \(checked) sampled paragraphs were checked")
    }

    @Test("lookup is tolerant of indexes, case and prefixes")
    func tolerantLookup() throws {
        let chapter = TextTesting.convert("<div><p>one</p><p>two</p></div><div><p>three</p></div>")
        #expect(chapter.block(atElementPath: "/body/div/p[2]")?.text == "two")
        #expect(chapter.block(atElementPath: "/body/div[1]/p[2]")?.text == "two")
        #expect(chapter.block(atElementPath: "/BODY/DIV[2]/P")?.text == "three")
        #expect(chapter.block(atElementPath: "/body/xhtml:div[2]/p[1]")?.text == "three")
        #expect(chapter.block(atElementPath: "/body/div[3]/p[1]") == nil)
        #expect(chapter.block(nearestElementPath: "/body/div[2]/p[1]/b[1]/i[2]")?.text == "three")
        #expect(chapter.block(nearestElementPath: "/body/div[1]/table[1]/tr[1]") == nil)
    }
}
