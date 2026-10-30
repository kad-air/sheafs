import UIKit
import PencilKit

/// Pencil markings against the text: `capture` ties every control point of a stroke drawn on a
/// page to a character of the chapter, and `place` puts the strokes back on whichever page now
/// holds those characters, however the chapter is laid out (font, size, spacing, margins, fold).
/// At the layout a marking was drawn in, it comes back exactly as drawn.
///
/// How a stroke holds on depends on what it is (`StrokeAnchors.Kind`):
/// - on the text (most of it lies over glyphs: a circle, an underline, a strike-through): each
///   point keeps to the character under it on the stroke's own line(s), at its offset from that
///   glyph in ems, so the mark stretches with its words, and where they now wrap onto the next
///   line the stroke is cut there and carries on under them; a point over a gap, or grazing a
///   word at either end that holds almost none of the stroke, keeps to the nearest letter of a
///   word the stroke is over (a circle's clearance around its word is not the words beside it);
/// - a stroke the size of a passage, two lines tall or more and either thin (a bracket or bar
///   beside it) or across half the column or more (a circle around a paragraph, a scribble through
///   it): the whole stroke keeps to the run of lines it spans, from the first character of the
///   first to the last of the last, and is stretched to wherever that run is now (by lines, so a
///   point between two lines stays between them; across a page break the stroke is cut there and
///   carries on over the rest of the run on the next page); its overshoot above and below the run
///   in ems, its x as a fraction of the column, or points out in the margin, so a bracket keeps its
///   distance from the column and a circle stays around it. Per point anchoring tore these apart:
///   each line's first character is mid-line after a reflow;
/// - anything else (a note written in the margin, an arrow, a doodle, or a cluster of small
///   strokes that reads as handwriting anywhere): rigid, as drawn, placed from one character of the
///   marking and from the column edge on its side, kept on the page.
/// Coordinates are page coordinates (origin at the text's top-left, `PaginatedChapter`'s).
enum SketchLayout {
    /// A stroke placed on a page: which stored stroke and which of its control points it draws.
    struct Placed {
        var stroke: PKStroke
        var sketchID: UUID
        var strokeIndex: Int
        var points: [Int]
    }

    // MARK: Capture

