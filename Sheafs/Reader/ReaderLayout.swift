import SwiftUI
import UIKit

/// The reader's three margins (`ReaderSettings`), in points. `side`: each page's OUTER edge to the
/// text (a single page's left and right; a spread's two outer edges only). `gutter`: on a spread,
/// each page's edge at the fold to the text, so the space between the two columns is the fold plus
/// twice this. `vertical`: the page's top edge to the text where nothing else is in the head band;
/// past the least (`PageLayout.headerHeight`, the running head's band) the extra goes between the
/// running head and the text and, the same amount, between the text and the folio.
nonisolated struct PageMargins: Equatable, Sendable {
    var side: CGFloat
    var gutter: CGFloat
    var vertical: CGFloat

    /// What the one margin setting drew at its default (24): a spread's fold gap was the fold plus
    /// 24 a side, and the top and bottom were fixed.
    static let standard = PageMargins(side: 24, gutter: 24, vertical: 36)
}

/// Where pages go on screen: one page, or a two-page spread with the gutter on the fold.
struct PageLayout: Equatable {
    /// Frames of the page views (1 or 2), in the reader's coordinate space.
    var pageFrames: [CGRect]
    /// Insets from a page view's edges to its text container: a single page's, or a spread's RIGHT
    /// page's (its left inset is the gutter's, at the fold). The left page mirrors them
    /// (`textInsets(ofPage:)`); both are the same width, so one pagination serves both pages.
    var textInsets: UIEdgeInsets
    /// How far the text stands off the running head's band above it and the folio's band below it:
    /// the top and bottom margins beyond the least. The head and folio stay at the page's edges.
    var bandGap: CGFloat = 0
    /// The region below a horizontal active fold (tabletop pose) left free for controls, if any. The
    /// page above it ends at the fold's middle, so the two meet only through the fold's lower half.
    var deckFrame: CGRect?
    /// The cover display's camera hole, in the reader's coordinate space (`CoverCamera`).
    var camera: CGRect?

    var isSpread: Bool { pageFrames.count == 2 }
    var pageViewSize: CGSize { pageFrames.first?.size ?? .zero }
    /// The space between a spread's two pages that no text enters (the fold's region, or an iPad's
    /// middle); nil for one page. The gap between the two columns of text is this plus both gutters.
    var foldGap: CGFloat? { isSpread ? pageFrames[1].minX - pageFrames[0].maxX : nil }

    /// The text insets of page `index`: the left page of a spread mirrors `textInsets` (the side
    /// margin on its left, the gutter on its right, at the fold).
    func textInsets(ofPage index: Int) -> UIEdgeInsets {
        guard isSpread, index == 0 else { return textInsets }
        var mirrored = textInsets
        swap(&mirrored.left, &mirrored.right)
        return mirrored
    }
    /// The text container size shared by every page.
    var textSize: CGSize {
        let s = pageViewSize
        return CGSize(width: max(10, s.width - textInsets.left - textInsets.right),
                      height: max(10, s.height - textInsets.top - textInsets.bottom))
    }

    struct Input: Equatable {
        var size: CGSize
        var safeArea: EdgeInsets
        /// The division (fold) region including inactive ones, if the device has a fold.
        var division: CGRect?
        var divisionIsActive: Bool
        /// The cover display's camera hole in window coordinates, or nil on any other display.
        var camera: CGRect?
        var margins: PageMargins
        var fontSize: CGFloat
        var allowSpread: Bool
        /// Let the pages run the full width (under the vertical bar's strip); the bars overlay on tap.
        var fullBleed = false
    }

    /// Bands for the folio and the running head (Books: folio centred 50 pt above the display's
    /// bottom edge on the cover display, 16 pt above the home indicator's zone).
    static let footerHeight: CGFloat = 30
    static let headerHeight: CGFloat = 36

    /// How far above the window's bottom edge a SPREAD's pages stop (at most the bottom safe area).
    /// The home indicator is centred on the display, so on a spread it sits in the gutter (on the
    /// Duo, on the fold), under neither folio: the bottom safe area (34 pt on the Duo's inner
    /// display) is no reason to lift the folio band off the foot of the page. 🔴 The pages used to
    /// stop at the safe area with the 30 pt band on top of it: the folio's ink ended 43 pt above the
    /// edge, a band of empty page under it. At 6 pt its ink ends ~15 pt above the edge, as far as
    /// the running head's begins below the top, and the text is 28 pt taller (a line at 19 pt).
    /// A single page keeps to the safe area: the indicator is right under its folio.
    static let spreadFootInset: CGFloat = 6

    /// The gutter of a spread on a fold: the fold's region plus 2 pt each side, never narrower than
    /// the 40 pt region the Duo reports for its hinge. The same in every pose, so unfolding from
    /// book pose to flat (or back) keeps the pages, and therefore every line break, exactly as they
    /// were; only whether the region is active changes between those poses, not where the text goes.
    static let minimumFoldGutter: CGFloat = 44

