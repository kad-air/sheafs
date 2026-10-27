import LinkPresentation
import UIKit
import os

private let log = Logger(subsystem: "io.sheafs.reader", category: "pager")

/// Sharing a selected passage: the quote as text (`AnnotationExport.quote`) and as an image card
/// drawn in the reader's theme and typeface, both handed to the system share sheet.
enum QuoteShare {
    /// The share sheet for a quote. Text-first targets (Messages, Mail, Notes, Copy) get the text
    /// alone; everything else gets the text and the card, and image-only targets (Save Image) take
    /// the card.
    static func sheet(text: String, credit: AnnotationExport.Credit, palette: ReaderPalette, font: ReaderFont) -> UIActivityViewController {
        let quote = AnnotationExport.quote(text, credit: credit)
        let started = Date()
        let card = QuoteCard.render(text: AnnotationExport.quoteText(text), attribution: credit.attribution,
                                    palette: palette, font: font)
        log.notice("quote card: \(Int(card.image.size.width))×\(Int(card.image.size.height)) truncated=\(card.truncated) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let sheet = UIActivityViewController(activityItems: [QuoteTextItem(quote, credit: credit, card: card.image),
                                                             QuoteImageItem(card.image)],
                                             applicationActivities: nil)
        sheet.excludedActivityTypes = [.assignToContact, .addToReadingList]
        return sheet
    }

    /// Activities that should get the words, not a picture of them.
    nonisolated static let textOnly: Set<UIActivity.ActivityType> = [
        .message, .mail, .copyToPasteboard,
        UIActivity.ActivityType("com.apple.mobilenotes.SharingExtension"),
        UIActivity.ActivityType("com.apple.reminders.sharingextension"),
    ]
}

/// The quote as text, for every target but the photo library. Nonisolated: UIKit may ask for the
/// items off the main thread, and a main-actor method would trap there; it only reads its lets.
nonisolated final class QuoteTextItem: NSObject, UIActivityItemSource {
    let text: String
    let credit: AnnotationExport.Credit
    let card: UIImage

    init(_ text: String, credit: AnnotationExport.Credit, card: UIImage) {
        self.text = text
        self.credit = credit
        self.card = card
    }

    /// The sheet's header: the card as its icon and the book as its title (without it the header
    /// is a blank placeholder icon).
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = [credit.title, credit.author].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        metadata.iconProvider = NSItemProvider(object: card)
        return metadata
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { text }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        activityType == .saveToCameraRoll ? nil : text
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        text.components(separatedBy: "\n").last ?? ""
    }
}

/// The quote card, for every target that isn't text-first. Nonisolated, like `QuoteTextItem`.
nonisolated final class QuoteImageItem: NSObject, UIActivityItemSource {
    let image: UIImage

    init(_ image: UIImage) { self.image = image }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        guard let activityType else { return image }
        return QuoteShare.textOnly.contains(activityType) ? nil : image
    }
}

/// A quote drawn as a card: the text in the reader's typeface on the theme's page colour, the
/// attribution smaller beneath a short rule, generous margins. `width` points wide at scale 1
/// (so as many pixels), as tall as the text needs up to `maxHeight`; a longer quote ends in an
/// ellipsis on the card only (the shared text is always whole).
enum QuoteCard {
    static let width: CGFloat = 1080
    /// A 9:16 story at most.
    static let maxHeight: CGFloat = 1920
    static let margin: CGFloat = 112
    static let quoteSize: CGFloat = 46
    static let attributionSize: CGFloat = 30

    struct Rendered {
        var image: UIImage
        /// Whether the text was cut short to fit `maxHeight` and the card ends in an ellipsis.
        var truncated: Bool
    }

    static func render(text: String, attribution: String, palette: ReaderPalette, font: ReaderFont) -> Rendered {
        let textWidth = width - margin * 2
        let ruleGap: CGFloat = 52, ruleHeight: CGFloat = 3, ruleWidth: CGFloat = 72

        let quotePara = NSMutableParagraphStyle()
        quotePara.lineHeightMultiple = 1.22
        quotePara.paragraphSpacing = quoteSize * 0.6
        quotePara.hyphenationFactor = 0.3
        let storage = NSTextStorage(string: text, attributes: [
            .font: font.font(size: quoteSize), .foregroundColor: palette.text, .paragraphStyle: quotePara,
        ])
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let attributionPara = NSMutableParagraphStyle()
        attributionPara.lineHeightMultiple = 1.15
        let credit = NSAttributedString(string: attribution, attributes: [
            .font: font.font(size: attributionSize, italic: true), .foregroundColor: palette.secondary,
            .paragraphStyle: attributionPara,
        ])
        let creditHeight = ceil(credit.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)

        // Too tall: keep the lines that fit and let TextKit end the last one with an ellipsis.
        let room = maxHeight - margin * 2 - ruleGap * 2 - ruleHeight - creditHeight
        layoutManager.ensureLayout(for: container)
        var truncated = false
        if layoutManager.usedRect(for: container).height > room {
            var lines = 0
            layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, _, stop in
                if rect.maxY <= room { lines += 1 } else { stop.pointee = true }
            }
            container.maximumNumberOfLines = max(1, lines)
            container.lineBreakMode = .byTruncatingTail
            layoutManager.ensureLayout(for: container)
            // TextKit only draws its ellipsis when the last line it keeps runs on into the same
            // paragraph; a cut that falls at a paragraph's end (dialogue, short lines) just stops.
            // Then end the kept text with an ellipsis here: if that wraps past the last line, the
            // line now runs on and TextKit truncates it instead.
            if !textKitEllipsis(layoutManager, container), visibleCharacters(layoutManager, container) < storage.length {
                let kept = (storage.string as NSString).substring(to: visibleCharacters(layoutManager, container))
                    .trimmingCharacters(in: .whitespacesAndNewlines) as NSString
                storage.replaceCharacters(in: NSRange(location: kept.length, length: storage.length - kept.length), with: "…")
                layoutManager.ensureLayout(for: container)
            }
            // What was really laid out, not what was asked for: an ellipsis TextKit drew, or ours, shown.
            truncated = textKitEllipsis(layoutManager, container)
                || (storage.string.hasSuffix("…") && visibleCharacters(layoutManager, container) == storage.length)
        }
        let quoteHeight = ceil(layoutManager.usedRect(for: container).height)
        let height = min(maxHeight, margin * 2 + quoteHeight + ruleGap * 2 + ruleHeight + creditHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            palette.background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let glyphs = layoutManager.glyphRange(for: container)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: margin, y: margin))
            var y = margin + quoteHeight + ruleGap
            palette.link.setFill()
            context.fill(CGRect(x: margin, y: y, width: ruleWidth, height: ruleHeight))
            y += ruleHeight + ruleGap
            credit.draw(with: CGRect(x: margin, y: y, width: textWidth, height: creditHeight + 1),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        return Rendered(image: image, truncated: truncated)
    }

    /// Whether TextKit truncated the container's last line with an ellipsis.
    private static func textKitEllipsis(_ layoutManager: NSLayoutManager, _ container: NSTextContainer) -> Bool {
        let shown = layoutManager.glyphRange(for: container)
        return shown.length > 0
            && layoutManager.truncatedGlyphRange(inLineFragmentForGlyphAt: NSMaxRange(shown) - 1).location != NSNotFound
    }

    /// How many characters (from the start) the container shows.
    private static func visibleCharacters(_ layoutManager: NSLayoutManager, _ container: NSTextContainer) -> Int {
        NSMaxRange(layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(for: container), actualGlyphRange: nil))
    }
}
