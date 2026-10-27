import Foundation
import UIKit
import SheafsKit

/// The resolved style of a typeset chapter. Equal styles produce equal attributed strings.
struct TypesetStyle: Hashable, Sendable {
    var font: ReaderFont
    var fontSize: Double
    var lineHeight: Double
    var justified: Bool
    var hyphenate: Bool
    var paragraphStyle: ParagraphStyleChoice
    var palette: ReaderPalette
    var language: String?
}

/// Images available to a chapter, keyed by the `src` as written in the document.
struct ChapterImages: Sendable {
    var images: [String: UIImage] = [:]
}

extension NSAttributedString.Key {
    /// Marks the characters of an image block so taps can find it.
    nonisolated static let sheafsImageSource = NSAttributedString.Key("sheafs.imageSource")
    nonisolated static let sheafsBlockIndex = NSAttributedString.Key("sheafs.blockIndex")
    /// A link's href. Not `.link`: TextKit draws `.link` text system blue and underlined whatever
    /// the foreground colour says, which put index and glossary links all over the page.
    nonisolated static let sheafsLink = NSAttributedString.Key("sheafs.link")
}

/// Turns a `Chapter` into an `NSAttributedString` whose UTF-16 layout matches the chapter's
/// offsets exactly: every block's text followed by "\n".
enum Typesetter {
    nonisolated static func attributedString(for chapter: Chapter, style: TypesetStyle, images: ChapterImages,
                                             pageSize: CGSize) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let size = CGFloat(style.fontSize)
        var previousWasBodyParagraph = false

