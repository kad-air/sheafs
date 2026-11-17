import Testing
import Foundation
import UIKit
import SheafsKit
@testable import Sheafs

/// The Ask pane draws an answer's markdown (`AskAnswerText`): the text as read, no marks left (it is
/// also what Copy gives), bold and italic faces where the answer asked for them, list items in a
/// hanging indent, and a text view that grows with the answer.
@MainActor
struct AskAnswerTextTests {
    static let answer = """
    1. **Dinah** – Alice's cat, at home.

    2. **White Rabbit** – *late*, as always,
    and in a hurry.

    That is all.
    """

    static func drawn() -> NSAttributedString {
        AskAnswerText.attributed(AnswerMarkdown.parse(answer), traits: UITraitCollection(preferredContentSizeCategory: .large))
    }

    @Test func theTextIsTheAnswerAsRead() {
        // Items keep their numbers before a tab; a line break inside one is a line separator, so the
        // paragraph spacing stays between blocks.
        #expect(Self.drawn().string == "1.\tDinah – Alice's cat, at home.\n2.\tWhite Rabbit – late, as always,\u{2028}and in a hurry.\nThat is all.")
    }

    @Test func emphasisIsTheFacesNotTheMarks() throws {
        let text = Self.drawn()
        func font(at word: String) throws -> UIFont {
            let range = (text.string as NSString).range(of: word)
            try #require(range.location != NSNotFound)
            return try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
        }
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(try font(at: "Dinah").fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(try font(at: "White Rabbit").fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(try font(at: "late").fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(try !font(at: "late").fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(try font(at: "Alice").fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic]).isEmpty)
        #expect(try font(at: "Alice").pointSize == body.pointSize)
    }

    @Test func listItemsHangTheirText() throws {
        let text = Self.drawn()
        func style(at word: String) throws -> NSParagraphStyle {
            let range = (text.string as NSString).range(of: word)
            return try #require(text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        }
        let item = try style(at: "Dinah")
        // The number sits at the margin, the text (and its wrapped lines) at the tab.
        #expect(item.firstLineHeadIndent == 0)
        #expect(item.headIndent > 0)
        #expect(item.tabStops.first?.location == item.headIndent)
        #expect(try style(at: "in a hurry").headIndent == item.headIndent)
        #expect(try style(at: "That is all").headIndent == 0)
        // Items of a list sit closer together than the paragraph after them.
        #expect(item.paragraphSpacing < (try style(at: "in a hurry")).paragraphSpacing)
    }

    /// The pane sizes the text view from `sizeThatFits` at its width: more answer, taller view.
    @Test func theViewGrowsWithTheAnswer() {
        let view = UITextView()
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        func height(_ markdown: String) -> CGFloat {
            view.attributedText = AskAnswerText.attributed(AnswerMarkdown.parse(markdown), traits: view.traitCollection)
            return view.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let one = height("- One")
        let three = height("- One\n- Two\n- Three")
        #expect(one > 10)
        #expect(three > one * 2)
    }
}
