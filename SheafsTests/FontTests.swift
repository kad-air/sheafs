import Testing
import UIKit
import SheafsKit
@testable import Sheafs

/// Every reading font must resolve to its own family on iOS. `ReaderFont.font(size:)` falls back to
/// the system font for a family that isn't installed, and a fallback looks like a perfectly good
/// font in the font list and on the page, so check the resolved family by name, plus a real bold and
/// italic face (a missing trait silently keeps the regular face).
struct FontTests {
    @Test(arguments: ReaderFont.allCases)
    func resolvesToItsOwnFamily(_ font: ReaderFont) {
        let regular = font.font(size: 17)
        switch font {
        case .newYork:
            // New York is the system font's serif design; its family reads ".AppleSystemUIFontSerif".
            #expect(regular.familyName == ".AppleSystemUIFontSerif", "\(font) resolved to \(regular.familyName)")
        case .sanFrancisco:
            #expect(regular.familyName == UIFont.systemFont(ofSize: 17).familyName)
        default:
            #expect(regular.familyName == font.familyName, "\(font) resolved to \(regular.familyName)")
        }
        #expect(font.font(size: 17, bold: true).fontName != regular.fontName, "\(font) has no bold face")
        #expect(font.font(size: 17, italic: true).fontName != regular.fontName, "\(font) has no italic face")
    }

    /// Only the system font itself may come out as the system font.
    @Test func serifChoicesAreNotTheSystemFont() {
        let system = UIFont.systemFont(ofSize: 17).familyName
        let fallbacks = ReaderFont.allCases.filter { $0 != .sanFrancisco && $0.font(size: 17).familyName == system }
        #expect(fallbacks.isEmpty, "fell back to the system font: \(fallbacks)")
    }

    /// Which families have real lower-case small caps (measured on iOS 27; CoreText reports the
    /// feature for OpenType `smcp` too). Where it is missing, asking for it draws plain roman.
    static let smallCaps: [ReaderFont: Bool] = [
        .newYork: true, .georgia: false, .palatino: false, .charter: false, .iowan: true,
        .baskerville: true, .times: false, .sanFrancisco: true, .avenir: true,
    ]

    @Test(arguments: ReaderFont.allCases)
    func smallCapsCapability(_ font: ReaderFont) {
        #expect(Typesetter.hasSmallCaps(font.font(size: 17)) == Self.smallCaps[font], "\(font)")
    }

    /// Standard Ebooks: `b, strong { font-variant: small-caps; font-weight: normal }`. In a font
    /// with small caps the bold becomes small caps; in one without, it stays bold rather than
    /// vanishing into plain roman. A small-caps span with no bold behind it stays roman there.
    @Test(arguments: ReaderFont.allCases)
    func boldSurvivesSmallCapsWithoutTheFeature(_ font: ReaderFont) throws {
        let chapter = XHTMLConverter().convert("""
            <html><head><style>b, strong { font-variant: small-caps; font-weight: normal } .sc { font-variant: small-caps }</style></head>
            <body><p>Plain <b>Bold</b> <span class="sc">Caps</span></p></body></html>
            """)
        var style = ReaderEngineTests.style
        style.font = font
        let string = Typesetter.attributedString(for: chapter, style: style, images: ChapterImages(),
                                                 pageSize: CGSize(width: 320, height: 500))
        let text = string.string as NSString
        func face(_ word: String) throws -> UIFont {
            try #require(string.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as? UIFont)
        }
        func featured(_ f: UIFont) -> Bool { f.fontDescriptor.object(forKey: .featureSettings) != nil }
        let bold = try face("Bold"), caps = try face("Caps")
        let has = Self.smallCaps[font] ?? false
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold) == !has, "\(font): \(bold.fontName)")
        #expect(featured(bold) == has && featured(caps) == has, "\(font)")
        #expect(!caps.fontDescriptor.symbolicTraits.contains(.traitBold), "\(font)")
    }

    /// Georgia, spelled out: the case that made the emphasis vanish.
    @Test func georgiaBoldStaysBold() throws {
        #expect(Self.smallCaps[.georgia] == false)
        let chapter = XHTMLConverter().convert("""
            <html><head><style>b { font-variant: small-caps; font-weight: normal }</style></head>
            <body><p>See <b>this</b>.</p></body></html>
            """)
        var style = ReaderEngineTests.style
        style.font = .georgia
        let string = Typesetter.attributedString(for: chapter, style: style, images: ChapterImages(),
                                                 pageSize: CGSize(width: 320, height: 500))
        let font = try #require(string.attribute(.font, at: (string.string as NSString).range(of: "this").location,
                                                 effectiveRange: nil) as? UIFont)
        #expect(font.familyName == "Georgia")
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    /// No house italics: a blockquote (a letter, an epigraph) is upright unless the book says so.
    @Test func blockquotesAreUpright() throws {
        let chapter = XHTMLConverter().convert("<blockquote><p>Dear Sir, <i>truly</i></p></blockquote>")
        #expect(chapter.blocks.first?.kind == .blockquote)
        let string = Typesetter.attributedString(for: chapter, style: ReaderEngineTests.style, images: ChapterImages(),
                                                 pageSize: CGSize(width: 320, height: 500))
        let text = string.string as NSString
        let plain = try #require(string.attribute(.font, at: text.range(of: "Dear").location, effectiveRange: nil) as? UIFont)
        let italic = try #require(string.attribute(.font, at: text.range(of: "truly").location, effectiveRange: nil) as? UIFont)
        #expect(!plain.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }
}