        for block in chapter.blocks {
            let piece = NSMutableAttributedString()
            switch block.kind {
            case .image(let source, _) where block.textLength == 1:
                // A chapter that is only an image (a cover page) fills the page; inline images never upscale.
                piece.append(imageAttachment(source: source, images: images, pageSize: pageSize, style: style,
                                             fillsPage: chapter.blocks.count == 1))
            case .horizontalRule where block.textLength == 1:
                piece.append(ruleAttachment(style: style, pageWidth: pageSize.width))
            default:
                for run in block.runs {
                    piece.append(NSAttributedString(string: run.text, attributes: attributes(for: run, block: block, style: style)))
                }
            }
            // The contract: a block contributes exactly its text, so chapter offsets are string indices.
            // Enforce it rather than trust it; a drift would silently break positions and sync.
            if piece.length != block.textLength {
                if piece.length > block.textLength {
                    piece.deleteCharacters(in: NSRange(location: block.textLength, length: piece.length - block.textLength))
                } else {
                    piece.append(NSAttributedString(string: String(repeating: " ", count: block.textLength - piece.length),
                                                    attributes: [.font: style.font.font(size: size)]))
                }
            }

            let paragraph = paragraphStyle(for: block, style: style, continuing: previousWasBodyParagraph, pageSize: pageSize)
            piece.append(NSAttributedString(string: "\n", attributes: [.font: style.font.font(size: size)]))
            piece.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: piece.length))
            piece.addAttribute(.sheafsBlockIndex, value: block.id, range: NSRange(location: 0, length: piece.length))
            if let language = style.language {
                piece.addAttribute(NSAttributedString.Key(kCTLanguageAttributeName as String), value: language,
                                   range: NSRange(location: 0, length: piece.length))
            }
            result.append(piece)
            previousWasBodyParagraph = isBodyParagraph(block)
        }
        assert(result.length == chapter.textLength, "typeset chapter length \(result.length) != \(chapter.textLength)")
        return result
    }

    nonisolated private static func isBodyParagraph(_ block: Block) -> Bool {
        if case .paragraph = block.kind, block.alignment == .natural || block.alignment == .justified { return true }
        return false
    }

    nonisolated static func isExternal(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    nonisolated private static func attributes(for run: InlineRun, block: Block, style: TypesetStyle) -> [NSAttributedString.Key: Any] {
        let base = CGFloat(style.fontSize)
        var size = base
        var bold = run.style.contains(.bold)
        var italic = run.style.contains(.italic)
        var color = style.palette.text
        var attrs: [NSAttributedString.Key: Any] = [:]

        switch block.kind {
        case .heading(let level):
            bold = true
            size = base * [1.55, 1.35, 1.2, 1.1, 1.0, 1.0][max(0, min(5, level - 1))]
        case .caption:
            size = base * 0.85
            color = style.palette.secondary
        case .blockquote:
            italic = true
        case .preformatted:
            size = base * 0.85
        default:
            break
        }
        if block.kind == .preformatted || run.style.contains(.code) {
            let mono = UIFont.monospacedSystemFont(ofSize: size * 0.92, weight: bold ? .semibold : .regular)
            attrs[.font] = italic ? UIFont(descriptor: mono.fontDescriptor.withSymbolicTraits(.traitItalic) ?? mono.fontDescriptor, size: size * 0.92) : mono
        } else {
            var font = style.font.font(size: size, bold: bold, italic: italic)
            if run.style.contains(.superscript) || run.style.contains(.subscript) {
                font = style.font.font(size: size * 0.68, bold: bold, italic: italic)
                attrs[.baselineOffset] = run.style.contains(.superscript) ? size * 0.36 : -size * 0.12
            }
            if run.style.contains(.smallCaps) {
                let features: [[UIFontDescriptor.FeatureKey: Int]] = [[
                    .type: kLowerCaseType, .selector: kLowerCaseSmallCapsSelector,
                ]]
                let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            attrs[.font] = font
        }
        if run.style.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.style.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link {
            attrs[.sheafsLink] = link
            // The theme's link colour and a dotted underline: a quiet hint that there is something
            // to look at (index entries, glossary terms), not a web link. A note marker is already
            // a superscript; a dotted line under a raised "1" is only noise.
            color = style.palette.link
            if !run.style.contains(.superscript) {
                attrs[.underlineStyle] = NSUnderlineStyle([.single, .patternDot]).rawValue
                attrs[.underlineColor] = style.palette.link.withAlphaComponent(0.7)
            }
        }
        attrs[.foregroundColor] = color
        return attrs
    }

    nonisolated private static func paragraphStyle(for block: Block, style: TypesetStyle, continuing: Bool, pageSize: CGSize) -> NSParagraphStyle {
        let size = CGFloat(style.fontSize)
        let p = NSMutableParagraphStyle()
        let font = style.font.font(size: size)
        let lineSpacing = max(0, font.lineHeight * (CGFloat(style.lineHeight) - 1))
        p.lineSpacing = lineSpacing
        p.lineBreakMode = .byWordWrapping
        p.hyphenationFactor = style.hyphenate ? 0.9 : 0
        p.baseWritingDirection = .natural

        switch block.alignment {
        case .center: p.alignment = .center
        case .trailing: p.alignment = .right
        case .justified: p.alignment = .justified
        case .natural: p.alignment = style.justified ? .justified : .natural
        }

        let indentUnit = size * 1.4
        let indent = CGFloat(block.indent) * indentUnit
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        p.tailIndent = -indent

        switch block.kind {
        case .paragraph:
            if style.paragraphStyle == .indented {
                p.paragraphSpacing = 0
                if continuing && block.alignment != .center { p.firstLineHeadIndent = indent + size * 1.3 }
            } else {
                p.paragraphSpacing = size * 0.6
            }
        case .heading(let level):
            p.alignment = block.alignment == .natural ? (level <= 2 ? .center : .natural) : p.alignment
            p.paragraphSpacingBefore = size * (level <= 2 ? 1.2 : 0.9)
            p.paragraphSpacing = size * 0.7
            p.hyphenationFactor = 0
            p.lineSpacing = lineSpacing * 0.5
        case .blockquote:
            p.paragraphSpacing = size * 0.5
            p.paragraphSpacingBefore = size * 0.3
        case .listItem(let ordered, let ordinal):
            let marker = ordered ? "\(ordinal)." : "•"
            let markerWidth = (marker as NSString).size(withAttributes: [.font: font]).width + size * 0.5
            p.firstLineHeadIndent = indent
            p.headIndent = indent + markerWidth
            p.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
            p.paragraphSpacing = size * 0.25
        case .preformatted:
            p.alignment = .natural
            p.hyphenationFactor = 0
            p.lineBreakMode = .byCharWrapping
            p.paragraphSpacing = size * 0.6
        case .image:
            p.alignment = .center
            p.paragraphSpacingBefore = size * 0.6
            p.paragraphSpacing = size * 0.6
            p.firstLineHeadIndent = 0
            p.headIndent = 0
            p.tailIndent = 0
        case .horizontalRule:
            p.alignment = .center
            p.paragraphSpacingBefore = size * 0.8
            p.paragraphSpacing = size * 0.8
        case .caption:
            p.alignment = block.alignment == .natural ? .center : p.alignment
            p.paragraphSpacing = size * 0.8
        }
        return p
    }

    nonisolated private static func imageAttachment(source: String, images: ChapterImages, pageSize: CGSize,
                                                    style: TypesetStyle, fillsPage: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let maxWidth = max(40, pageSize.width)
        let maxHeight = max(40, pageSize.height * (fillsPage ? 0.96 : 0.9))
        guard let image = images.images[source], image.size.width > 0, image.size.height > 0 else {
            // Missing or undecodable image: a quiet placeholder so the flow is not disturbed. Not
            // tagged as a picture: there is nothing to open, so a tap there is a tap on text.
            attachment.image = placeholderImage(style: style)
            attachment.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
            return NSAttributedString(attachment: attachment)
        }
        attachment.image = image
        let fit = min(maxWidth / image.size.width, maxHeight / image.size.height)
        let scale = fillsPage ? fit : min(1, fit)
        attachment.bounds = CGRect(x: 0, y: 0, width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttribute(.sheafsImageSource, value: source, range: NSRange(location: 0, length: string.length))
        return string
    }

    nonisolated private static func ruleAttachment(style: TypesetStyle, pageWidth: CGFloat) -> NSAttributedString {
        let width = max(40, min(pageWidth * 0.3, 160))
        let height: CGFloat = 8
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            style.palette.secondary.withAlphaComponent(0.6).setFill()
            ctx.fill(CGRect(x: 0, y: height / 2 - 0.5, width: width, height: 1))
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let string = NSMutableAttributedString(attachment: attachment)
        return string
    }

    nonisolated private static func placeholderImage(style: TypesetStyle) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return renderer.image { ctx in
            style.palette.secondary.withAlphaComponent(0.35).setStroke()
            ctx.cgContext.setLineWidth(1)
            ctx.cgContext.stroke(CGRect(x: 1, y: 1, width: 22, height: 22))
        }
    }
}
