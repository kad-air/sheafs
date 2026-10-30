import SwiftUI
import UIKit
import PencilKit
import SheafsKit

/// A marking a markup session saved or removed; `ReaderView` writes it to the library.
enum SketchEdit {
    case save(SketchSave)
    case delete(UUID)
}

/// A marking as it is to be stored.
struct SketchSave {
    var mark: SketchMark
    var range: NSRange
    var startPointer: String?
    var endPointer: String?
    var text: String
    var thumbnail: Data?
    var isNew: Bool
}

/// Marking up the spread on screen: a PencilKit canvas over each page, holding the page's strokes
/// placed for the layout on screen, with the system tool picker. `commit` reads the canvases back:
/// strokes are told apart by their seeds; a marking with a stroke changed, erased, moved or added
/// near it is captured again (`SketchLayout.capture`) from what the canvases show, the parts of it
/// on no canvas (on another page) kept as they were; new strokes on their own form new markings,
/// one per cluster of strokes drawn close together.
final class MarkupSession: NSObject, PKCanvasViewDelegate {
    private let session: BookSession
    let toolPicker = PKToolPicker()
    private var palette = ReaderPalette.paper

    private struct Page {
        let canvas: PKCanvasView
        let pageView: PageView
        let chapter: PaginatedChapter
        let page: Int
        /// The placed strokes the canvas started with, by seed.
        let loaded: [UInt32: SketchLayout.Placed]
    }

    private var pages: [Page] = []
    var isActive: Bool { !pages.isEmpty }

    init(session: BookSession) {
        self.session = session
        super.init()
    }

    /// Puts a canvas over every page of `spread` that shows text.
    func attach(to spread: SpreadViewController, palette: ReaderPalette) {
        detach()
        self.palette = palette
        toolPicker.colorUserInterfaceStyle = palette.isDark ? .dark : .light
        toolPicker.overrideUserInterfaceStyle = palette.isDark ? .dark : .light
        for (index, pageView) in spread.pageViews.enumerated() {
            guard index < spread.slots.count, let slot = spread.slots[index], let chapter = pageView.chapter else { continue }
            let placed = pageView.sketchStrokes()
            let canvas = PKCanvasView(frame: pageView.bounds)
            canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.drawingPolicy = .default
            canvas.isScrollEnabled = false
            canvas.contentInsetAdjustmentBehavior = .never
            canvas.overrideUserInterfaceStyle = palette.isDark ? .dark : .light
            canvas.drawing = PKDrawing(strokes: placed.map(\.stroke))
            canvas.delegate = self
            canvas.accessibilityLabel = "Markup canvas"
            toolPicker.addObserver(canvas)
            pageView.addSubview(canvas)
            pageView.hidesSketches = true
            let loaded = Dictionary(placed.map { ($0.stroke.randomSeed, $0) }, uniquingKeysWith: { first, _ in first })
            pages.append(Page(canvas: canvas, pageView: pageView, chapter: chapter, page: slot.page, loaded: loaded))
        }
        if let first = pages.first?.canvas {
            toolPicker.setVisible(true, forFirstResponder: first)
            first.becomeFirstResponder()
        }
    }

    /// Takes the canvases away (commit first); the pages draw their strokes again.
    func detach() {
        for page in pages {
            toolPicker.setVisible(false, forFirstResponder: page.canvas)
            toolPicker.removeObserver(page.canvas)
            page.canvas.resignFirstResponder()
            page.canvas.removeFromSuperview()
            page.pageView.hidesSketches = false
        }
        pages = []
    }

