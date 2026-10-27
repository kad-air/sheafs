import Testing
import Foundation
import UIKit
@testable import Sheafs

/// Sharing a quote from the selection menu: the text reads `quote` + newline + `— Author, Title,
/// Chapter` with the same credit the Markdown export uses, is never shortened, and the image card
/// is 1080 wide, in the theme's colours, with ink where the quote and the credit go.
@MainActor
struct QuoteShareTests {
    static let alice = "Alice’s Adventures in Wonderland"

    @Test func quoteReadsTextThenAttribution() {
        let credit = AnnotationExport.Credit(title: Self.alice, author: "Lewis Carroll", chapter: "Down the Rabbit-Hole")
        #expect(AnnotationExport.quote("Curiouser and curiouser!", credit: credit)
                == "Curiouser and curiouser!\n— Lewis Carroll, Alice’s Adventures in Wonderland, Down the Rabbit-Hole")
    }

    @Test func missingAuthorAndRepeatedTitleAreLeftOut() {
        let noAuthor = AnnotationExport.Credit(title: Self.alice, author: nil, chapter: "Chapter II")
        #expect(noAuthor.attribution == "— Alice’s Adventures in Wonderland, Chapter II")
        let blankAuthor = AnnotationExport.Credit(title: Self.alice, author: "  \n ", chapter: nil)
        #expect(blankAuthor.attribution == "— Alice’s Adventures in Wonderland")
        // A chapter that only repeats the book's title (one-file books, a TOC naming the book) is dropped.
        let sameTitle = AnnotationExport.Credit(title: Self.alice, author: "Lewis Carroll", chapter: " alice’s adventures in wonderland ")
        #expect(sameTitle.attribution == "— Lewis Carroll, Alice’s Adventures in Wonderland")
        // Line breaks inside a title (some OPFs wrap it) fold to one space.
        let wrapped = AnnotationExport.Credit(title: "Through the\n   Looking-Glass", author: " Lewis  Carroll ", chapter: "")
        #expect(wrapped.attribution == "— Lewis Carroll, Through the Looking-Glass")
    }

    @Test func quoteTrimsWhitespaceKeepsCurlyQuotesAndParagraphs() {
        let credit = AnnotationExport.Credit(title: "Alice", author: "Lewis Carroll", chapter: nil)
        // A selection that swept up a paragraph break, an illustration (U+FFFC) and indents.
        let selected = "  “Who are you?” said the Caterpillar.  \n\u{FFFC}\n\n\t‘I—I hardly know, sir.’ \n"
        #expect(AnnotationExport.quote(selected, credit: credit)
                == "“Who are you?” said the Caterpillar.\n‘I—I hardly know, sir.’\n— Lewis Carroll, Alice")
    }

    @Test func longSelectionIsNeverTruncated() {
        let credit = AnnotationExport.Credit(title: "Alice", author: nil, chapter: nil)
        let sentence = "Alice was beginning to get very tired of sitting by her sister on the bank. "
        let long = String(repeating: sentence, count: 400).trimmingCharacters(in: .whitespaces)
        let quote = AnnotationExport.quote(long, credit: credit)
        #expect(quote == long + "\n— Alice")
        #expect(!quote.contains("…"))
    }

    @Test func markdownAndQuoteCreditTheSameSource() {
        // The Markdown export's heading, byline and chapter heading are the quote's credit, piece by piece.
        let credit = AnnotationExport.Credit(title: " Alice\n", author: " Lewis Carroll ", chapter: " Down the Rabbit-Hole ")
        let markdown = AnnotationExport.markdown(title: " Alice\n", author: " Lewis Carroll ",
                                                 annotations: [(" Down the Rabbit-Hole ", "Curiouser!", "")])
        #expect(markdown == "# \(credit.title)\n*\(credit.author!)*\n\n## \(credit.chapter!)\n\n> Curiouser!\n")
        #expect(credit.attribution == "— Lewis Carroll, Alice, Down the Rabbit-Hole")
    }

    @Test func saveImageIsAllowed() throws {
        // Without this key the share sheet leaves Save Image out (and saving would crash).
        let reason = try #require(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)
        #expect(!reason.isEmpty)
    }

    @Test func textFirstTargetsGetTheTextAloneOthersTheCardToo() {
        let card = QuoteCard.render(text: "Curiouser!", attribution: "— Alice", palette: .paper, font: .newYork).image
        let credit = AnnotationExport.Credit(title: "Alice", author: nil, chapter: nil)
        let text = QuoteTextItem("Curiouser!\n— Alice", credit: credit, card: card), image = QuoteImageItem(card)
        let sheet = UIActivityViewController(activityItems: [], applicationActivities: nil)
        for type: UIActivity.ActivityType in [.message, .mail, .copyToPasteboard, .init("com.apple.mobilenotes.SharingExtension")] {
            #expect(text.activityViewController(sheet, itemForActivityType: type) as? String == "Curiouser!\n— Alice", "\(type.rawValue)")
            #expect(image.activityViewController(sheet, itemForActivityType: type) == nil, "\(type.rawValue) got the card")
        }
        #expect(image.activityViewController(sheet, itemForActivityType: .saveToCameraRoll) as? UIImage === card)
        #expect(text.activityViewController(sheet, itemForActivityType: .saveToCameraRoll) == nil)
        // A third-party target (Instagram, say) gets both.
        let other = UIActivity.ActivityType("com.example.share")
        #expect(text.activityViewController(sheet, itemForActivityType: other) as? String != nil)
        #expect(image.activityViewController(sheet, itemForActivityType: other) as? UIImage === card)
    }

    @Test func itemSourcesAnswerOffTheMainThread() async {
        // UIKit may ask for the items on a background queue; a main-actor method traps there.
        let card = QuoteCard.render(text: "Curiouser!", attribution: "— Alice", palette: .paper, font: .newYork).image
        let credit = AnnotationExport.Credit(title: "Alice", author: nil, chapter: nil)
        let text = QuoteTextItem("Curiouser!\n— Alice", credit: credit, card: card), image = QuoteImageItem(card)
        nonisolated(unsafe) let sheet = UIActivityViewController(activityItems: [], applicationActivities: nil)
        let answers = await Task.detached {
            #expect(pthread_main_np() == 0, "ran on the main thread")
            return (text.activityViewController(sheet, itemForActivityType: .copyToPasteboard) as? String,
                    image.activityViewController(sheet, itemForActivityType: .saveToCameraRoll) != nil,
                    text.activityViewControllerPlaceholderItem(sheet) is String,
                    text.activityViewControllerLinkMetadata(sheet)?.title)
        }.value
        #expect(answers.0 == "Curiouser!\n— Alice")
        #expect(answers.1 && answers.2)
        #expect(answers.3 == "Alice")
    }

    @Test func markdownHeadsAChapterNamedLikeTheBook() {
        // A collection named after a story that isn't its first: the title story's highlights get
        // their own heading, not filed under the story before (only the quote's credit drops it).
        let markdown = AnnotationExport.markdown(title: "The Dead", author: "James Joyce", annotations: [
            ("Araby", "North Richmond Street, being blind, was a quiet street", ""),
            ("The Dead", "His soul swooned slowly as he heard the snow falling", ""),
        ])
        #expect(markdown == """
        # The Dead
        *James Joyce*

        ## Araby

        > North Richmond Street, being blind, was a quiet street

        ## The Dead

        > His soul swooned slowly as he heard the snow falling

        """)
        #expect(AnnotationExport.Credit(title: "The Dead", author: "James Joyce", chapter: "The Dead").attribution
                == "— James Joyce, The Dead")
    }

    // MARK: Card

    /// The card's pixels, RGBA.
    static func pixels(of image: UIImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (pixels, width, height)
    }

    /// Pixels in rows `rows` (top-down) that differ clearly from `background`.
    static func ink(_ image: (pixels: [UInt8], width: Int, height: Int), rows: Range<Int>, background: UIColor) -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        background.getRed(&r, green: &g, blue: &b, alpha: &a)
        let bg = [Int(r * 255), Int(g * 255), Int(b * 255)]
        var count = 0
        for y in rows.clamped(to: 0..<image.height) {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                let distance = abs(Int(image.pixels[i]) - bg[0]) + abs(Int(image.pixels[i + 1]) - bg[1]) + abs(Int(image.pixels[i + 2]) - bg[2])
                if distance > 60 { count += 1 }
            }
        }
        return count
    }

    @Test func cardIs1080WideWithInkInTheThemesColours() throws {
        for palette in [ReaderPalette.paper, .night] {
            let card = QuoteCard.render(text: "“Curiouser and curiouser!” cried Alice.",
                                        attribution: "— Lewis Carroll, Alice’s Adventures in Wonderland",
                                        palette: palette, font: .newYork)
            #expect(card.image.size.width == 1080 && card.image.scale == 1)
            #expect(!card.truncated)
            let image = try Self.pixels(of: card.image)
            #expect(image.width == 1080)
            #expect(image.height > 400 && image.height < 900, "\(image.height) px tall for two short lines")
            // The corners are the page colour; the margins stay clear.
            #expect(Self.ink(image, rows: 0..<Int(QuoteCard.margin) - 8, background: palette.background) == 0)
            #expect(Self.ink(image, rows: image.height - Int(QuoteCard.margin) + 8..<image.height, background: palette.background) == 0)
            // Ink in the quote's rows (the top half) and the credit's (the bottom half).
            let middle = image.height / 2
            #expect(Self.ink(image, rows: Int(QuoteCard.margin)..<middle, background: palette.background) > 2000, "\(palette): no quote")
            #expect(Self.ink(image, rows: middle..<image.height - Int(QuoteCard.margin) + 8, background: palette.background) > 500, "\(palette): no credit")
        }
    }

    @Test func longQuoteIsCappedWithAnEllipsisOnTheCardOnly() throws {
        let sentence = "Alice was beginning to get very tired of sitting by her sister on the bank. "
        let card = QuoteCard.render(text: String(repeating: sentence, count: 200), attribution: "— Lewis Carroll, Alice",
                                    palette: .sepia, font: .georgia)
        #expect(card.truncated, "TextKit did not end the last line with an ellipsis")
        // Capped at a 9:16 story, and filled to within a couple of lines of it.
        #expect(card.image.size.width == 1080)
        #expect(card.image.size.height <= QuoteCard.maxHeight && card.image.size.height > QuoteCard.maxHeight - 150,
                "\(card.image.size.height) pt tall")
        // The cut can fall where a paragraph ends (dialogue, short lines): TextKit then just stops
        // without an ellipsis, so the card must add one itself.
        let dialogue = (1...200).map { "“Line \($0).”" }.joined(separator: "\n")
        let short = QuoteCard.render(text: dialogue, attribution: "— Lewis Carroll, Alice", palette: .paper, font: .newYork)
        #expect(short.truncated, "a cut at a paragraph's end drew no ellipsis")
        #expect(short.image.size.height <= QuoteCard.maxHeight && short.image.size.height > QuoteCard.maxHeight - 150)
        // The credit still fits under the cut text.
        let image = try Self.pixels(of: card.image)
        #expect(Self.ink(image, rows: image.height - Int(QuoteCard.margin) - 60..<image.height - Int(QuoteCard.margin) + 8,
                         background: ReaderPalette.sepia.background) > 300)
    }
}
