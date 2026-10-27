import Testing
import Foundation
import UIKit
import SwiftUI
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// Tapping a picture opens it full screen: the pager finds the picture under the finger from the
/// page's layout (`PaginatedChapter.images(onPage:)`), resolves it to its image block (source, alt),
/// and the viewer keeps to the tapped page's side of the Duo's fold. The rects are checked against
/// the RENDERED page (the picture's own pixels), not just against the layout that produced them.
@MainActor
struct ImageViewerTests {
    static let pageSize = CGSize(width: 320, height: 420)
    static let plate = "images/plate.png"
    static let pictureSize = CGSize(width: 200, height: 120)

    /// A solid red picture, in points (scale 1), so the page shows exactly where it is drawn.
    static func red(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A paragraph, the picture, and enough text after it for several pages.
    static func illustratedChapter() -> (chapter: Chapter, paginated: PaginatedChapter) {
        let filler = String(repeating: "The Hatter opened his eyes very wide on hearing this; but all he said was, why is a raven like a writing-desk? ", count: 6)
        let xhtml = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>A Mad Tea-Party.</p>
        <div class="figure"><img src="\(plate)" alt="The Hatter and the March Hare at tea"/></div>
        <p>\(filler)</p><p>\(filler)</p><p>\(filler)</p>
        </body></html>
        """
        let chapter = XHTMLConverter().convert(Data(xhtml.utf8))
        let images = ChapterImages(images: [plate: red(pictureSize)])
        let string = Typesetter.attributedString(for: chapter, style: ReaderEngineTests.style, images: images, pageSize: pageSize)
        return (chapter, PaginatedChapter(spineIndex: 3, attributedString: string, pageSize: pageSize))
    }

    /// The page's pixels, RGBA at 1x, drawn exactly as on screen (`PageView.render`).
    static func pixels(of view: PageView) -> (bytes: [UInt8], width: Int) {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            view.render(in: ctx)
        }
        return (bytes, width)
    }

    static func isRed(_ pixels: (bytes: [UInt8], width: Int), at point: CGPoint) -> Bool {
        let i = (Int(point.y) * pixels.width + Int(point.x)) * 4
        return pixels.bytes[i] > 230 && pixels.bytes[i + 1] < 30 && pixels.bytes[i + 2] < 30
    }

    @Test func aTapOnThePictureFindsItsImageBlock() throws {
        let (chapter, paginated) = Self.illustratedChapter()
        #expect(paginated.pageCount > 1)
        let block = try #require(chapter.blocks.first { if case .image = $0.kind { true } else { false } })
        let page = paginated.pageIndex(containing: block.textOffset)
        let images = paginated.images(onPage: page)
        let image = try #require(images.first)
        #expect(images.count == 1)
        // The attachment is exactly the block's one character, and carries the source as written.
        #expect(image.index == block.textOffset)
        #expect(image.source == Self.plate)
        // It draws at the picture's own size (inline pictures never upscale), inside the page, centred.
        #expect(image.rect.size == Self.pictureSize)
        #expect(CGRect(origin: .zero, size: Self.pageSize).contains(image.rect))
        #expect(abs(image.rect.midX - Self.pageSize.width / 2) <= 1)

        // A tap in its middle resolves to it, and back to the block: source and alt for the viewer.
        let tap = CGPoint(x: image.rect.midX, y: image.rect.midY)
        let hit = try #require(paginated.image(at: tap, page: page))
        #expect(hit == image)
        let resolved = try #require(chapter.block(containing: hit.index))
        #expect(resolved.kind == .image(source: Self.plate, alt: "The Hatter and the March Hare at tea"))
        // Off the picture (in the text under it, and beside it) there is nothing to open.
        #expect(paginated.image(at: CGPoint(x: image.rect.midX, y: image.rect.maxY + 40), page: page) == nil)
        #expect(paginated.image(at: CGPoint(x: image.rect.minX - 20, y: image.rect.midY), page: page) == nil)
        // No other page claims it.
        for other in 0 ..< paginated.pageCount where other != page {
            #expect(paginated.images(onPage: other).isEmpty, "page \(other)")
        }
    }

    /// The rect is where the page really paints the picture: red inside it, not red just outside.
    @Test func thePictureIsDrawnWhereTheHitTestLooks() throws {
        let (chapter, paginated) = Self.illustratedChapter()
        let block = try #require(chapter.blocks.first { if case .image = $0.kind { true } else { false } })
        let view = PageView(frame: CGRect(origin: .zero, size: CGSize(width: 360, height: 500)))
        view.textInsets = UIEdgeInsets(top: 36, left: 20, bottom: 44, right: 20)
        view.chapter = paginated
        view.page = paginated.pageIndex(containing: block.textOffset)
        let image = try #require(view.images().first)
        let pixels = Self.pixels(of: view)
        let r = image.rect
        for point in [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX + 2, y: r.minY + 2), CGPoint(x: r.maxX - 3, y: r.maxY - 3)] {
            #expect(Self.isRed(pixels, at: point), "not red inside the picture at \(point)")
        }
        for point in [CGPoint(x: r.midX, y: r.minY - 3), CGPoint(x: r.midX, y: r.maxY + 2),
                      CGPoint(x: r.minX - 3, y: r.midY), CGPoint(x: r.maxX + 2, y: r.midY)] {
            #expect(!Self.isRed(pixels, at: point), "red outside the picture at \(point)")
        }
        // The view-level lookup agrees, in view coordinates.
        #expect(view.image(at: CGPoint(x: r.midX, y: r.midY))?.index == block.textOffset)
        #expect(view.image(at: CGPoint(x: r.midX, y: r.maxY + 40)) == nil)
    }

    /// A real book: Alice's cover page is a picture alone in its chapter (an SVG `<image>`), which
    /// fills the page; the hit test finds it, and the viewer decodes the JPEG at its own 800 × 1104
    /// pixels (the size `sips` reports for the file), not the page's downsampled copy.
    @Test func aCoverPageIsOneTappablePictureAtFullResolution() throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let epub = try EPUBBook(url: url)
        let item = epub.spine[0].item
        let chapter = XHTMLConverter().convert(try epub.data(for: item))
        let block = try #require(chapter.blocks.first)
        guard case .image(let source, _) = block.kind else {
            Issue.record("the cover chapter's first block is \(block.kind), not a picture")
            return
        }
        let data = try epub.data(at: EPUBPath.resolve(EPUBPath.split(source).path, relativeTo: item.path))
        let pageImage = try #require(ImageUtilities.downsampled(data, maxPixelSize: 400))
        let string = Typesetter.attributedString(for: chapter, style: ReaderEngineTests.style,
                                                 images: ChapterImages(images: [source: pageImage]), pageSize: Self.pageSize)
        let paginated = PaginatedChapter(spineIndex: 0, attributedString: string, pageSize: Self.pageSize)
        let image = try #require(paginated.images(onPage: 0).first)
        #expect(image.source == source)
        #expect(abs(image.rect.width / image.rect.height - 800.0 / 1104) < 0.01)
        #expect(image.rect.height > Self.pageSize.height * 0.9, "a picture alone in its chapter fills the page")
        #expect(paginated.image(at: CGPoint(x: image.rect.midX, y: image.rect.midY), page: 0)?.index == block.textOffset)

        let full = try #require(ImageViewerLayout.decode(data, maxPixelSize: 4096))
        #expect(full.size.width * full.scale == 800)
        #expect(full.size.height * full.scale == 1104)
        // A huge picture is held to the cap on its long side.
        let capped = try #require(ImageViewerLayout.decode(data, maxPixelSize: 552))
        #expect(max(capped.size.width, capped.size.height) * capped.scale == 552)
    }

    /// A picture that is missing (or can't be decoded) draws a 24 pt placeholder, which is NOT a
    /// picture to open: a tap there is a tap on text.
    @Test func aMissingPictureIsNotTappable() throws {
        let xhtml = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Before.</p><img src="gone.png" alt="Lost"/><p>After.</p></body></html>
        """
        let chapter = XHTMLConverter().convert(Data(xhtml.utf8))
        let string = Typesetter.attributedString(for: chapter, style: ReaderEngineTests.style, images: ChapterImages(), pageSize: Self.pageSize)
        let paginated = PaginatedChapter(spineIndex: 0, attributedString: string, pageSize: Self.pageSize)
        let block = try #require(chapter.blocks.first { if case .image = $0.kind { true } else { false } })
        #expect(string.attribute(.attachment, at: block.textOffset, effectiveRange: nil) != nil, "the placeholder is still drawn")
        #expect(string.attribute(.sheafsImageSource, at: block.textOffset, effectiveRange: nil) == nil)
        #expect(paginated.images(onPage: 0).isEmpty)
    }

    /// The gestures, on a real pager showing Alice's cover on the cover display: a SINGLE tap on the
    /// picture does exactly what it does anywhere (the centre toggles the bars, the right edge turns
    /// the page), a DOUBLE tap opens it, and the double tap takes no touch off a picture (so a single
    /// tap there never waits for a second one).
    @Test func aSingleTapOnAPictureIsAnOrdinaryTapADoubleTapOpensIt() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        let window = CGSize(width: 466, height: 678)
        let layout = PageLayout.compute(.init(size: window, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: nil, divisionIsActive: false, camera: nil,
                                              margin: 24, fontSize: 19, allowSpread: true, fullBleed: true))
        session.configure(style: ReaderEngineTests.style, textSize: layout.textSize)
        let controller = PagerController(session: session)
        controller.pageTurn = .slide
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: window)
        var taps: [ReaderTap] = []
        controller.onTap = { taps.append($0) }
        controller.apply(layout: layout, palette: .paper, location: .start, animated: false)
        controller.currentSpread?.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        let centre = try #require(controller.imageCentre(spineIndex: 0, textOffset: 0), "the cover picture is not on the page")
        controller.tap(at: centre)
        #expect(taps == [.center], "a single tap on the picture must toggle the bars like any centre tap")
        #expect(controller.acceptsDoubleTap(at: centre))
        #expect(controller.doubleTap(at: centre))
        guard case .image(let image) = taps.last else {
            Issue.record("the double tap opened nothing: \(taps)")
            return
        }
        #expect(image.spineIndex == 0 && image.textOffset == 0)
        #expect(image.source.hasSuffix("_cover.jpg"))