    /// The window's size from a reader inside the safe area: its size plus its insets, on whole
    /// pixels. 🔴 Summed as is, the bars' insets (thirds of a point) can leave it an ulp off the
    /// window (677.9999999999999 for 678), and every comparison downstream (`SteadyPageGeometry`,
    /// the page frames, the pagination cache's page size) is exact. Window sizes are whole pixels.
    static func windowSize(content: CGSize, insets: EdgeInsets, scale: CGFloat) -> CGSize {
        let scale = max(1, scale)
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGSize(width: snapped(content.width + insets.leading + insets.trailing),
                      height: snapped(content.height + insets.top + insets.bottom))
    }

    static func compute(_ input: Input) -> PageLayout {
        var content = CGRect(origin: .zero, size: input.size).inset(by: UIEdgeInsets(
            top: input.safeArea.top, left: input.fullBleed ? 0 : input.safeArea.leading,
            bottom: input.safeArea.bottom, right: input.fullBleed ? 0 : input.safeArea.trailing))
        content = content.standardized
        guard content.width > 60, content.height > 60 else {
            return PageLayout(pageFrames: [content], textInsets: .zero, deckFrame: nil, camera: nil)
        }

        // The cover camera widens the head band (or, upside down / camera at the bottom, the folio
        // band) so the text stops 2 pt short of the hole, as Books does; the frame itself stays put
        // and the running head moves aside (`PageView.headFrame`).
        var topBand = headerHeight, bottomBand = footerHeight
        let camera = input.camera.flatMap { $0.intersects(content) ? $0 : nil }
        if let hole = camera {
            if hole.midY < content.midY {
                topBand = max(topBand, hole.maxY - content.minY + 2)
            } else {
                bottomBand = max(bottomBand, content.maxY - hole.minY + 2)
            }
        }
        // Top and bottom margins past the least open a gap between the bands and the text; the
        // running head and the folio stay where they are, at the page's edges (a spread's folio
        // stays at the foot of the page, never over a band of empty page).
        let margins = input.margins
        let bandGap = max(0, margins.vertical - headerHeight)
        let insets = UIEdgeInsets(top: topBand + bandGap, left: margins.side, bottom: bottomBand + bandGap, right: margins.side)
        var deck: CGRect?

        if let fold = input.division, fold.width >= fold.height, input.divisionIsActive,
           fold.minY > content.minY + 120, content.maxY - fold.maxY > 80 {
            // Tabletop / laptop pose: the page lives on the upper half, controls on the lower half.
            // The page runs down to the MIDDLE of the fold, not its top: the folio sits in the upper
            // half of the crease (caught a little in its curve, which is fine) so the text gets that
            // much more height, and the block of pages still to read under the page's edge
            // (`TabletopBaseView`) lies wholly below the centreline. The deck still starts below it.
            deck = CGRect(x: content.minX, y: fold.maxY, width: content.width, height: content.maxY - fold.maxY)
            content = CGRect(x: content.minX, y: content.minY, width: content.width, height: fold.midY - content.minY)
        }

        let wantsSpread: Bool
        var gutterRect: CGRect?
        if input.allowSpread, let fold = input.division, fold.height >= fold.width,
           fold.minX > content.minX + 200, content.maxX - fold.maxX > 200 {
            wantsSpread = true
            let width = max(fold.width + 4, minimumFoldGutter)
            gutterRect = CGRect(x: fold.midX - width / 2, y: content.minY, width: width, height: content.height)
        } else if input.allowSpread, input.division == nil, content.width >= 820, content.width > content.height {
            // A wide screen without a fold (iPad landscape): a conventional spread.
            wantsSpread = true
            gutterRect = CGRect(x: content.midX - 14, y: content.minY, width: 28, height: content.height)
        } else {
            wantsSpread = false
        }

        // Frames land on whole points (whole pixels at any scale): the fold's region and a centred
        // measure often come out at a half point, which draws the text soft and makes the page
        // flip's textures disagree with the live page by half a pixel.
        if wantsSpread, let gutter = gutterRect {
            let leftEdge = gutter.minX.rounded(.down), rightEdge = gutter.maxX.rounded(.up)
            let width = min(leftEdge - content.minX, content.maxX - rightEdge).rounded(.down)
            // Down to `spreadFootInset` above the window's bottom, not the safe area (never with a
            // deck below: that is tabletop, where the page ends at the fold).
            let bottom = deck == nil ? input.size.height - min(input.safeArea.bottom, spreadFootInset) : content.maxY
            let height = max(content.height, bottom - content.minY)
            let left = CGRect(x: leftEdge - width, y: content.minY, width: width, height: height)
            let right = CGRect(x: rightEdge, y: content.minY, width: width, height: height)
            // The right page's insets: the gutter at the fold, the side margin outside. The page
            // frames don't depend on the margins, so neither setting moves the other's edge.
            var rightInsets = insets
            rightInsets.left = margins.gutter
            return PageLayout(pageFrames: [left, right], textInsets: rightInsets, bandGap: bandGap, deckFrame: deck, camera: camera)
        }

        // Single page: cap the measure so long lines stay readable on wide screens.
        let maxMeasure = input.fontSize * 38 + margins.side * 2
        let width = min(content.width, maxMeasure).rounded(.down)
        let frame = CGRect(x: (content.midX - width / 2).rounded(), y: content.minY, width: width, height: content.height)
        return PageLayout(pageFrames: [frame], textInsets: insets, bandGap: bandGap, deckFrame: deck, camera: camera)
    }

