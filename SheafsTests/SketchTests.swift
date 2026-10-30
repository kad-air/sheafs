import Testing
import Foundation
import SwiftData
import UIKit
import PencilKit
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// Pencil markings: every control point is anchored to the chapter's text, so at the layout a
/// marking was drawn in it comes back exactly, and after a text-size change a circle is still
/// around its word, an underline under its words (cut where they now wrap), a margin note in its
/// margin with its shape, and a bracket beside a passage or a circle around one stretched over
/// wherever that passage now runs, larger or smaller; markings persist, die with their book, list
/// with the highlights in reading order and export with them.
@MainActor
struct SketchTests {
    static let textSize = BookmarkTests.layout.textSize
    /// What a page view of `BookmarkTests.layout` shows, in page coordinates.
    static let area = CGRect(x: -24, y: -PageLayout.headerHeight, width: textSize.width + 48,
                             height: textSize.height + PageLayout.headerHeight + PageLayout.footerHeight)

    static func stroke(_ points: [CGPoint], seed: UInt32 = 7) -> PKStroke {
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date(timeIntervalSinceReferenceDate: 0))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, transform: .identity, mask: nil, randomSeed: seed)
    }

    static func ellipse(around rect: CGRect, count: Int = 48) -> [CGPoint] {
        let box = rect.insetBy(dx: -5, dy: -4)
        return (0 ... count).map { step in
            let angle = Double(step) / Double(count) * 2 * .pi
            return CGPoint(x: box.midX + box.width / 2 * cos(angle), y: box.midY + box.height / 2 * sin(angle))
        }
    }

    static func mark(_ captured: (strokes: [PKStroke], anchors: [StrokeAnchors], covers: NSRange?), spine: Int) -> SketchMark {
        SketchMark(id: UUID(), spineIndex: spine, version: .now, drawing: PKDrawing(strokes: captured.strokes),
                   anchors: SketchAnchors(strokes: captured.anchors))
    }

    static func bounds(_ strokes: [SketchLayout.Placed]) -> CGRect {
        strokes.flatMap { $0.stroke.path.map(\.location) }.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    static func session(fontSize: Double = 19) async throws -> BookSession {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        var style = ReaderEngineTests.style
        style.fontSize = fontSize
        session.configure(style: style, textSize: textSize)
        return session
    }

    static func resize(_ session: BookSession, to fontSize: Double) {
        var style = ReaderEngineTests.style
        style.fontSize = fontSize
        session.configure(style: style, textSize: textSize)
    }

    /// A line of page 1 of chapter 2 with at least `minimum` characters of text.
    static func line(in chapter: PaginatedChapter, minimum: Int = 30, skip: Int = 2) throws -> TextLine {
        let lines = chapter.lines(onPage: 1).filter { $0.characters.length >= minimum }
        return try #require(lines.dropFirst(skip).first)
    }

    @Test func aMarkingComesBackExactlyAtTheLayoutItWasDrawnIn() async throws {
        let session = try await Self.session()
        let chapter = try #require(session.paginatedChapter(2))
        let line = try Self.line(in: chapter)
        let word = chapter.wordRange(at: line.characters.location + 8)
        let rect = try #require(chapter.rects(for: word, page: 1).first)
        let underline = Self.stroke([CGPoint(x: line.used.minX, y: line.baseline + 3), CGPoint(x: line.used.midX, y: line.baseline + 3.5),
                                     CGPoint(x: line.used.maxX, y: line.baseline + 3)], seed: 2)
        let note = Self.stroke([CGPoint(x: Self.textSize.width + 6, y: line.baseline - 10),
                                CGPoint(x: Self.textSize.width + 16, y: line.baseline + 2)], seed: 3)
        let strokes = [Self.stroke(Self.ellipse(around: rect)), underline, note]
        let captured = SketchLayout.capture(strokes, chapter: chapter, page: 1)
        #expect(captured.anchors.map(\.kind) == [.text, .text, .free])
        #expect(captured.anchors[2].edge == .trailing)
        let covers = try #require(captured.covers)
        #expect(NSLocationInRange(word.location, covers))

        let placed = SketchLayout.place([Self.mark(captured, spine: 2)], chapter: chapter, page: 1, area: Self.area)
        #expect(placed.count == 3)
        for (original, back) in zip(strokes, placed.sorted { $0.strokeIndex < $1.strokeIndex }) {
            let a = original.path.map(\.location), b = back.stroke.path.map(\.location)
            #expect(a.count == b.count)
            for (p, q) in zip(a, b) { #expect(hypot(p.x - q.x, p.y - q.y) < 0.01) }
            #expect(back.stroke.randomSeed == original.randomSeed)
        }
        // Nowhere else.
        #expect(SketchLayout.place([Self.mark(captured, spine: 2)], chapter: chapter, page: 0, area: Self.area).isEmpty)
        #expect(SketchLayout.place([Self.mark(captured, spine: 2)], chapter: chapter, page: 2, area: Self.area).isEmpty)
    }

    @Test func aCircleStaysAroundItsWordWhenTheTextGrows() async throws {
        let session = try await Self.session()
        let small = try #require(session.paginatedChapter(2))
        let line = try Self.line(in: small)
        let word = small.wordRange(at: line.characters.location + 8)
        let before = try #require(small.rects(for: word, page: 1).first)
        let mark = Self.mark(SketchLayout.capture([Self.stroke(Self.ellipse(around: before))], chapter: small, page: 1), spine: 2)

        Self.resize(session, to: 27)
        let large = try #require(session.paginatedChapter(2, anchor: small.range(ofPage: 0).location))
        let page = large.pageIndex(containing: word.location)
        let after = try #require(large.rects(for: word, page: page).first)
        #expect(after.width > before.width * 1.2)
        let placed = SketchLayout.place([mark], chapter: large, page: page, area: Self.area)
        let circle = Self.bounds(placed)
        #expect(circle.contains(after.insetBy(dx: 1, dy: 1)))
        // About as snug as it was drawn: grown with the word, not left at its old size or place.
        #expect(circle.width < after.width + 30)
        #expect(circle.height < after.height + 24)
        for other in [page - 1, page + 1] where other >= 0 && other < large.pageCount {
            #expect(SketchLayout.place([mark], chapter: large, page: other, area: Self.area).isEmpty)
        }
    }

    @Test func anUnderlineWrapsWithItsWords() async throws {
        let session = try await Self.session()
        let small = try #require(session.paginatedChapter(2))
        // A full line (the page is 312 pt wide: 33–39 characters at 19 pt), which 30 pt breaks in two.
        let line = try Self.line(in: small, minimum: 34)
        let y = line.baseline + 3
        let points = stride(from: line.used.minX + 1, through: line.used.maxX - 1, by: 4).map { CGPoint(x: $0, y: y) }
        let mark = Self.mark(SketchLayout.capture([Self.stroke(points)], chapter: small, page: 1), spine: 2)
        #expect(mark.anchors.strokes.first?.kind == .text)

        Self.resize(session, to: 30)
        let large = try #require(session.paginatedChapter(2, anchor: line.characters.location))
        let page = large.pageIndex(containing: line.characters.location)
        let placed = SketchLayout.place([mark], chapter: large, page: page, area: Self.area)
        // The words now take two lines or more: one piece under each.
        #expect(placed.count >= 2)
        let lines = large.lines(onPage: page)
        for piece in placed {
            let box = Self.bounds([piece])
            #expect(box.height < 2)
            let under = lines.filter { abs($0.baseline + 3 * 30 / 19 - box.midY) < 3 }
            #expect(under.count == 1)
        }
    }

    @Test func aMarginNoteKeepsItsShapeAndItsMargin() async throws {
        let session = try await Self.session()
        let small = try #require(session.paginatedChapter(2))
        let line = try Self.line(in: small)
        let x = Self.textSize.width + 3
        // Four little strokes, like a word written in the right margin.
        let strokes = (0 ..< 4).map { index in
            Self.stroke([CGPoint(x: x + CGFloat(index) * 4, y: line.baseline - 8), CGPoint(x: x + CGFloat(index) * 4 + 3, y: line.baseline)],
                        seed: UInt32(10 + index))
        }
        let captured = SketchLayout.capture(strokes, chapter: small, page: 1)
        #expect(captured.anchors.allSatisfy { $0.kind == .free && $0.edge == .trailing })
        let mark = Self.mark(captured, spine: 2)

        Self.resize(session, to: 27)
        let large = try #require(session.paginatedChapter(2, anchor: small.range(ofPage: 0).location))
        let reference = try #require(captured.anchors.first?.characters.first)
        let page = large.pageIndex(containing: reference)
        let placed = SketchLayout.place([mark], chapter: large, page: page, area: Self.area).sorted { $0.strokeIndex < $1.strokeIndex }
        #expect(placed.count == 4)
        let origin = try #require(placed.first?.stroke.path.first?.location)
        let drawnOrigin = try #require(strokes.first?.path.first?.location)
        for (original, back) in zip(strokes, placed) {
            for (p, q) in zip(original.path.map(\.location), back.stroke.path.map(\.location)) {
                #expect(abs((p.x - drawnOrigin.x) - (q.x - origin.x)) < 0.01)
                #expect(abs((p.y - drawnOrigin.y) - (q.y - origin.y)) < 0.01)
                #expect(q.x > Self.textSize.width)
            }
        }
        // Beside the line it was written by.
        let place = try #require(large.glyphPlace(at: reference))
        #expect(abs(origin.y - (place.baseline - 8)) < 0.01)
    }

    @Test func aBracketSpansTheSameLines() async throws {
        let session = try await Self.session()
        let small = try #require(session.paginatedChapter(2))
        let lines = small.lines(onPage: 1).filter { $0.characters.length > 0 }
        #expect(lines.count > 8)
        let top = lines[3], bottom = lines[6]
        let points = stride(from: top.rect.minY + 2, through: bottom.rect.maxY - 2, by: 3).map { CGPoint(x: -10, y: $0) }
        let captured = SketchLayout.capture([Self.stroke(points)], chapter: small, page: 1)
        let anchors = try #require(captured.anchors.first)
        #expect(anchors.kind == .block)
        let covers = try #require(captured.covers)
        #expect(NSLocationInRange(top.characters.location, covers))
        #expect(NSLocationInRange(NSMaxRange(bottom.characters) - 2, covers))
        let mark = Self.mark(captured, spine: 2)
        Self.expectExact(points, SketchLayout.place([mark], chapter: small, page: 1, area: Self.area))

        for size in [27.0, 14.0] {
            Self.resize(session, to: size)
            let chapter = try #require(session.paginatedChapter(2, anchor: top.characters.location))
            let passage = try Self.passage(captured, in: chapter)
            let placed = SketchLayout.place([mark], chapter: chapter, page: passage.page, area: Self.area)
            let all = placed.flatMap { $0.stroke.path.map(\.location) }
            // As far out in the margin, beside the same text, from its first line to its last.
            #expect(!all.isEmpty)
            #expect(all.allSatisfy { abs($0.x + 10) < 0.01 })
            let box = Self.bounds(placed)
            #expect(box.minY < passage.text.minY + 4 && box.minY > passage.text.minY - 12)
            #expect(box.maxY > passage.text.maxY - 4 && box.maxY < passage.text.maxY + 12)
        }
    }

    @Test func aCircleAroundAParagraphStaysAroundIt() async throws {
        let session = try await Self.session()
        let small = try #require(session.paginatedChapter(2))
        let lines = small.lines(onPage: 1).filter { $0.characters.length >= 30 }
        #expect(lines.count > 6)
        let run = lines[2 ... 5]
        let drawn = run.map(\.used).reduce(CGRect.null) { $0.union($1) }
        let points = Self.ellipse(around: drawn.insetBy(dx: -6, dy: -4), count: 96)
        let captured = SketchLayout.capture([Self.stroke(points)], chapter: small, page: 1)
        #expect(captured.anchors.first?.kind == .block)
        let mark = Self.mark(captured, spine: 2)
        Self.expectExact(points, SketchLayout.place([mark], chapter: small, page: 1, area: Self.area))

        for size in [27.0, 14.0] {
            Self.resize(session, to: size)
            let chapter = try #require(session.paginatedChapter(2, anchor: run.first!.characters.location))
            let passage = try Self.passage(captured, in: chapter)
            let placed = SketchLayout.place([mark], chapter: chapter, page: passage.page, area: Self.area)
            // One closed loop around all of the passage's text, about as snug as it was drawn.
            #expect(placed.count == 1)
            let circle = Self.bounds(placed)
            #expect(circle.contains(passage.text.insetBy(dx: 1, dy: 1)))
            #expect(circle.height < passage.text.height + 3 * CGFloat(size))
            #expect(circle.minX > -24 && circle.maxX < Self.textSize.width + 24)
        }
    }

    /// Every point back where it was drawn.
    static func expectExact(_ points: [CGPoint], _ placed: [SketchLayout.Placed]) {
        #expect(placed.count == 1)
        let back = placed.first.map { $0.stroke.path.map(\.location) } ?? []
        #expect(back.count == points.count)
        for (p, q) in zip(points, back) { #expect(hypot(p.x - q.x, p.y - q.y) < 0.01) }
    }

    /// The page a block marking's passage is on now (the test pages each start at it, so all of it
    /// is), and the box of its glyphs there.
    static func passage(_ captured: (strokes: [PKStroke], anchors: [StrokeAnchors], covers: NSRange?),
                        in chapter: PaginatedChapter) throws -> (page: Int, text: CGRect) {
        let anchors = try #require(captured.anchors.first)
        let first = try #require(anchors.characters.first), last = try #require(anchors.lineStarts.first)
        let page = chapter.pageIndex(containing: first)
        #expect(chapter.pageIndex(containing: last) == page)
        let range = NSRange(location: first, length: last - first + 1)
        let text = chapter.rects(for: range, page: page).reduce(CGRect.null) { $0.union($1) }
        #expect(!text.isNull)
        return (page, text)
    }

    @Test func pagesDrawTheirMarkings() async throws {
        let session = try await Self.session()
        let chapter = try #require(session.paginatedChapter(2))
        let line = try Self.line(in: chapter)
        let rect = try #require(chapter.rects(for: chapter.wordRange(at: line.characters.location + 8), page: 1).first)
        let mark = Self.mark(SketchLayout.capture([Self.stroke(Self.ellipse(around: rect))], chapter: chapter, page: 1), spine: 2)
        session.sketches = [mark]
        let spread = SpreadViewController(session: session, slots: [PageSlot(spineIndex: 2, page: 1)], layout: BookmarkTests.layout, palette: .paper)
        spread.loadViewIfNeeded()
        let pageView = try #require(spread.pageViews.first)
        #expect(pageView.sketchStrokes().count == 1)
        // In the view's coordinates: shifted by the text's origin.
        let drawn = Self.bounds(pageView.sketchStrokes())
        #expect(drawn.contains(rect.offsetBy(dx: pageView.textOrigin.x, dy: pageView.textOrigin.y).insetBy(dx: 1, dy: 1)))
        let other = SpreadViewController(session: session, slots: [PageSlot(spineIndex: 2, page: 2)], layout: BookmarkTests.layout, palette: .paper)
        other.loadViewIfNeeded()
        #expect(other.pageViews.first?.sketchStrokes().isEmpty == true)
    }

    @Test func nearbyStrokesMakeOneMarking() {
        let a = Self.stroke([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0)], seed: 1)
        let b = Self.stroke([CGPoint(x: 24, y: 2), CGPoint(x: 40, y: 2)], seed: 2)
        let far = Self.stroke([CGPoint(x: 200, y: 200), CGPoint(x: 220, y: 200)], seed: 3)
        let groups = MarkupSession.clusters([a, b, far], gap: 12)
        #expect(groups.map { $0.map(\.randomSeed) } == [[1, 2], [3]])
    }

    @Test func sketchesPersistListWithHighlightsAndDieWithTheirBook() throws {
        let store = LibraryStore(inMemory: true)
        let book = Book(title: "One", author: "A. Author", language: nil, fileSize: 1, partialMD5: "aaaa", hasCover: false)
        let other = Book(title: "Two", author: nil, language: nil, fileSize: 1, partialMD5: "bbbb", hasCover: false)
        store.context.insert(book)
        store.context.insert(other)
        let anchors = SketchAnchors(strokes: [StrokeAnchors(kind: .text, edge: .glyph, characters: [5, 6], dx: [0, 0.5],
                                                            dy: [0.1, 0.1], lineStarts: [0, 0])])
        #expect(SketchAnchors.decode(anchors.encoded()) == anchors)
        let drawing = PKDrawing(strokes: [Self.stroke([CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 1)])])
        let mark = SketchMark(id: UUID(), spineIndex: 1, version: Date(timeIntervalSinceReferenceDate: 1000), drawing: drawing, anchors: anchors)
        store.apply([.save(SketchSave(mark: mark, range: NSRange(location: 5, length: 4), text: "word", isNew: true))], for: book)
        store.add(Sketch(bookID: other.id, spineIndex: 0, startOffset: 0, endOffset: 1, text: "z",
                         drawing: drawing.dataRepresentation(), anchors: anchors.encoded()))
        let saved = try #require(store.sketches(for: book).first)
        #expect(saved.id == mark.id)
        #expect(saved.text == "word")
        #expect(saved.range == NSRange(location: 5, length: 4))
        #expect(saved.mark == mark)
        #expect(saved.mark?.drawing.strokes.count == 1)

        // In the notes list and the export, in reading order with the highlights.
        let before = Annotation(bookID: book.id, spineIndex: 1, startOffset: 2, endOffset: 4, text: "a highlight", color: .yellow)
        let after = Annotation(bookID: book.id, spineIndex: 1, startOffset: 40, endOffset: 44, text: "later", color: .blue)
        let entries = NotesListView.entries(annotations: [before, after], sketches: [saved])
        #expect(entries.map(\.id) == [before.id, saved.id, after.id])

        // Saving again replaces it; an edit that removes it deletes it.
        let moved = SketchMark(id: mark.id, spineIndex: 1, version: Date(timeIntervalSinceReferenceDate: 2000), drawing: drawing, anchors: anchors)
        store.apply([.save(SketchSave(mark: moved, range: NSRange(location: 6, length: 3), text: "ord", isNew: false))], for: book)
        #expect(store.sketches(for: book).map(\.text) == ["ord"])
        store.apply([.delete(mark.id)], for: book)
        #expect(store.sketches(for: book).isEmpty)

        store.apply([.save(SketchSave(mark: mark, range: NSRange(location: 5, length: 4), text: "word", isNew: true))], for: book)
        store.delete(book)
        #expect(store.sketches(for: book).isEmpty)
        #expect(store.sketches(for: other).map(\.text) == ["z"])
        #expect(try store.context.fetch(FetchDescriptor<Sketch>()).count == 1)
    }

    @Test func markdownExportCarriesMarkings() {
        let text = AnnotationExport.markdown(title: "Alice", author: nil, annotations: [
            (chapter: "One", text: "a circled phrase", note: NotesListView.sketchNote),
        ])
        #expect(text.contains("> a circled phrase"))
        #expect(text.contains(NotesListView.sketchNote))
    }
}