    /// What changed on the canvases since they were put up, as edits; the session's sketches are
    /// brought up to date at once, so a page laid out next (a turn) already shows them.
    func commit() -> [SketchEdit] {
        guard !pages.isEmpty else { return [] }
        var matched: [UUID: [(page: Int, stroke: PKStroke)]] = [:]
        var shown: [UUID: [Int: Set<Int>]] = [:]
        var touched: Set<UUID> = []
        var fresh: [(page: Int, strokes: [PKStroke])] = []
        for (pageIndex, page) in pages.enumerated() {
            var seen: Set<UInt32> = []
            var added: [PKStroke] = []
            for stroke in page.canvas.drawing.strokes {
                // A copy pasted with the lasso keeps its seed: only the first one is the original.
                if let loaded = page.loaded[stroke.randomSeed], !seen.contains(stroke.randomSeed) {
                    seen.insert(stroke.randomSeed)
                    matched[loaded.sketchID, default: []].append((pageIndex, stroke))
                    if !Self.same(stroke, loaded.stroke) { touched.insert(loaded.sketchID) }
                } else {
                    added.append(stroke)
                }
            }
            for (seed, loaded) in page.loaded {
                shown[loaded.sketchID, default: [:]][loaded.strokeIndex, default: []].formUnion(loaded.points)
                if !seen.contains(seed) { touched.insert(loaded.sketchID) }
            }
            if !added.isEmpty { fresh.append((pageIndex, added)) }
        }

        // New strokes in clusters, page by page; a cluster drawn against a marking already on that
        // page (a second stroke under a circle) becomes part of it.
        let gap = CGFloat(session.style?.fontSize ?? 17) * 0.8
        var joined: [UUID: [(page: Int, strokes: [PKStroke])]] = [:]
        var created: [(page: Int, strokes: [PKStroke])] = []
        for (pageIndex, strokes) in fresh {
            let page = pages[pageIndex]
            for cluster in Self.clusters(strokes.flatMap(SketchLayout.normalized), gap: gap) {
                let box = cluster.reduce(CGRect.null) { $0.union($1.renderBounds) }.insetBy(dx: -gap, dy: -gap)
                let near = page.loaded.values
                    .filter { $0.stroke.renderBounds.intersects(box) && matched[$0.sketchID] != nil }
                    .min { Self.distance($0.stroke.renderBounds, box) < Self.distance($1.stroke.renderBounds, box) }
                if let near {
                    joined[near.sketchID, default: []].append((pageIndex, cluster))
                    touched.insert(near.sketchID)
                } else {
                    created.append((pageIndex, cluster))
                }
            }
        }

        let version = Date.now
        var edits: [SketchEdit] = []
        for id in touched.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let mark = session.sketches.first(where: { $0.id == id }) else { continue }
            var strokes: [PKStroke] = []
            var anchors: [StrokeAnchors] = []
            var covers: [NSRange] = []
            // The parts on no canvas, as they were.
            for (index, stroke) in mark.drawing.strokes.enumerated() where index < mark.anchors.strokes.count {
                let onCanvas = shown[id]?[index] ?? []
                let points = Array(stroke.path)
                var run: [Int] = []
                func keep() {
                    guard !run.isEmpty else { return }
                    let part = Self.subset(mark.anchors.strokes[index], run)
                    strokes.append(PKStroke(ink: stroke.ink,
                                            path: PKStrokePath(controlPoints: run.map { points[$0] }, creationDate: stroke.path.creationDate),
                                            transform: .identity, mask: nil, randomSeed: stroke.randomSeed))
                    anchors.append(part)
                    if let range = SketchLayout.covers(part) { covers.append(range) }
                    run = []
                }
                for point in points.indices {
                    if onCanvas.contains(point) { keep() } else { run.append(point) }
                }
                keep()
            }
            var byPage: [Int: [PKStroke]] = [:]
            for item in matched[id] ?? [] { byPage[item.page, default: []].append(item.stroke) }
            for item in joined[id] ?? [] { byPage[item.page, default: []] += item.strokes }
            var thumbnail: Data?
            for (pageIndex, list) in byPage.sorted(by: { $0.key < $1.key }) {
                let captured = capture(list, on: pages[pageIndex])
                strokes += captured.strokes
                anchors += captured.anchors
                if let range = captured.covers { covers.append(range) }
                if thumbnail == nil { thumbnail = Self.thumbnail(of: list, on: pages[pageIndex], palette: palette) }
            }
            guard !strokes.isEmpty else {
                edits.append(.delete(id))
                continue
            }
            let updated = SketchMark(id: id, spineIndex: mark.spineIndex, version: version,
                                     drawing: PKDrawing(strokes: strokes), anchors: SketchAnchors(strokes: anchors))
            edits.append(.save(save(updated, covers: covers, thumbnail: thumbnail, isNew: false)))
        }
        for (pageIndex, cluster) in created {
            let page = pages[pageIndex]
            let captured = capture(cluster, on: page)
            guard !captured.strokes.isEmpty else { continue }
            let mark = SketchMark(id: UUID(), spineIndex: page.chapter.spineIndex, version: version,
                                  drawing: PKDrawing(strokes: captured.strokes), anchors: SketchAnchors(strokes: captured.anchors))
            edits.append(.save(save(mark, covers: captured.covers.map { [$0] } ?? [],
                                    thumbnail: Self.thumbnail(of: cluster, on: page, palette: palette), isNew: true)))
        }

