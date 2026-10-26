import Testing
import Foundation
import UIKit
import SheafsKit
@testable import Sheafs

/// Links draw in the theme's link colour with a dotted underline (none under a superscript note
/// marker), never TextKit's system blue: an `NSAttributedString.Key.link` run is drawn blue and
/// underlined whatever its foreground colour says, so every word an edition linked to its index
/// came out like a web link. These tests render real pages and read the pixels, because the
/// attributed string looked right all along.
@MainActor
struct LinkStyleTests {
    static let pageSize = CGSize(width: 320, height: 420)
    static let body = """
    <p>And he did off the <a href="index.xhtml#star">Star</a> of the North Kingdom and gave it to \
    the keeping of the sons of Elrond.<a epub:type="noteref" href="notes.xhtml#fn1">1</a></p>
    """

    static func page(_ body: String, palette: ReaderPalette = .paper,
                     edit: (NSMutableAttributedString) -> Void = { _ in }) -> (view: PageView, chapter: PaginatedChapter) {
        let xhtml = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>\(body)</body></html>
        """
        let chapter = XHTMLConverter().convert(Data(xhtml.utf8))
        var style = ReaderEngineTests.style
        style.palette = palette
        let string = NSMutableAttributedString(attributedString: Typesetter.attributedString(
            for: chapter, style: style, images: ChapterImages(), pageSize: pageSize))
        edit(string)
        let paginated = PaginatedChapter(spineIndex: 0, attributedString: string, pageSize: pageSize)
        let view = PageView(frame: CGRect(origin: .zero, size: pageSize))
        view.palette = palette
        view.chapter = paginated
        view.page = 0
        return (view, paginated)
    }

    /// The page's pixels, RGBA, at 2x.
    static func pixels(of view: PageView) -> [UInt8] {
        let scale = 2
        let width = Int(pageSize.width) * scale, height = Int(pageSize.height) * scale
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            view.render(in: ctx)
        }
        return pixels
    }

    /// Counts pixels by hue: "blue" is the system link tint, "warm" a theme's link colour. Paper's,
    /// Night's and Black's text and backgrounds are near-neutral, so neither counts them.
    static func hues(_ pixels: [UInt8]) -> (blue: Int, warm: Int) {
        var blue = 0, warm = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), b = Int(pixels[i + 2])
            if b - r > 40 { blue += 1 }
            if r - b > 40 { warm += 1 }
        }
        return (blue, warm)
    }

    @Test func linksDrawInTheThemesColourNotSystemBlue() {
        let (view, chapter) = Self.page(Self.body)
        for palette in [ReaderPalette.paper, .night, .black] {
            view.palette = palette
            let hues = Self.hues(Self.pixels(of: view))
            #expect(hues.blue == 0, "\(palette): \(hues.blue) blue pixels (TextKit's link style)")
            #expect(hues.warm > 50, "\(palette): the theme's link colour is missing (\(hues.warm) tinted pixels)")
        }
        // Still a link: the tap lookup finds it under our own key, and TextKit's key is gone.
        let text = chapter.textStorage.string as NSString
        let star = text.range(of: "Star")
        #expect(chapter.textStorage.attribute(.sheafsLink, at: star.location, effectiveRange: nil) as? String == "index.xhtml#star")
        #expect(chapter.textStorage.attribute(.link, at: star.location, effectiveRange: nil) == nil)
    }

    /// The dotted underline is really drawn (taking it away changes tinted pixels), under the word
    /// but not under the superscript note marker.
    @Test func linkedWordsHaveADottedUnderlineNoteMarkersDoNot() throws {
        let underlined = Self.pixels(of: Self.page(Self.body).view)
        let bare = Self.pixels(of: Self.page(Self.body) { string in
            string.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: string.length))
        }.view)
        #expect(Self.hues(underlined).warm - Self.hues(bare).warm > 20, "no dotted underline drawn")

        let chapter = Self.page(Self.body).chapter
        let text = chapter.textStorage.string as NSString
        let star = text.range(of: "Star")
        let style = try #require(chapter.textStorage.attribute(.underlineStyle, at: star.location, effectiveRange: nil) as? Int)
        #expect(NSUnderlineStyle(rawValue: style).contains(.patternDot))
        let marker = text.length - 2  // "…Elrond.1\n"
        #expect(text.substring(with: NSRange(location: marker, length: 1)) == "1")
        #expect(chapter.textStorage.attribute(.sheafsLink, at: marker, effectiveRange: nil) as? String == "notes.xhtml#fn1")
        #expect(chapter.textStorage.attribute(.underlineStyle, at: marker, effectiveRange: nil) == nil)
    }

    @Test func linksOutOfTheAppLookTheSame() {
        let (view, _) = Self.page("""
        <p>Produced by <a href="https://standardebooks.org">Standard Ebooks</a>, and plain words after it.</p>
        """)
        let hues = Self.hues(Self.pixels(of: view))
        #expect(hues.blue == 0, "\(hues.blue) blue pixels (TextKit's link style)")
        #expect(hues.warm > 50)
    }
}
