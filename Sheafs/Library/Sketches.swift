import Foundation
import PencilKit
import SwiftData
import Synchronization

/// A marking drawn on the page with Apple Pencil (or a finger): PencilKit strokes, each control
/// point anchored to a character of the chapter (`SketchAnchors`) so the marking follows its text
/// through a font, size, margin or fold change. Stored like a highlight: the chapter, the UTF-16
/// range of the text it marks (with the CREngine pointers of both ends and the quoted `text`, for
/// re-anchoring and for the notes list), keyed by book id, so `LibraryStore.delete(book)` deletes
/// them by hand.
@Model
final class Sketch {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var spineIndex: Int
    var startOffset: Int
    var endOffset: Int
    var startPointer: String?
    var endPointer: String?
    /// The text the marking is on or beside, as it reads on the page.
    var text: String
    /// `PKDrawing.dataRepresentation()` of the strokes as they were captured (page coordinates of
    /// the page they were drawn on, no transforms or masks): their inks, widths, pressure and seeds.
    var drawing: Data
    /// `SketchAnchors` (one anchor per control point of each stroke), property-list encoded.
    var anchors: Data
    /// The marking over its text as it looked when drawn, for the notes list.
    @Attribute(.externalStorage) var thumbnail: Data?
    var createdAt: Date
    var modifiedAt: Date

    init(id: UUID = UUID(), bookID: UUID, spineIndex: Int, startOffset: Int, endOffset: Int,
         startPointer: String? = nil, endPointer: String? = nil, text: String,
         drawing: Data, anchors: Data, thumbnail: Data? = nil, modifiedAt: Date = .now) {
        self.id = id
        self.bookID = bookID
        self.spineIndex = spineIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.startPointer = startPointer
        self.endPointer = endPointer
        self.text = text
        self.drawing = drawing
        self.anchors = anchors
        self.thumbnail = thumbnail
        self.createdAt = modifiedAt
        self.modifiedAt = modifiedAt
    }

    var range: NSRange { NSRange(location: startOffset, length: max(0, endOffset - startOffset)) }
    var location: ReadingLocation { ReadingLocation(spineIndex: spineIndex, textOffset: startOffset) }

    /// What the pages draw, decoded once per version.
    var mark: SketchMark? { SketchMark.decoded(id: id, spineIndex: spineIndex, version: modifiedAt, drawing: drawing, anchors: anchors) }
}

/// How each control point of a stroke holds onto the text.
nonisolated struct SketchAnchors: Codable, Equatable, Sendable {
    var strokes: [StrokeAnchors]

    func encoded() -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> SketchAnchors? {
        try? PropertyListDecoder().decode(SketchAnchors.self, from: data)
    }
}

/// One stroke's anchors: how it moves with the text, and one `PointAnchor` per control point
/// (parallel arrays, so the encoding stays small).
nonisolated struct StrokeAnchors: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// On the text (a circle, an underline, a strike-through): every point keeps to the
        /// character under it, at its offset from the glyph in ems, so the mark stretches and
        /// wraps with its words.
        case text
        /// A tall stroke beside lines (a bracket, a bar in the margin): every point keeps to its
        /// own line, so the stroke grows or shrinks with the lines it spans; its distance from the
        /// column edge stays as drawn.
        case span
        /// Anything else (handwriting, an arrow, a doodle in the margin): the stroke keeps its
        /// shape and size, all of it placed from one character of the marking.
        case free
    }

    /// Where a point's x is measured from.
    enum Edge: Int, Codable, Sendable {
        /// The anchor character's glyph.
        case glyph = 0
        /// The text column's left or right edge (the stroke is in that margin).
        case leading = 1
        case trailing = 2
    }

    var kind: Kind
    var edge: Edge
    /// Per control point: the anchor character (chapter coordinates) …
    var characters: [Int]
    /// … the point's offset from it (ems for `.text`, points otherwise; x from `edge`, y from the
    /// character's baseline) …
    var dx: [Float]
    var dy: [Float]
    /// … and the first character of the anchor's line when drawn: two neighbouring points that
    /// shared a line and no longer do are not joined (an underline wraps with its words).
    var lineStarts: [Int]

    var count: Int { characters.count }
}

/// What a page needs to draw a sketch: a value, so the pager can tell "nothing changed" (by id and
/// version; the strokes are decoded once per version).
nonisolated struct SketchMark: Hashable, @unchecked Sendable {
    var id: UUID
    var spineIndex: Int
    var version: Date
    var drawing: PKDrawing
    var anchors: SketchAnchors

    static func == (a: SketchMark, b: SketchMark) -> Bool { a.id == b.id && a.version == b.version && a.spineIndex == b.spineIndex }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(version)
    }

    /// The character range the anchors cover.
    var anchoredRange: ClosedRange<Int>? {
        let all = anchors.strokes.flatMap(\.characters)
        guard let low = all.min(), let high = all.max() else { return nil }
        return low ... high
    }

    /// Decoded marks by id (a model's `mark` may be read off the main actor: SwiftData's models are
    /// not isolated to it).
    private static let cache = Mutex<[UUID: SketchMark]>([:])

    static func decoded(id: UUID, spineIndex: Int, version: Date, drawing: Data, anchors: Data) -> SketchMark? {
        if let hit = cache.withLock({ $0[id] }), hit.version == version, hit.spineIndex == spineIndex { return hit }
        guard let strokes = try? PKDrawing(data: drawing), let anchors = SketchAnchors.decode(anchors),
              anchors.strokes.count == strokes.strokes.count else { return nil }
        let mark = SketchMark(id: id, spineIndex: spineIndex, version: version, drawing: strokes, anchors: anchors)
        cache.withLock { $0[id] = mark }
        return mark
    }

    /// Seeds the cache with a mark the pager made itself, so the model's copy decodes to it.
    static func remember(_ mark: SketchMark) { cache.withLock { $0[mark.id] = mark } }
}