        var sketches = session.sketches
        for edit in edits {
            switch edit {
            case .delete(let id):
                sketches.removeAll { $0.id == id }
            case .save(let save):
                SketchMark.remember(save.mark)
                if let index = sketches.firstIndex(where: { $0.id == save.mark.id }) {
                    sketches[index] = save.mark
                } else {
                    sketches.append(save.mark)
                }
            }
        }
        session.sketches = sketches
        return edits
    }

    /// Strokes as a canvas over `page` holds them (the page view's coordinates), captured in the
    /// page's text coordinates.
    private func capture(_ strokes: [PKStroke], on page: Page) -> (strokes: [PKStroke], anchors: [StrokeAnchors], covers: NSRange?) {
        let origin = page.pageView.textOrigin
        let shift = CGAffineTransform(translationX: -origin.x, y: -origin.y)
        let local = strokes.map { stroke in
            var stroke = stroke
            stroke.transform = stroke.transform.concatenating(shift)
            return stroke
        }
        return SketchLayout.capture(local, chapter: page.chapter, page: page.page)
    }

    private func save(_ mark: SketchMark, covers: [NSRange], thumbnail: Data?, isNew: Bool) -> SketchSave {
        let spine = mark.spineIndex
        let length = spine < session.chapters.count ? session.chapters[spine].textLength : 0
        var range = covers.reduce(nil as NSRange?) { union, range in union.map { NSUnionRange($0, range) } ?? range }
            ?? mark.anchoredRange.map { NSRange(location: $0.lowerBound, length: $0.count) }
            ?? NSRange(location: 0, length: 0)
        range.location = max(0, min(range.location, length))
        range.length = max(0, min(range.length, length - range.location))
        let start = ReadingLocation(spineIndex: spine, textOffset: range.location)
        let end = ReadingLocation(spineIndex: spine, textOffset: NSMaxRange(range))
        let text = spine < session.chapters.count
            ? AnnotationExport.quoteText(session.chapters[spine].displayText(in: range.location ..< NSMaxRange(range)))
            : ""
        return SketchSave(mark: mark, range: range, startPointer: session.xpointer(for: start)?.serialized,
                          endPointer: session.xpointer(for: end)?.serialized, text: text, thumbnail: thumbnail, isNew: isNew)
    }

    // MARK: Helpers

    /// The same stroke the canvas was given: not moved, recoloured, resized or erased into.
    private static func same(_ a: PKStroke, _ b: PKStroke) -> Bool {
        guard a.transform == b.transform, a.mask == nil, a.ink.inkType == b.ink.inkType,
              a.path.count == b.path.count, let firstA = a.path.first, let firstB = b.path.first,
              let lastA = a.path.last, let lastB = b.path.last else { return false }
        return hypot(firstA.location.x - firstB.location.x, firstA.location.y - firstB.location.y) < 0.01
            && hypot(lastA.location.x - lastB.location.x, lastA.location.y - lastB.location.y) < 0.01
            && a.ink.color.isEqual(b.ink.color)
    }

    private static func subset(_ anchors: StrokeAnchors, _ indices: [Int]) -> StrokeAnchors {
        StrokeAnchors(kind: anchors.kind, edge: anchors.edge, characters: indices.map { anchors.characters[$0] },
                      dx: indices.map { anchors.dx[$0] }, dy: indices.map { anchors.dy[$0] },
                      lineStarts: indices.map { anchors.lineStarts[$0] })
    }

    /// Strokes grouped by nearness: two strokes whose bounds come within `gap` are one marking.
    static func clusters(_ strokes: [PKStroke], gap: CGFloat) -> [[PKStroke]] {
        let boxes = strokes.map { $0.renderBounds.insetBy(dx: -gap / 2, dy: -gap / 2) }
        var parent = Array(strokes.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in strokes.indices {
            for j in strokes.indices where j > i && boxes[i].intersects(boxes[j]) {
                parent[root(j)] = root(i)
            }
        }
        var groups: [Int: [PKStroke]] = [:]
        var order: [Int] = []
        for i in strokes.indices {
            let r = root(i)
            if groups[r] == nil { order.append(r) }
            groups[r, default: []].append(strokes[i])
        }
        return order.compactMap { groups[$0] }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// The marking over its text, cut from the page as it is drawn now, for the notes list.
    private static func thumbnail(of strokes: [PKStroke], on page: Page, palette: ReaderPalette) -> Data? {
        let drawing = PKDrawing(strokes: strokes)
        let bounds = page.pageView.bounds
        var crop = drawing.bounds.insetBy(dx: -18, dy: -18)
        if crop.height < 64 { crop = crop.insetBy(dx: 0, dy: (crop.height - 64) / 2) }
        crop = crop.intersection(bounds).integral
        guard !crop.isNull, crop.width > 4, crop.height > 4 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, 1200 / crop.width)
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: crop.size, format: format).image { context in
            palette.background.setFill()
            context.fill(CGRect(origin: .zero, size: crop.size))
            context.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            page.chapter.draw(page: page.page, at: page.pageView.textOrigin)
            UITraitCollection(userInterfaceStyle: palette.isDark ? .dark : .light).performAsCurrent {
                drawing.image(from: crop, scale: format.scale).draw(in: crop)
            }
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}

/// The markup controls: page back, Done, page forward, in a glass capsule over the page.
struct MarkupBar: View {
    var onPrevious: () -> Void
    var onDone: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button("Previous Page", systemImage: "chevron.backward", action: onPrevious)
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 36)
                .contentShape(.rect)
            Divider().frame(height: 18)
            Button(action: onDone) {
                Label("Done", systemImage: "pencil.tip.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
            }
            Divider().frame(height: 18)
            Button("Next Page", systemImage: "chevron.forward", action: onNext)
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .contain)
    }
}
