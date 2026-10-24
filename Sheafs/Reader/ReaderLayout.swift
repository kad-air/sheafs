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
    }

    static let footerHeight: CGFloat = 30
    static let headerHeight: CGFloat = 14

    static func compute(_ input: Input) -> PageLayout {
        var content = CGRect(origin: .zero, size: input.size).inset(by: UIEdgeInsets(
            top: input.safeArea.top, left: input.safeArea.leading,
            bottom: input.safeArea.bottom, right: input.safeArea.trailing))
        // An active occlusion (the inner camera) that reaches into the content from the top pushes
        // the content down; one inside the bars' safe area doesn't touch the content at all.
        for region in input.occlusions {
            let hit = region.intersection(content)
            guard !hit.isNull, !hit.isEmpty, hit.minY <= content.minY + 1 else { continue }
            let cut = hit.maxY - content.minY
            content.origin.y += cut
            content.size.height -= cut
        }
        content = content.standardized
        guard content.width > 60, content.height > 60 else {
            return PageLayout(pageFrames: [content], textInsets: .zero, deckFrame: nil)
        }

        let insets = UIEdgeInsets(top: headerHeight, left: input.margin, bottom: footerHeight, right: input.margin)
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
            return PageLayout(pageFrames: [left, right], textInsets: insets, deckFrame: deck)
        }

        // Single page: cap the measure so long lines stay readable on wide screens.
        let maxMeasure = input.fontSize * 38 + input.margin * 2
        let width = min(content.width, maxMeasure)
        let frame = CGRect(x: content.midX - width / 2, y: content.minY, width: width, height: content.height)
        return PageLayout(pageFrames: [frame], textInsets: insets, deckFrame: deck)
    }
}