    /// Strokes as the canvas holds them, made plain: transforms applied (a lasso move or resize)
    /// and the parts a pixel eraser left as strokes of their own, with no masks.
    static func normalized(_ stroke: PKStroke) -> [PKStroke] {
        var paths: [[PKStrokePoint]] = []
        if stroke.mask != nil {
            for range in stroke.maskedPathRanges {
                let points = Array(stroke.path.interpolatedPoints(in: range, by: .distance(1.5)))
                if !points.isEmpty { paths.append(points) }
            }
        } else {
            paths = [Array(stroke.path)]
        }
        let transform = stroke.transform
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        return paths.map { points in
            let moved = transform.isIdentity ? points : points.map { point in
                PKStrokePoint(location: point.location.applying(transform), timeOffset: point.timeOffset,
                              size: CGSize(width: point.size.width * scale, height: point.size.height * scale),
                              opacity: point.opacity, force: point.force, azimuth: point.azimuth,
                              altitude: point.altitude, secondaryScale: point.secondaryScale)
            }
            return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: moved, creationDate: stroke.path.creationDate),
                            transform: .identity, mask: nil, randomSeed: stroke.randomSeed)
        }
    }

    /// The text of a page, measured once for a capture.
    private final class PageText {
        let chapter: PaginatedChapter
        let page: Int
        let lines: [TextLine]
        let ems: [CGFloat]
        let width: CGFloat
        private var boxes: [Int: [(index: Int, box: CGRect)]] = [:]

        init(chapter: PaginatedChapter, page: Int) {
            self.chapter = chapter
            self.page = page
            lines = chapter.lines(onPage: page).filter { $0.characters.length > 0 }
            ems = lines.map { chapter.glyphPlace(at: $0.characters.location)?.em ?? 17 }
            width = chapter.pageSize.width
        }

        var typicalEm: CGFloat { ems.isEmpty ? 17 : ems.sorted()[ems.count / 2] }
        var typicalLineHeight: CGFloat {
            let heights = lines.map(\.rect.height).sorted()
            return heights.isEmpty ? typicalEm * 1.4 : heights[heights.count / 2]
        }

        /// The middle of a line's lower-case letters: what a mark on that line is drawn around.
        func centre(_ line: Int) -> CGFloat { lines[line].baseline - ems[line] * 0.35 }

        /// The lines a stroke with these bounds belongs to: those whose letters' middle it spans,
        /// else the one nearest its own middle (an underline, a strike-through).
        func homeLines(for bounds: CGRect) -> [Int] {
            let inside = lines.indices.filter { bounds.minY <= centre($0) && centre($0) <= bounds.maxY }
            if !inside.isEmpty { return inside }
            return nearestLine(to: bounds.midY).map { [$0] } ?? []
        }

        func nearestLine(to y: CGFloat, among candidates: [Int]? = nil) -> Int? {
            (candidates ?? Array(lines.indices)).min { abs(centre($0) - y) < abs(centre($1) - y) }
        }

        /// The glyph boxes of a line's characters, in order, without its closing line break.
        func characters(of line: Int) -> [(index: Int, box: CGRect)] {
            if let cached = boxes[line] { return cached }
            let string = chapter.textStorage.string as NSString
            var result: [(index: Int, box: CGRect)] = []
            let range = lines[line].characters
            for index in range.location ..< NSMaxRange(range) {
                let unit = string.character(at: index)
                if unit == 0x0A || unit == 0x2028 { continue }
                guard let place = chapter.glyphPlace(at: index), place.page == page else { continue }
                result.append((index: index, box: place.box))
            }
            if result.isEmpty, let place = chapter.glyphPlace(at: range.location) {
                result = [(index: range.location, box: place.box)]
            }
            boxes[line] = result
            return result
        }

        /// The character of `line` nearest to `x`: under it, else the first or last.
        func character(on line: Int, nearestTo x: CGFloat) -> (index: Int, box: CGRect) {
            let chars = characters(of: line)
            guard let first = chars.first, let last = chars.last else {
                return (lines[line].characters.location, lines[line].used)
            }
            if x <= first.box.maxX { return first }
            if x >= last.box.minX { return last }
            var best = first
            var distance = CGFloat.greatestFiniteMagnitude
            for char in chars {
                if char.box.minX <= x && x <= char.box.maxX { return char }
                let d = min(abs(char.box.minX - x), abs(char.box.maxX - x))
                if d < distance { distance = d; best = char }
            }
            return best
        }

        /// How much of a stroke lies over a line's glyphs (0…1). A little past a line's ends still
        /// counts (an underline overshoots), but never outside the column: a point in the margin
        /// is over no glyph.
        func overlap(_ points: [CGPoint]) -> CGFloat {
            guard !points.isEmpty, !lines.isEmpty else { return 0 }
            let over = points.filter { point in
                lines.indices.contains { line in
                    let em = ems[line], used = lines[line].used, baseline = lines[line].baseline
                    return point.y >= baseline - em * 1.2 && point.y <= baseline + em * 0.6
                        && point.x >= max(0, used.minX - em * 0.4) && point.x <= min(width, used.maxX + em * 0.4)
                }
            }
            return CGFloat(over.count) / CGFloat(points.count)
        }

        private var words: [Int: NSRange] = [:]

        /// The word character `index` is part of; nil over a space or punctuation.
        func word(at index: Int) -> NSRange? {
            let range: NSRange
            if let known = words[index] {
                range = known
            } else {
                range = chapter.wordRange(at: index)
                words[index] = range
            }
            return NSLocationInRange(index, range) ? range : nil
        }

        /// The characters of a text stroke's points on one line: each point keeps to the glyph
        /// under it, but a point over a space (or punctuation), and a point over a word at either
        /// end of the stroke that holds under a tenth of its points there (a circle's edge grazing
        /// the word before, an underline overshooting into the next), keeps to the nearest letter
        /// of a word the stroke is really over, so a circle around a word stays with that word
        /// when its neighbours wrap away.
        func anchors(on line: Int, at xs: [CGFloat]) -> [(index: Int, box: CGRect)] {
            let hits = xs.map { character(on: line, nearestTo: $0) }
            var counts: [Int: Int] = [:]
            for hit in hits {
                if let word = word(at: hit.index) { counts[word.location, default: 0] += 1 }
            }
            let order = counts.keys.sorted()
            guard !order.isEmpty else { return hits }
            let threshold = max(1, xs.count / 10)
            var strong = Set(order.filter { counts[$0]! >= threshold })
            if strong.isEmpty { strong = Set(order) }
            // Only the ends can be grazed: a short word in the middle of a strike-through is struck.
            for key in order where !strong.contains(key) && key != order.first && key != order.last {
                strong.insert(key)
            }
            let chars = characters(of: line)
            let letters = chars.filter { char in word(at: char.index).map { strong.contains($0.location) } ?? false }
            guard !letters.isEmpty else { return hits }
            return zip(hits, xs).map { hit, x in
                if let word = word(at: hit.index), strong.contains(word.location) { return hit }
                return letters.min { a, b in
                    distance(from: x, to: a.box) < distance(from: x, to: b.box)
                } ?? hit
            }
        }

        private func distance(from x: CGFloat, to box: CGRect) -> CGFloat {
            if box.minX <= x && x <= box.maxX { return 0 }
            return min(abs(box.minX - x), abs(box.maxX - x))
        }

        func edge(for x: CGFloat) -> StrokeAnchors.Edge {
            if x < 0 { return .leading }
            if x > width { return .trailing }
            return .glyph
        }

        func origin(of edge: StrokeAnchors.Edge, glyph: CGRect) -> CGFloat {
            switch edge {
            case .glyph: glyph.minX
            case .leading: 0
            case .trailing: width
            }
        }

        /// The characters of the lines whose letters' middle lies between `top` and `bottom`.
        func lineCharacters(from top: CGFloat, to bottom: CGFloat) -> NSRange? {
            let spanned = lines.indices.filter { centre($0) >= top && centre($0) <= bottom }
            guard let first = spanned.first, let last = spanned.last else { return nil }
            let start = lines[first].characters.location
            return NSRange(location: start, length: NSMaxRange(lines[last].characters) - start)
        }
    }

    /// One marking's strokes, drawn on `page` (page coordinates): plain strokes (`normalized`), each
    /// with its anchors, and the range of text the marking is on or beside.
    static func capture(_ strokes: [PKStroke], chapter: PaginatedChapter, page: Int) -> (strokes: [PKStroke], anchors: [StrokeAnchors], covers: NSRange?) {
        let strokes = strokes.flatMap(normalized).filter { !$0.path.isEmpty }
        guard !strokes.isEmpty else { return ([], [], nil) }
        let text = PageText(chapter: chapter, page: page)
        let pageStart = chapter.range(ofPage: page).location
        guard !text.lines.isEmpty else {
            // Nothing to measure against (a page with only a picture's line): rigid, from the page's start.
            let place = chapter.glyphPlace(at: pageStart)
            let anchors = strokes.map { stroke in
                rigid(stroke, character: pageStart, edge: .leading, origin: 0, baseline: place?.baseline ?? 0,
                      lineStart: place?.lineStart ?? pageStart)
            }
            return (strokes, anchors, NSRange(location: pageStart, length: 1))
        }

        let points = strokes.map { $0.path.map(\.location) }
        let bounds = points.map(Self.bounds)
        let em = text.typicalEm
        let diagonals = bounds.map { hypot($0.width, $0.height) }.sorted()
        let handwriting = strokes.count >= 4 && diagonals[diagonals.count / 2] < em * 1.2
        enum Role { case text, block, span, free }
        let roles: [Role] = strokes.indices.map { index in
            if handwriting { return .free }
            let box = bounds[index]
            let tall = box.height >= text.typicalLineHeight * 1.8
            let thin = box.height >= 2.5 * max(box.width, 1)
            // Over or beside two lines or more, and either thin (a bracket, a bar) or across most of
            // the column (a circle around a paragraph, a scribble through it): it marks the passage.
            if tall, thin || box.width >= text.width * 0.5, text.homeLines(for: box).count >= 2 { return .block }
            if text.overlap(points[index]) >= 0.5 { return .text }
            if tall && thin { return .span }
            return .free
        }

        var anchors: [StrokeAnchors?] = Array(repeating: nil, count: strokes.count)
        var covered: [NSRange] = []
        for index in strokes.indices where roles[index] == .text {
            let home = text.homeLines(for: bounds[index])
            var a = StrokeAnchors(kind: .text, edge: .glyph, characters: [], dx: [], dy: [], lineStarts: [])
            let lines = points[index].map { text.nearestLine(to: $0.y, among: home) ?? 0 }
            // Each line's points are anchored together: which words the stroke is over decides
            // where a point over a gap keeps to.
            var chars: [(index: Int, box: CGRect)?] = Array(repeating: nil, count: points[index].count)
            for line in Set(lines) {
                let members = points[index].indices.filter { lines[$0] == line }
                let anchored = text.anchors(on: line, at: members.map { points[index][$0].x })
                for (member, char) in zip(members, anchored) { chars[member] = char }
            }
            for (number, point) in points[index].enumerated() {
                let line = lines[number]
                let char = chars[number] ?? text.character(on: line, nearestTo: point.x)
                // The character's own baseline and size (a superscript sits above the line's).
                let place = chapter.glyphPlace(at: char.index)
                let size = place?.em ?? text.ems[line]
                a.characters.append(char.index)
                a.dx.append(Float((point.x - char.box.minX) / size))
                a.dy.append(Float((point.y - (place?.baseline ?? text.lines[line].baseline)) / size))
                a.lineStarts.append(text.lines[line].characters.location)
            }
            anchors[index] = a
            if let low = a.characters.min(), let high = a.characters.max() {
                covered.append(NSRange(location: low, length: high - low + 1))
            }
        }
        for index in strokes.indices where roles[index] == .block {
            let home = text.homeLines(for: bounds[index])
            guard let top = home.first, let bottom = home.last else { continue }
            let first = text.characters(of: top).first?.index ?? text.lines[top].characters.location
            let last = text.characters(of: bottom).last?.index ?? max(first, NSMaxRange(text.lines[bottom].characters) - 1)
            let run = home.map { BlockLine(page: page, centre: text.centre($0), em: text.ems[$0], height: text.lines[$0].rect.height) }
            var a = StrokeAnchors(kind: .block, edge: .glyph, characters: [], dx: [], dy: [], lineStarts: [])
            for point in points[index] {
                a.characters.append(first)
                a.lineStarts.append(last)
                a.dx.append(Float(Self.across(point.x, width: text.width)))
                a.dy.append(Float(Self.down(point.y, lines: run)))
            }
            anchors[index] = a
            covered.append(NSRange(location: first, length: last - first + 1))
        }
        for index in strokes.indices where roles[index] == .span {
            let home = text.homeLines(for: bounds[index])
            let edge = text.edge(for: bounds[index].midX)
            var a = StrokeAnchors(kind: .span, edge: edge, characters: [], dx: [], dy: [], lineStarts: [])
            for point in points[index] {
                let line = text.nearestLine(to: point.y, among: home) ?? 0
                let first = text.characters(of: line).first ?? (index: text.lines[line].characters.location, box: text.lines[line].used)
                let baseline = chapter.glyphPlace(at: first.index)?.baseline ?? text.lines[line].baseline
                a.characters.append(first.index)
                a.dx.append(Float(point.x - text.origin(of: edge, glyph: first.box)))
                a.dy.append(Float(point.y - baseline))
                a.lineStarts.append(text.lines[line].characters.location)
            }
            anchors[index] = a
            if let range = text.lineCharacters(from: bounds[index].minY, to: bounds[index].maxY) { covered.append(range) }
        }
        let free = strokes.indices.filter { roles[$0] == .free }
        if !free.isEmpty {
            // One reference for all of them, so a written note keeps together: the first character
            // the marking's text strokes hold, else the character nearest the free strokes' middle.
            let union = free.map { bounds[$0] }.reduce(CGRect.null) { $0.union($1) }
            let edge = text.edge(for: union.midX)
            let reference: (index: Int, box: CGRect, baseline: CGFloat, lineStart: Int)
            if let held = anchors.compactMap({ $0 }).filter({ $0.kind == .text }).flatMap(\.characters).min(),
               let place = chapter.glyphPlace(at: held), place.page == page {
                reference = (held, place.box, place.baseline, place.lineStart)
            } else {
                let line = text.nearestLine(to: union.midY) ?? 0
                let char = text.character(on: line, nearestTo: union.midX)
                let place = chapter.glyphPlace(at: char.index)
                reference = (char.index, char.box, place?.baseline ?? text.lines[line].baseline,
                             place?.lineStart ?? text.lines[line].characters.location)
            }
            let origin = text.origin(of: edge, glyph: reference.box)
            for index in free {
                anchors[index] = rigid(strokes[index], character: reference.index, edge: edge, origin: origin,
                                       baseline: reference.baseline, lineStart: reference.lineStart)
            }
            if let range = text.lineCharacters(from: union.minY, to: union.maxY) {
                covered.append(range)
            } else {
                covered.append(chapter.wordRange(at: reference.index))
            }
        }
        let covers = covered.reduce(nil as NSRange?) { union, range in union.map { NSUnionRange($0, range) } ?? range }
        return (strokes, anchors.map { $0! }, covers.map { wordAligned($0, in: chapter) })
    }

    /// A line of the run a `.block` stroke spans: its page, the middle of its letters (see
    /// `PageText.centre`), its font size and its height.
    struct BlockLine {
        var page: Int
        var centre: CGFloat
        var em: CGFloat
        var height: CGFloat
    }

    /// A `.block` point's x as stored: its fraction of the column's width, points past either edge
    /// outside it (a bracket stays as far out in the margin; a circle around a paragraph stays
    /// around the column, however wide it is now).
    static func across(_ x: CGFloat, width: CGFloat) -> CGFloat {
        if x < 0 { return x }
        if x > width { return 1 + (x - width) }
        return width > 0 ? x / width : 0
    }

    static func x(across u: CGFloat, width: CGFloat) -> CGFloat {
        if u < 0 { return u }
        if u > 1 { return width + (u - 1) }
        return u * width
    }

    /// A `.block` point's y as stored: its place down the run of lines (0 at the first line's
    /// letters, 1 at the last's, by lines: halfway between the second and third of five lines is
    /// 0.375), ems above the first line below 0, ems below the last line above 1.
    static func down(_ y: CGFloat, lines: [BlockLine]) -> CGFloat {
        guard let first = lines.first, let last = lines.last else { return 0 }
        if y < first.centre { return (y - first.centre) / first.em }
        if y > last.centre { return 1 + (y - last.centre) / last.em }
        guard lines.count > 1 else { return 0 }
        var k = 0
        while k < lines.count - 2 && y > lines[k + 1].centre { k += 1 }
        let gap = lines[k + 1].centre - lines[k].centre
        let fraction = gap > 0 ? (y - lines[k].centre) / gap : 0
        return (CGFloat(k) + fraction) / CGFloat(lines.count - 1)
    }

    /// Where a stored `.block` y lands on the run of lines as they are now: the line it belongs
    /// with (its page decides where it is drawn) and the y on that line's page. Between two lines
    /// a page break now separates, the nearer one's page, a line's height beyond it.
    static func y(down s: CGFloat, lines: [BlockLine]) -> (line: BlockLine, y: CGFloat)? {
        guard let first = lines.first, let last = lines.last else { return nil }
        if s < 0 { return (first, first.centre + s * first.em) }
        if s > 1 { return (last, last.centre + (s - 1) * last.em) }
        let position = s * CGFloat(lines.count - 1)
        let k = min(lines.count - 1, Int(position.rounded(.down)))
        guard k < lines.count - 1 else { return (last, last.centre) }
        let fraction = position - CGFloat(k)
        let a = lines[k], b = lines[k + 1]
        if a.page == b.page { return (a, a.centre + fraction * (b.centre - a.centre)) }
        return fraction < 0.5 ? (a, a.centre + fraction * a.height) : (b, b.centre - (1 - fraction) * b.height)
    }

    private static func rigid(_ stroke: PKStroke, character: Int, edge: StrokeAnchors.Edge, origin: CGFloat,
                              baseline: CGFloat, lineStart: Int) -> StrokeAnchors {
        let points = stroke.path.map(\.location)
        return StrokeAnchors(kind: .free, edge: edge, characters: Array(repeating: character, count: points.count),
                             dx: points.map { Float($0.x - origin) }, dy: points.map { Float($0.y - baseline) },
                             lineStarts: Array(repeating: lineStart, count: points.count))
    }

    /// A range widened to whole words at both ends.
    static func wordAligned(_ range: NSRange, in chapter: PaginatedChapter) -> NSRange {
        let length = chapter.textStorage.length
        guard length > 0 else { return range }
        let start = chapter.wordRange(at: max(0, min(range.location, length - 1)))
        let end = chapter.wordRange(at: max(0, min(NSMaxRange(range) - 1, length - 1)))
        let low = min(start.location, range.location)
        let high = min(length, max(NSMaxRange(end), NSMaxRange(range)))
        return NSRange(location: low, length: max(0, high - low))
    }

    /// The range a marking's anchors cover when there is no page to measure it on (the parts of a
    /// marking kept as they were).
    static func covers(_ anchors: StrokeAnchors) -> NSRange? {
        guard let low = anchors.held.min(), let high = anchors.held.max() else { return nil }
        return NSRange(location: low, length: high - low + 1)
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Placing

    /// The strokes of `marks` that fall on `page` of `chapter`, in page coordinates. `area` is what
    /// the page can show (page coordinates: the text column plus its margins); rigid parts are
    /// kept inside it.
    static func place(_ marks: [SketchMark], chapter: PaginatedChapter, page: Int, area: CGRect) -> [Placed] {
        var places: [Int: GlyphPlace?] = [:]
        func glyph(_ index: Int) -> GlyphPlace? {
            if let known = places[index] { return known }
            let found = chapter.glyphPlace(at: index)
            places[index] = found
            return found
        }
        let width = chapter.pageSize.width
        var pageLines: [Int: [TextLine]] = [:]
        func textLines(onPage page: Int) -> [TextLine] {
            if let known = pageLines[page] { return known }
            let found = chapter.lines(onPage: page).filter { $0.characters.length > 0 }
            pageLines[page] = found
            return found
        }
        /// The lines from the one holding `first` to the one holding `last`, wherever they are now.
        func passage(from first: Int, to last: Int) -> [BlockLine] {
            guard let start = glyph(first), let end = glyph(last), start.page <= end.page,
                  start.page <= page, page <= end.page else { return [] }
            return (start.page ... end.page).flatMap { number in
                textLines(onPage: number).filter { NSMaxRange($0.characters) > first && $0.characters.location <= last }.map { line in
                    let em = glyph(line.characters.location)?.em ?? 17
                    return BlockLine(page: number, centre: line.baseline - em * 0.35, em: em, height: line.rect.height)
                }
            }
        }
        var result: [Placed] = []
        for mark in marks where mark.spineIndex == chapter.spineIndex {
            let strokes = mark.drawing.strokes
            var rigid: [Placed] = []
            for (strokeIndex, anchors) in mark.anchors.strokes.enumerated() where strokeIndex < strokes.count {
                let stroke = strokes[strokeIndex]
                let points = Array(stroke.path)
                guard points.count == anchors.count else { continue }
                // Each point where it is now, nil off this page; `cuts`: points that start a new piece.
                var located: [CGPoint?] = Array(repeating: nil, count: points.count)
                var cuts = Set<Int>()
                if anchors.kind == .block {
                    guard let first = anchors.characters.min(), let last = anchors.lineStarts.max() else { continue }
                    let lines = passage(from: first, to: last)
                    guard !lines.isEmpty else { continue }
                    for index in points.indices {
                        guard let landed = Self.y(down: CGFloat(anchors.dy[index]), lines: lines), landed.line.page == page else { continue }
                        located[index] = CGPoint(x: Self.x(across: CGFloat(anchors.dx[index]), width: width), y: landed.y)
                    }
                } else {
                    var previous: GlyphPlace?
                    for index in points.indices {
                        guard let at = glyph(anchors.characters[index]), at.page == page else {
                            previous = nil
                            continue
                        }
                        // Neighbours that shared a line when drawn and no longer do: the words wrapped.
                        if anchors.kind == .text, let previous, index > 0,
                           anchors.lineStarts[index] == anchors.lineStarts[index - 1], at.lineStart != previous.lineStart {
                            cuts.insert(index)
                        }
                        let unit: CGFloat = anchors.kind == .text ? at.em : 1
                        let x: CGFloat = switch anchors.edge {
                        case .glyph: at.box.minX
                        case .leading: 0
                        case .trailing: width
                        }
                        located[index] = CGPoint(x: x + CGFloat(anchors.dx[index]) * unit,
                                                 y: at.baseline + CGFloat(anchors.dy[index]) * unit)
                        previous = at
                    }
                }
                var run: [(index: Int, location: CGPoint)] = []
                var runs: [[(index: Int, location: CGPoint)]] = []
                for index in points.indices {
                    guard let location = located[index] else {
                        if !run.isEmpty { runs.append(run); run = [] }
                        continue
                    }
                    if cuts.contains(index), !run.isEmpty {
                        runs.append(run)
                        run = []
                    }
                    run.append((index, location))
                }
                if !run.isEmpty { runs.append(run) }
                for (number, run) in runs.enumerated() {
                    let moved = run.map { item in
                        let point = points[item.index]
                        return PKStrokePoint(location: item.location, timeOffset: point.timeOffset, size: point.size,
                                             opacity: point.opacity, force: point.force, azimuth: point.azimuth,
                                             altitude: point.altitude, secondaryScale: point.secondaryScale)
                    }
                    // Each piece its own seed (the canvas tells strokes apart by it); the first keeps the stroke's.
                    let seed = number == 0 ? stroke.randomSeed : stroke.randomSeed &+ UInt32(number) &* 2_654_435_761
                    let placed = Placed(stroke: PKStroke(ink: stroke.ink,
                                                         path: PKStrokePath(controlPoints: moved, creationDate: stroke.path.creationDate),
                                                         transform: .identity, mask: nil, randomSeed: seed),
                                        sketchID: mark.id, strokeIndex: strokeIndex, points: run.map(\.index))
                    if anchors.kind == .free { rigid.append(placed) } else { result.append(placed) }
                }
            }
            result += kept(rigid, inside: area)
        }
        return result
    }

    /// Rigid strokes moved as one, the least distance that keeps them inside `area` (a margin note
    /// next to a column that grew wider still fits on the page).
    private static func kept(_ strokes: [Placed], inside area: CGRect) -> [Placed] {
        guard !strokes.isEmpty, !area.isNull else { return strokes }
        let union = strokes.reduce(CGRect.null) { $0.union(bounds($1.stroke.path.map(\.location))) }
        func shift(_ low: CGFloat, _ high: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
            if high - low > max - min { return min - low }
            if low < min { return min - low }
            if high > max { return max - high }
            return 0
        }
        let dx = shift(union.minX, union.maxX, area.minX, area.maxX)
        let dy = shift(union.minY, union.maxY, area.minY, area.maxY)
        guard dx != 0 || dy != 0 else { return strokes }
        return strokes.map { placed in
            var placed = placed
            let path = placed.stroke.path
            let moved = path.map { point in
                PKStrokePoint(location: CGPoint(x: point.location.x + dx, y: point.location.y + dy), timeOffset: point.timeOffset,
                              size: point.size, opacity: point.opacity, force: point.force, azimuth: point.azimuth,
                              altitude: point.altitude, secondaryScale: point.secondaryScale)
            }
            placed.stroke.path = PKStrokePath(controlPoints: moved, creationDate: path.creationDate)
            return placed
        }
    }
}