    /// The fold gap a spread would have in the window `proxy` spans (a reader that ignores the safe
    /// area), nil if the reader would show one page there: the Settings screen has no reader up,
    /// and shows the Gutter control where the reader would lay out a spread.
    static func foldGap(window proxy: GeometryProxy) -> CGFloat? {
        let regions = WindowRegions(proxy: proxy)
        return compute(Input(size: proxy.size, safeArea: EdgeInsets(), division: regions.division,
                             divisionIsActive: regions.divisionIsActive, camera: nil, margins: .standard,
                             fontSize: 19, allowSpread: true, fullBleed: true)).foldGap
    }
}

/// Where the Ask pane goes while it is up. Over a VERTICAL fold laid out as a spread (the Duo's inner
/// display, flat or in book pose) Ask takes the left page's side and the book stays live on the
/// right as ONE page: the spread's right page, the one holding the reading position, in the same
/// place at the same size. So opening or closing Ask (or unfolding with it up) moves no text and
/// keeps the spread's pagination; pages then turn one at a time. Neither side reaches into the fold:
/// the spread's frames already keep clear of it. Everywhere else (the cover display, inner portrait,
/// tabletop, iPhone, an iPad's fold-less spread) Ask floats over the bottom of the page.
enum AskPresentation: Equatable {
    case floating
    /// `pane`: the left page's side of the window, to its frame's right edge, full height. `book`:
    /// the pager's frame, from the right page's left edge to the window's right edge.
    case beside(pane: CGRect, book: CGRect)

    static func choose(for layout: PageLayout, division: CGRect?, window: CGSize) -> AskPresentation {
        guard layout.isSpread, let fold = division, fold.height > fold.width else { return .floating }
        let left = layout.pageFrames[0], right = layout.pageFrames[1]
        guard left.maxX <= fold.minX, right.minX >= fold.maxX, right.minX < window.width else { return .floating }
        return .beside(pane: CGRect(x: 0, y: 0, width: left.maxX, height: window.height),
                       book: CGRect(x: right.minX, y: 0, width: window.width - right.minX, height: window.height))
    }

    var isBeside: Bool { if case .beside = self { true } else { false } }

    /// The pager's frame in the window: all of it, or the book's side of the fold.
    func bookFrame(in window: CGSize) -> CGRect {
        if case .beside(_, let book) = self { return book }
        return CGRect(origin: .zero, size: window)
    }

    /// The pages as the pager lays them out in its own frame (`bookFrame`): beside Ask, the spread's
    /// right page alone, where it was in the window. Same size, so the same pagination.
    func pages(_ layout: PageLayout) -> PageLayout {
        guard case .beside(_, let book) = self, layout.isSpread else { return layout }
        var single = layout
        single.pageFrames = [layout.pageFrames[1].offsetBy(dx: -book.minX, dy: -book.minY)]
        return single
    }
}

/// Where the iPhone Duo's cover-display camera hole is, written down rather than read from the
/// system: the OCCLUSION reserved regions also carry the status-bar cluster and Live Activities (on
/// both displays, coming and going while reading) with nothing to tell them from hardware, which
/// pushed the text around. The hole is a 37 pt square 29⅓ pt in from the display's top and right
/// edges in portrait (window coordinates (399.67, 29.33, 37 × 37) on the 466 × 678 pt window, as the
/// device reports it); it turns with the interface. The cover display is the one without a fold.
enum CoverCamera {
    static let window = CGSize(width: 466, height: 678)
    static let side: CGFloat = 37
    /// From each of the two nearest display edges: 88 px at 3x, as the device reports it.
    static let inset: CGFloat = 88.0 / 3

