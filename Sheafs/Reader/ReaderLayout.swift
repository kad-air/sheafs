import SwiftUI
import UIKit

/// Where pages go on screen: one page, or a two-page spread with the gutter on the fold.
struct PageLayout: Equatable {
    /// Frames of the page views (1 or 2), in the reader's coordinate space.
    var pageFrames: [CGRect]
    /// Insets from a page view's edges to its text container.
    var textInsets: UIEdgeInsets
    /// The region below a horizontal active fold (tabletop pose) left free for controls, if any.
    var deckFrame: CGRect?
    /// The cover display's camera hole, in the reader's coordinate space (`CoverCamera`).
    var camera: CGRect?

    var isSpread: Bool { pageFrames.count == 2 }
    var pageViewSize: CGSize { pageFrames.first?.size ?? .zero }
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
        var margin: CGFloat
        var fontSize: CGFloat
        var allowSpread: Bool
        /// Let the pages run the full width (under the vertical bar's strip); the bars overlay on tap.
        var fullBleed = false
    }

    /// Bands for the folio and the running head (Books: folio centred 50 pt above the display's
    /// bottom edge on the cover display, 16 pt above the home indicator's zone).
    static let footerHeight: CGFloat = 30
    static let headerHeight: CGFloat = 36

    /// The gutter of a spread on a fold: the fold's region plus 2 pt each side, never narrower than
    /// the 40 pt region the Duo reports for its hinge. The same in every pose, so unfolding from
    /// book pose to flat (or back) keeps the pages, and therefore every line break, exactly as they
    /// were; only whether the region is active changes between those poses, not where the text goes.
    static let minimumFoldGutter: CGFloat = 44

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
        let insets = UIEdgeInsets(top: topBand, left: input.margin, bottom: bottomBand, right: input.margin)
        var deck: CGRect?

        if let fold = input.division, fold.width >= fold.height, input.divisionIsActive,
           fold.minY > content.minY + 120, content.maxY - fold.maxY > 80 {
            // Tabletop / laptop pose: the page lives on the upper half, controls on the lower half.
            deck = CGRect(x: content.minX, y: fold.maxY, width: content.width, height: content.maxY - fold.maxY)
            content = CGRect(x: content.minX, y: content.minY, width: content.width, height: fold.minY - content.minY)
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
            let left = CGRect(x: leftEdge - width, y: content.minY, width: width, height: content.height)
            let right = CGRect(x: rightEdge, y: content.minY, width: width, height: content.height)
            return PageLayout(pageFrames: [left, right], textInsets: insets, deckFrame: deck, camera: camera)
        }

        // Single page: cap the measure so long lines stay readable on wide screens.
        let maxMeasure = input.fontSize * 38 + input.margin * 2
        let width = min(content.width, maxMeasure).rounded(.down)
        let frame = CGRect(x: (content.midX - width / 2).rounded(), y: content.minY, width: width, height: content.height)
        return PageLayout(pageFrames: [frame], textInsets: insets, deckFrame: deck, camera: camera)
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
        // Interface landscape-right = the phone's top edge on the left: the hole comes to the top left.
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
        division = proxy.reservedRegions(kind: .division, options: [.includeInactive]).first.map { inWindow($0.frame) }
        divisionIsActive = !proxy.reservedRegions(kind: .division).isEmpty
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

    func isHolding(_ fresh: PageLayout.Input) -> Bool {
        guard let reading, Display(reading) == Display(fresh) else { return false }
        return reading.safeArea != fresh.safeArea
    }
}