        // Off the picture (the margin beside it) the double tap takes no touch and does nothing.
        let page = try #require(controller.currentSpread?.pageViews.first)
        let beside = CGPoint(x: page.frame.minX + 4, y: centre.y)
        #expect(!controller.acceptsDoubleTap(at: beside))
        #expect(!controller.doubleTap(at: beside))
        // On the picture inside the right turn zone, a single tap still turns the page.
        let edge = CGPoint(x: window.width * 0.8, y: centre.y)
        #expect(controller.acceptsDoubleTap(at: edge), "the picture reaches into the turn zone")
        taps.removeAll()
        controller.tap(at: edge)
        #expect(taps == [.next])
    }

    // Display sizes in points: cover 466×678, inner 951×669 (landscape) / 669×951 (portrait); the
    // simulator reports the hinge as (455.5, 0, 40 × 669), flat and folded.

    @Test func withoutAFoldThePictureHasTheWholeWindow() {
        let window = CGSize(width: 466, height: 678)
        #expect(ImageViewerLayout.viewport(window: window, division: nil, divisionIsActive: false,
                                           pageFrame: CGRect(x: 0, y: 0, width: 382, height: 678))
                == CGRect(origin: .zero, size: window))
    }

    /// The picture as the viewer really shows it: a `ZoomingImageView` laid out in `viewport`, its
    /// image view's frame in window coordinates.
    static func shown(_ picture: CGSize, in viewport: CGRect) -> CGRect {
        let view = ZoomingImageView(image: red(picture))
        view.frame = viewport
        view.layoutIfNeeded()
        return view.imageFrame.offsetBy(dx: viewport.minX, dy: viewport.minY)
    }

    @Test func overAVerticalFoldThePictureStaysOnTheTappedPage() {
        let window = CGSize(width: 951, height: 669)
        let hinge = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        let leftPage = CGRect(x: 0, y: 0, width: 453, height: 635)
        let rightPage = CGRect(x: 498, y: 0, width: 453, height: 635)
        for active in [true, false] {  // book pose and flat: the same, like the spread
            let left = ImageViewerLayout.viewport(window: window, division: hinge, divisionIsActive: active, pageFrame: leftPage)
            let right = ImageViewerLayout.viewport(window: window, division: hinge, divisionIsActive: active, pageFrame: rightPage)
            #expect(left == CGRect(x: 0, y: 0, width: 455.5, height: 669))
            #expect(right == CGRect(x: 495.5, y: 0, width: 455.5, height: 669))
            // Opened without a tap: the right page, which holds the reading position.
            #expect(ImageViewerLayout.viewport(window: window, division: hinge, divisionIsActive: active, pageFrame: nil) == right)
            // Whatever its shape, the picture as shown never reaches the hinge.
            for picture in [CGSize(width: 4000, height: 300), CGSize(width: 300, height: 4000), CGSize(width: 800, height: 1104)] {
                for viewport in [left, right] {
                    let shown = Self.shown(picture, in: viewport)
                    #expect(!shown.intersects(hinge), "\(picture) in \(viewport) → \(shown)")
                    #expect(viewport.insetBy(dx: -0.5, dy: -0.5).contains(shown), "\(picture) in \(viewport) → \(shown)")
                }
            }
        }
    }

    @Test func inTabletopThePictureKeepsToTheUpperHalf() {
        let window = CGSize(width: 669, height: 951)
        let fold = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let page = CGRect(x: 0, y: 0, width: 669, height: 455)
        #expect(ImageViewerLayout.viewport(window: window, division: fold, divisionIsActive: true, pageFrame: page)
                == CGRect(x: 0, y: 0, width: 669, height: 455.5))
        // Lying flat (inner display in portrait): one page, the whole window.
        #expect(ImageViewerLayout.viewport(window: window, division: fold, divisionIsActive: false, pageFrame: page)
                == CGRect(origin: .zero, size: window))
    }

    /// The viewer centres the fitted picture with the scroll view's insets (its offset showing
    /// them), whichever way it is limited: a gap above and below a wide one, beside a tall one.
    @Test func theViewerCentresThePicture() {
        let cover = CGSize(width: 800, height: 1104)
        // Width-limited on a half of the inner display: 455 × 628, gaps above and below.
        let half = CGRect(x: 495.5, y: 0, width: 455.5, height: 669)
        let tall = Self.shown(cover, in: half)
        #expect(tall.size == CGSize(width: 455, height: 628))
        #expect(abs(tall.midX - half.midX) <= 0.5)
        #expect(abs(tall.midY - half.midY) <= 0.5)
        #expect(tall.minY - half.minY > 20)
        // Height-limited in a wider viewport: 484 × 668…669, a horizontal gap each side.
        let wide = CGRect(x: 0, y: 0, width: 600, height: 669)
        let shown = Self.shown(cover, in: wide)
        #expect(shown.height >= 668 && shown.height <= 669)
        let dx = shown.minX - wide.minX
        #expect(dx > 50, "no horizontal gap: \(shown)")
        #expect(abs(dx - (wide.maxX - shown.maxX)) <= 1, "not centred: \(shown)")
        #expect(abs(shown.midY - wide.midY) <= 0.5)
    }

    /// Book pose ↔ flat keeps the viewer (same half); folding shut, unfolding, rotating or going to
    /// tabletop changes its viewport, so it closes rather than leave the picture on a stale side.
    @Test func theViewerClosesWhenTheDisplayMovesItsPicture() {
        let hinge = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        let inner = CGSize(width: 951, height: 669)
        let rightPage = CGRect(x: 498, y: 0, width: 453, height: 635)
        func viewport(_ size: CGSize, _ fold: CGRect?, _ active: Bool) -> CGRect {
            ImageViewerLayout.viewport(window: size, division: fold, divisionIsActive: active, pageFrame: rightPage)
        }
        let book = viewport(inner, hinge, true)
        #expect(ImageViewerLayout.staysOpen(openedIn: book, now: viewport(inner, hinge, false)), "book pose → flat")
        #expect(!ImageViewerLayout.staysOpen(openedIn: book, now: viewport(CGSize(width: 466, height: 678), nil, false)), "folded shut")
        let portrait = CGSize(width: 669, height: 951), across = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        #expect(!ImageViewerLayout.staysOpen(openedIn: book, now: viewport(portrait, across, false)), "rotated")
        #expect(!ImageViewerLayout.staysOpen(openedIn: viewport(portrait, across, false), now: viewport(portrait, across, true)),
                "flat portrait → tabletop")
    }

    /// The buttons and the caption keep clear of the cover display's camera hole, at its known spots.
    @Test func theControlsKeepClearOfTheCoverCamera() throws {
        // Portrait: the hole is top right, inside the 84 pt strip the safe area already leaves out.
        let portrait = CGSize(width: 466, height: 678)
        let hole = try #require(CoverCamera.hole(window: portrait, hasFold: false, orientation: .portrait))
        let safe = CGRect(x: 0, y: 0, width: 466 - 84, height: 678 - 20)
        let upright = ImageViewerLayout.controls(safe: safe, camera: hole)
        #expect(upright.buttons == CGRect(x: 0, y: 0, width: 382, height: ImageViewerLayout.buttonBand))
        #expect(!upright.buttons.intersects(hole))
        // Hinge down (interface landscape-right): the hole is top LEFT; with no inset there, the
        // Share button's band starts 8 pt past it, the ✕ keeps its corner.
        let landscape = CGSize(width: 678, height: 466)
        let topLeft = try #require(CoverCamera.hole(window: landscape, hasFold: false, orientation: .landscapeRight))
        let full = CGRect(origin: .zero, size: landscape)
        let turned = ImageViewerLayout.controls(safe: full, camera: topLeft)
        #expect(turned.buttons.minX == topLeft.maxX + 8)
        #expect(turned.buttons.maxX == full.maxX)
        #expect(!turned.buttons.intersects(topLeft))
        #expect(turned.caption == CGRect(x: 0, y: 466 - ImageViewerLayout.captionBand, width: 678, height: ImageViewerLayout.captionBand))
        // Hinge up (landscape-left): the hole is bottom right; the centred caption narrows on both sides.
        let bottomRight = try #require(CoverCamera.hole(window: landscape, hasFold: false, orientation: .landscapeLeft))
        let up = ImageViewerLayout.controls(safe: full, camera: bottomRight)
        #expect(up.caption.maxX <= bottomRight.minX - 8)
        #expect(abs(up.caption.midX - full.midX) <= 0.5)
        #expect(!up.caption.intersects(bottomRight))
        #expect(up.buttons == CGRect(x: 0, y: 0, width: 678, height: ImageViewerLayout.buttonBand))
    }
}