    static func hole(window size: CGSize, hasFold: Bool, orientation: UIInterfaceOrientation) -> CGRect? {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }
        let portrait = near(size.width, window.width) && near(size.height, window.height)
        let landscape = near(size.width, window.height) && near(size.height, window.width)
        guard !hasFold, portrait || landscape else { return nil }
        // Mid-rotation the orientation can lag the size; the size wins.
        let turned = orientation.isPortrait == portrait && orientation != .unknown
            ? orientation : (portrait ? .portrait : .landscapeRight)
        let far = (x: size.width - inset - side, y: size.height - inset - side)
        let origin: CGPoint
        switch turned {
        case .portraitUpsideDown: origin = CGPoint(x: inset, y: far.y)
        // The hinge runs down the cover's RIGHT edge in portrait (the camera's side). Hinge down =
        // the phone's top edge on the left = interface landscape-right: the hole is at the top left
        // (seen on the phone). Hinge up = interface landscape-left: the bottom right.
        case .landscapeRight: origin = CGPoint(x: inset, y: inset)
        case .landscapeLeft: origin = CGPoint(x: far.x, y: far.y)
        default: origin = CGPoint(x: far.x, y: inset)
        }
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }
}

/// Reports the window scene's interface orientation (SwiftUI has none), for `CoverCamera`.
struct InterfaceOrientationReader: UIViewRepresentable {
    var onChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) { view.onChange = onChange }

    final class Probe: UIView {
        var onChange: ((UIInterfaceOrientation) -> Void)?
        private var last: UIInterfaceOrientation?

        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }

        private func report() {
            guard let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
                  orientation != last else { return }
            last = orientation
            let onChange = onChange
            // Not during the layout pass that SwiftUI is running.
            DispatchQueue.main.async { onChange?(orientation) }
        }
    }
}

/// The fold of the window, in window coordinates. It must come from a reader that spans the whole
/// window, safe area included: the device reports only the regions that intersect the reader's frame.
struct WindowRegions: Equatable {
    var division: CGRect?
    var divisionIsActive: Bool

    init(proxy: GeometryProxy) {
        let origin = proxy.frame(in: .global).origin
        func inWindow(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: origin.x, dy: origin.y) }
        division = proxy.divisions().first.map { inWindow($0.frame) }
        divisionIsActive = !proxy.divisions(includeInactive: false).isEmpty
    }
}

/// Keeps the text still while anything but the display itself changes. The bars (status bar,
/// toolbar, progress strip) change the reader's safe areas; none of that may move the text. So the
/// safe areas are learned once per display state (window size + fold + camera) while the reader
/// settles, then locked: later changes on the same display are ignored. A fold, unfold or rotation
/// starts a new display state and is followed at once.
struct SteadyPageGeometry {
    /// What makes a display state: changes here re-lay the pages; anything else is held.
    struct Display: Equatable {
        var size: CGSize
        var division: CGRect?
        var divisionIsActive: Bool
        var camera: CGRect?
        init(_ input: PageLayout.Input) {
            size = input.size
            division = input.division
            divisionIsActive = input.divisionIsActive
            camera = input.camera
        }
    }

    /// The locked input for the current display (its safe areas are the ones used).
    private(set) var reading: PageLayout.Input?
    /// Until when (seconds of system uptime) the current display's geometry is still being learned.
    private(set) var learningUntil: TimeInterval = 0

    /// How long after a new display state its geometry may still settle (the bars leave one by one
    /// after a fold hides them; the status bar goes last).
    static let learningWindow: TimeInterval = 1.5

    /// `barsVisible`: the reader's own bars are up, so the current insets are theirs, not reading ones.
    mutating func observe(_ fresh: PageLayout.Input, barsVisible: Bool, now: TimeInterval) {
        guard let reading, Display(reading) == Display(fresh) else {
            reading = fresh
            learningUntil = now + Self.learningWindow
            return
        }
        if !barsVisible, now < learningUntil { self.reading = fresh }
    }

    /// The input to lay the pages out with: `fresh` (its settings, size and fold) with the locked
    /// safe areas while the display is the same.
    func input(for fresh: PageLayout.Input) -> PageLayout.Input {
        var used = fresh
        if let reading, Display(reading) == Display(fresh) {
            used.safeArea = reading.safeArea
        }
        return used
    }

    /// Whether the bars, if they are up, must go for `fresh`: the WINDOW changed (a fold, unfold or
    /// rotation), so the insets stored for the new display would be the bars' and not the reading
    /// ones. 🔴 Within a point it is the same window: the reader rebuilds the window's size from its
    /// insets, and the bars' own arrival must never read as a new display. Compared exactly, a size an
    /// ulp off would hide the bars the moment a tap brought them up (the likely cause of the cover
    /// display's bars not coming up on the phone).
    func windowChanged(_ fresh: PageLayout.Input) -> Bool {
        guard let reading else { return false }
        return !Self.sameWindow(reading.size, fresh.size)
    }

    static func sameWindow(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    func isHolding(_ fresh: PageLayout.Input) -> Bool {
        guard let reading, Display(reading) == Display(fresh) else { return false }
        return reading.safeArea != fresh.safeArea
    }
}
