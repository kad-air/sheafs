import SheafsKit
import SwiftUI
import UIKit

/// An answer in the Ask pane with its markdown drawn (`AnswerMarkdown`): bold, italics, bullet and
/// numbered lists with hanging indents, paragraphs apart. A read-only `UITextView`, so it selects
/// like any text on iOS: a long press picks a word, the handles take it across paragraphs and list
/// items, and the menu copies (the text as read: no asterisks, "•" and "1." kept), looks up,
/// translates, shares. `streaming`: the answer is still arriving (`AnswerMarkdown.parse`'s
/// `streaming`, so nothing shows raw mid-stream). The pane's own tap (keyboard away) still fires
/// over it, alongside the text view's.
struct AskAnswerText: UIViewRepresentable {
    var markdown: String
    var streaming = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let text = Self.attributed(AnswerMarkdown.parse(markdown, streaming: streaming), traits: traits)
        if view.attributedText != text { view.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width ?? size.width, height: size.height.rounded(.up))
    }

    // MARK: Drawing the blocks

    /// The blocks as one attributed string: the body text style at the reader's text size, blocks
    /// apart by a paragraph's spacing (list items closer), a line break inside a block a LINE
    /// separator (U+2028, so the spacing stays between blocks), list markers in a hanging indent.
    static func attributed(_ blocks: [AnswerMarkdown.Block], traits: UITraitCollection) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let em = body.pointSize
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let start = out.length
            var base = body
            var colour = UIColor.label
            let style = NSMutableParagraphStyle()
            switch block {
            case .paragraph:
                break
            case .heading(let level, _):
                base = UIFont.preferredFont(forTextStyle: level <= 2 ? .title3 : .headline, compatibleWith: traits)
                base = font(base, bold: true, italic: false)
            case .item(let marker, let ordered, let depth, _):
                let indent = CGFloat(depth) * em * 1.3
                let hang = ordered ? em * 1.7 : em * 1.1
                style.firstLineHeadIndent = indent
                style.headIndent = indent + hang
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hang)]
                let bullet = ordered ? marker : ["•", "◦", "▪︎", "▪︎"][min(depth, 3)]
                out.append(NSAttributedString(string: bullet + "\t", attributes: [
                    .font: ordered ? UIFont.monospacedDigitSystemFont(ofSize: em, weight: .regular) : body,
                    .foregroundColor: ordered ? UIColor.label : UIColor.secondaryLabel,
                ]))
            case .quote:
                style.firstLineHeadIndent = em * 0.8
                style.headIndent = em * 0.8
                colour = .secondaryLabel
            }
            for run in block.runs {
                let runFont = run.code
                    ? UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.9, weight: run.bold ? .semibold : .regular)
                    : font(base, bold: run.bold, italic: run.italic)
                out.append(NSAttributedString(string: run.text.replacingOccurrences(of: "\n", with: "\u{2028}"),
                                              attributes: [.font: runFont, .foregroundColor: colour]))
            }
            let next = index + 1 < blocks.count ? blocks[index + 1] : nil
            if next != nil {
                out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
            }
            // Items of one list sit closer than paragraphs.
            let isItem: (AnswerMarkdown.Block?) -> Bool = { if case .item = $0 { true } else { false } }
            style.paragraphSpacing = isItem(block) && isItem(next) ? em * 0.35 : em * 0.65
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    /// `base` in bold and/or italic (the same family and size), as far as the face has them.
    static func font(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard traits != base.fontDescriptor.symbolicTraits,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
}
