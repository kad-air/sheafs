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
    /// Camera holes to keep the margins clear of, in the reader's coordinate space.
    var occlusions: [CGRect] = []

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
        var occlusions: [CGRect]
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

    /// The occlusions the page must keep clear of: those in the top quarter of the content that are
    /// not merely the housing around another one. The cover display reports its camera twice, as
    /// the hole (37 pt square) and as the strip around it (84 × 82 pt); Books runs the text right
    /// up to the hole, so only the hole counts.
    static func cameraHoles(in occlusions: [CGRect], content: CGRect) -> [CGRect] {
        occlusions.filter { region in
            let hit = region.intersection(content)
            guard !hit.isNull, !hit.isEmpty, region.minY < content.minY + content.height / 4 else { return false }
            let housesAnother = occlusions.contains { other in other != region && region.contains(other) }
            return !housesAnother
        }
    }

    static func compute(_ input: Input) -> PageLayout {
        var content = CGRect(origin: .zero, size: input.size).inset(by: UIEdgeInsets(
            top: input.safeArea.top, left: input.fullBleed ? 0 : input.safeArea.leading,
            bottom: input.safeArea.bottom, right: input.fullBleed ? 0 : input.safeArea.trailing))
        content = content.standardized
        guard content.width > 60, content.height > 60 else {
            return PageLayout(pageFrames: [content], textInsets: .zero, deckFrame: nil, occlusions: [])
        }

        // A camera hole in the top part of the page widens the head band so the text starts just
        // below it; the frame itself stays put and the running head moves aside (`PageView.headFrame`).
        let holes = cameraHoles(in: input.occlusions, content: content)
        var topBand = headerHeight
        for hole in holes { topBand = max(topBand, hole.maxY - content.minY + 2) }
        let insets = UIEdgeInsets(top: topBand, left: input.margin, bottom: footerHeight, right: input.margin)
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
            return PageLayout(pageFrames: [left, right], textInsets: insets, deckFrame: deck, occlusions: holes)
        }

        // Single page: cap the measure so long lines stay readable on wide screens.
        let maxMeasure = input.fontSize * 38 + input.margin * 2
        let width = min(content.width, maxMeasure).rounded(.down)
        let frame = CGRect(x: (content.midX - width / 2).rounded(), y: content.minY, width: width, height: content.height)
        return PageLayout(pageFrames: [frame], textInsets: insets, deckFrame: deck, occlusions: holes)
    }
}

/// The reserved regions of the window, in window coordinates. They must come from a reader that
/// spans the whole window, safe area included: the device reports only the regions that intersect
/// the reader's frame, and the cover display's camera sits in the vertical bar's strip, outside
/// the safe area (the simulator reports every region regardless, which hid this).
struct WindowRegions: Equatable {
    var division: CGRect?
    var divisionIsActive: Bool
    var occlusions: [CGRect]

    init(proxy: GeometryProxy) {
        let origin = proxy.frame(in: .global).origin
        func inWindow(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: origin.x, dy: origin.y) }
        division = proxy.reservedRegions(kind: .division, options: [.includeInactive]).first.map { inWindow($0.frame) }
        divisionIsActive = !proxy.reservedRegions(kind: .division).isEmpty
        occlusions = proxy.reservedRegions(kind: .occlusion).map { inWindow($0.frame) }
    }
}

/// Keeps the text still while anything but the display itself changes. The bars (status bar,
/// toolbar, progress strip) change the reader's safe areas, and the system reports the status-bar
/// cluster and Live Activities as OCCLUSION regions, the same kind as the cover display's camera
/// hole (the API has no way to tell hardware from system UI). None of that may move the text. So the
/// geometry the page avoids (safe areas and occlusions) is learned once per display state (window
/// size + fold) while the reader settles, then locked: later changes on the same display are
/// ignored. A fold, unfold or rotation starts a new display state and is followed at once.
struct SteadyPageGeometry {
    /// What makes a display state: changes here re-lay the pages; anything else is held.
    struct Display: Equatable {
        var size: CGSize
        var division: CGRect?
        var divisionIsActive: Bool
        init(_ input: PageLayout.Input) {
            size = input.size
            division = input.division
            divisionIsActive = input.divisionIsActive
        }
    }

    /// The locked input for the current display (its safe areas and occlusions are the ones used).
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
    /// safe areas and occlusions while the display is the same.
    func input(for fresh: PageLayout.Input) -> PageLayout.Input {
        var used = fresh
        if let reading, Display(reading) == Display(fresh) {
            used.safeArea = reading.safeArea
            used.occlusions = reading.occlusions
        }
        return used
    }

    func isHolding(_ fresh: PageLayout.Input) -> Bool {
        guard let reading, Display(reading) == Display(fresh) else { return false }
        return reading.safeArea != fresh.safeArea || reading.occlusions != fresh.occlusions
    }
}
