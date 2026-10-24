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
            let pad: CGFloat = input.divisionIsActive ? 2 : 14
            gutterRect = fold.insetBy(dx: -pad, dy: 0)
        } else if input.allowSpread, input.division == nil, content.width >= 820, content.width > content.height {
            // A wide screen without a fold (iPad landscape): a conventional spread.
            wantsSpread = true
            gutterRect = CGRect(x: content.midX - 14, y: content.minY, width: 28, height: content.height)
        } else {
            wantsSpread = false
        }

        if wantsSpread, let gutter = gutterRect {
            let leftWidth = gutter.minX - content.minX
            let rightWidth = content.maxX - gutter.maxX
            let width = min(leftWidth, rightWidth)
            let left = CGRect(x: gutter.minX - width, y: content.minY, width: width, height: content.height)
            let right = CGRect(x: gutter.maxX, y: content.minY, width: width, height: content.height)
            return PageLayout(pageFrames: [left, right], textInsets: insets, deckFrame: deck, occlusions: holes)
        }

        // Single page: cap the measure so long lines stay readable on wide screens.
        let maxMeasure = input.fontSize * 38 + input.margin * 2
        let width = min(content.width, maxMeasure)
        let frame = CGRect(x: content.midX - width / 2, y: content.minY, width: width, height: content.height)
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
