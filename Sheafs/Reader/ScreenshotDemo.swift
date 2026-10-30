#if DEBUG
import UIKit
import PencilKit
import SheafsKit

/// Debug only, for App Store screenshots on the simulator (which has no Pencil and can't be
/// long-pressed headless): finds phrases in the book and makes the strokes a hand might draw over
/// them. `ReaderView`'s `-SheafsHighlightDemo` / `-SheafsMarkupDemo` launch arguments use it; the
/// strokes go onto the markup canvases and are saved through the same commit as a real drawing.
enum ScreenshotDemo {
    /// The first place in the book where `phrase` occurs (case-insensitive), in the chapter's
    /// UTF-16 offsets (the position and highlight contract).
    static func find(_ phrase: String, in chapters: [Chapter]) -> (spineIndex: Int, range: NSRange)? {
        for (index, chapter) in chapters.enumerated() {
            let range = (chapter.plainText as NSString).range(of: phrase, options: .caseInsensitive)
            if range.location != NSNotFound { return (index, range) }
        }
        return nil
    }

    /// `-SheafsMarkupDemo`'s spec: `page=<phrase>|underline=<phrase>|circle=<phrase>|bracket=<phrase>|note=<text>`,
    /// any subset, in any order; the first phrase starts the page (`page=` only does that).
    static func parse(_ spec: String) -> [(kind: String, value: String)] {
        spec.split(separator: "|").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
        }
    }

    /// The strokes for `spec` on one page, in the page view's coordinates (`origin` is the text's
    /// top-left in it). Phrases not on this page draw nothing here.
    static func strokes(spec: String, chapter: PaginatedChapter, page: Int, origin: CGPoint, margin: CGFloat) -> [PKStroke] {
        let string = chapter.textStorage.string as NSString
        let pageRange = chapter.range(ofPage: page)
        let lines = chapter.lines(onPage: page)
        guard !lines.isEmpty else { return [] }
        let items = parse(spec)
        func onPage(_ phrase: String) -> NSRange? {
            let found = string.range(of: phrase, options: .caseInsensitive, range: pageRange)
            return found.location == NSNotFound ? nil : found
        }
        func em(at index: Int) -> CGFloat { chapter.glyphPlace(at: index)?.em ?? 17 }
        func line(holding rect: CGRect) -> TextLine? {
            lines.min { abs($0.rect.midY - rect.midY) < abs($1.rect.midY - rect.midY) }
        }
        let shift = CGAffineTransform(translationX: origin.x, y: origin.y)
        var result: [[CGPoint]] = []
        var noteAfter: TextLine?
        // The last line of the paragraph holding a marked phrase on this page: where the note goes.
        func paragraphEnd(_ range: NSRange) -> TextLine? {
            let paragraph = NSIntersectionRange(string.paragraphRange(for: range), pageRange)
            return lines.last { NSIntersectionRange($0.characters, paragraph).length > 0 }
        }

        for (kind, value) in items {
            if kind != "note", let range = onPage(value) { noteAfter = paragraphEnd(range) }
            switch kind {
            case "underline":
                guard let range = onPage(value) else { continue }
                let size = em(at: range.location)
                for (number, rect) in chapter.rects(for: range, page: page).enumerated() {
                    guard let line = line(holding: rect) else { continue }
                    let y = line.baseline + size * 0.2
                    result.append(wobblyLine(from: CGPoint(x: rect.minX - 2, y: y + 0.6),
                                             to: CGPoint(x: rect.maxX + 3, y: y - 1.2 + CGFloat(number) * 0.4),
                                             amplitude: size * 0.045, seed: 3 + number))
                }
            case "circle":
                guard let range = onPage(value) else { continue }
                let rects = chapter.rects(for: range, page: page)
                guard let box = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { continue }
                let size = em(at: range.location)
                result.append(loop(around: box.insetBy(dx: -size * 0.3, dy: -size * 0.14)))
            case "bracket":
                guard let range = onPage(value) else { continue }
                let paragraph = NSIntersectionRange(string.paragraphRange(for: range), pageRange)
                let held = lines.filter { NSIntersectionRange($0.characters, paragraph).length > 0 }
                guard let top = held.first, let bottom = held.last else { continue }
                let size = em(at: range.location)
                let x = -min(margin * 0.5, size * 0.75)
                result.append(bracket(x: x, top: top.used.minY + size * 0.1, bottom: bottom.baseline + size * 0.22, size: size))
            case "note", "page":
                break
            default:
                print("[markup] demo: unknown item \(kind)")
            }
        }

        // The note in the blank after a short line: the marked paragraph's last line if it has
        // room, else the nearest short line on the page. Only on a page with a marked phrase (the
        // other page of a spread gets nothing).
        if let note = items.first(where: { $0.kind == "note" })?.value, noteAfter != nil {
            let size = em(at: pageRange.location)
            let scale = size * 0.8   // the hand's x-height: bigger than the type, as handwriting is
            let width = handwritingWidth(note) * scale
            // A hand runs on into the margin.
            let column = (lines.map(\.rect.maxX).max() ?? 300) + margin * 0.7
            func room(_ line: TextLine) -> CGFloat { column - line.used.maxX }
            let anchor = noteAfter.flatMap { room($0) >= width + size * 0.8 ? $0 : nil }
                ?? lines.filter { room($0) >= width + size * 0.8 }.min { a, b in
                    abs(a.baseline - (noteAfter?.baseline ?? 0)) < abs(b.baseline - (noteAfter?.baseline ?? 0))
                }
            if let anchor {
                let start = CGPoint(x: anchor.used.maxX + size * 0.6, y: anchor.baseline)
                result += handwriting(note, at: start, scale: scale)
            } else {
                print("[markup] demo: no room on page \(page) for the note \"\(note)\"")
            }
        }

        let ink = PKInk(.pen, color: UIColor(red: 0.70, green: 0.17, blue: 0.13, alpha: 1))
        return result.filter { $0.count >= 2 }.map { points in
            stroke(points.map { $0.applying(shift) }, ink: ink)
        }
    }

    // MARK: Shapes (page coordinates)

    /// A line drawn freehand: a slow wave and a little drift, slightly long at both ends.
    private static func wobblyLine(from a: CGPoint, to b: CGPoint, amplitude: CGFloat, seed: Int) -> [CGPoint] {
        let count = max(10, Int(hypot(b.x - a.x, b.y - a.y) / 5))
        return (0 ... count).map { step in
            let t = CGFloat(step) / CGFloat(count)
            let wave = sin(t * .pi * 2.3 + CGFloat(seed)) * amplitude + sin(t * .pi * 7.1 + CGFloat(seed) * 2) * amplitude * 0.35
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + wave)
        }
    }

    /// An ellipse drawn in one go: it starts at the upper left, goes round once and overshoots,
    /// and the radius wanders so the ends don't meet.
    private static func loop(around box: CGRect) -> [CGPoint] {
        let centre = CGPoint(x: box.midX, y: box.midY)
        let count = 72
        let start = CGFloat.pi * 1.15
        let sweep = CGFloat.pi * 2.18
        return (0 ... count).map { step in
            let t = CGFloat(step) / CGFloat(count)
            let angle = start + sweep * t
            let drift = 1 + 0.07 * t + 0.03 * sin(t * .pi * 3)
            return CGPoint(x: centre.x + cos(angle) * box.width / 2 * drift,
                           y: centre.y + sin(angle) * box.height / 2 * (drift + 0.04 * t) - 1.5 * t)
        }
    }

    /// A square bracket in the margin beside a paragraph, open toward the text.
    private static func bracket(x: CGFloat, top: CGFloat, bottom: CGFloat, size: CGFloat) -> [CGPoint] {
        let tick = size * 0.45
        var points = [CGPoint(x: x + tick, y: top - 1), CGPoint(x: x + tick * 0.4, y: top - 0.2), CGPoint(x: x + 0.5, y: top + 1.5)]
        let count = max(8, Int((bottom - top) / 8))
        for step in 1 ..< count {
            let t = CGFloat(step) / CGFloat(count)
            points.append(CGPoint(x: x + sin(t * .pi * 1.7) * 0.9 - t * 0.8, y: top + (bottom - top) * t))
        }
        points += [CGPoint(x: x - 0.6, y: bottom - 1.5), CGPoint(x: x + tick * 0.35, y: bottom + 0.2), CGPoint(x: x + tick * 1.05, y: bottom + 0.6)]
        return points
    }

    // MARK: Handwriting

    /// Single-stroke cursive letters in x-height units (y up from the baseline), drawn joined.
    /// Only what the screenshots write; other characters are skipped with a log line.
    private static let letters: [Character: (width: CGFloat, strokes: [[CGPoint]])] = [
        "y": (0.95, [[CGPoint(x: -0.05, y: 0.75), CGPoint(x: 0.05, y: 1.0), CGPoint(x: 0.08, y: 0.55), CGPoint(x: 0.18, y: 0.12),
                      CGPoint(x: 0.35, y: 0.0), CGPoint(x: 0.5, y: 0.15), CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.66, y: 1.0),
                      CGPoint(x: 0.62, y: 0.5), CGPoint(x: 0.58, y: 0.0), CGPoint(x: 0.52, y: -0.5), CGPoint(x: 0.42, y: -0.9),
                      CGPoint(x: 0.28, y: -1.05), CGPoint(x: 0.18, y: -0.9), CGPoint(x: 0.25, y: -0.6), CGPoint(x: 0.5, y: -0.3),
                      CGPoint(x: 0.95, y: 0.12)]]),
        "e": (0.62, [[CGPoint(x: 0.0, y: 0.12), CGPoint(x: 0.25, y: 0.45), CGPoint(x: 0.35, y: 0.75), CGPoint(x: 0.27, y: 0.95),
                      CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.02, y: 0.6), CGPoint(x: 0.05, y: 0.25), CGPoint(x: 0.2, y: 0.03),
                      CGPoint(x: 0.43, y: 0.0), CGPoint(x: 0.62, y: 0.15)]]),
        "s": (0.5, [[CGPoint(x: 0.0, y: 0.15), CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.2, y: 0.97), CGPoint(x: 0.3, y: 0.7),
                     CGPoint(x: 0.4, y: 0.45), CGPoint(x: 0.42, y: 0.2), CGPoint(x: 0.32, y: 0.02), CGPoint(x: 0.15, y: 0.0),
                     CGPoint(x: 0.06, y: 0.08)]]),
        "!": (0.35, [[CGPoint(x: 0.25, y: 1.75), CGPoint(x: 0.21, y: 1.2), CGPoint(x: 0.17, y: 0.6), CGPoint(x: 0.15, y: 0.4)],
                     [CGPoint(x: 0.12, y: 0.06), CGPoint(x: 0.15, y: 0.09), CGPoint(x: 0.14, y: 0.03)]]),
        " ": (0.5, []),
    ]

    private static func handwritingWidth(_ text: String) -> CGFloat {
        text.reduce(0) { $0 + (letters[$1]?.width ?? 0) } + 0.2
    }

    /// `text` written from `start` (its baseline, page coordinates), letters joined into one
    /// stroke until a break (a space, a "!"), slanted like a hand.
    private static func handwriting(_ text: String, at start: CGPoint, scale: CGFloat) -> [[CGPoint]] {
        var strokes: [[CGPoint]] = []
        var current: [CGPoint] = []
        var x: CGFloat = 0
        for character in text {
            guard let letter = letters[character] else {
                print("[markup] demo: the hand can't write \"\(character)\"")
                continue
            }
            if letter.strokes.count == 1, character != "!" {
                current += letter.strokes[0].map { CGPoint(x: $0.x + x, y: $0.y) }
            } else {
                if !current.isEmpty { strokes.append(current); current = [] }
                strokes += letter.strokes.map { $0.map { CGPoint(x: $0.x + x, y: $0.y) } }
            }
            x += letter.width
        }
        if !current.isEmpty { strokes.append(current) }
        return strokes.map { stroke in
            smooth(stroke).map { p in
                CGPoint(x: start.x + (p.x + p.y * 0.22) * scale, y: start.y - p.y * scale)
            }
        }
    }

    /// Catmull-Rom through the points, so the B-spline PencilKit draws stays near them.
    private static func smooth(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out: [CGPoint] = []
        for i in 0 ..< points.count - 1 {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            for step in 0 ..< 4 {
                let t = CGFloat(step) / 4, t2 = t * t, t3 = t2 * t
                func c(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    private static func stroke(_ points: [CGPoint], ink: PKInk) -> PKStroke {
        let count = points.count
        let controlPoints = points.enumerated().map { index, point in
            // Lighter at the ends, as a pen lands and lifts.
            let t = CGFloat(index) / CGFloat(max(1, count - 1))
            let pressure = 0.75 + 0.25 * sin(t * .pi)
            return PKStrokePoint(location: point, timeOffset: TimeInterval(index) * 0.012,
                                 size: CGSize(width: 3 * pressure, height: 3 * pressure),
                                 opacity: 1, force: pressure, azimuth: 0.6, altitude: .pi / 3)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: .now),
                        transform: .identity, mask: nil, randomSeed: UInt32.random(in: 1 ... .max))
    }
}
#endif
