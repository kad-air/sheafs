import Testing
import UIKit
import SwiftUI
@testable import Sheafs

private final class BundleMarker {}

/// iOS 27's Ask Siri item in the selection menu (UIKit puts it into every edit menu) reads the
/// selected text from the window's first responder, and only if that is a `UITextInput`. These
/// tests ask UIKit's OWN lookup, the private `_intelligentAssistantTextSelectionContext` (UIKit
/// 27.1) that the item uses, what it would hand Siri, on a real pager in a real window. Before
/// `SelectionTextInput` it handed over nothing and Siri opened with an empty prompt.
@MainActor
struct SelectionTextInputTests {
    static let lookup = NSSelectorFromString("_intelligentAssistantTextSelectionContext")

    /// The text UIKit's lookup reads starting from `responder` (its context's `selectedText`), nil if none.
    static func assistantText(from responder: NSObject) throws -> String? {
        try #require(responder.responds(to: lookup),
                     "UIKit no longer has \(NSStringFromSelector(lookup)): re-check how Ask Siri reads the selection")
        guard let context = responder.perform(lookup)?.takeUnretainedValue() as? NSObject else { return nil }
        return context.value(forKey: "selectedText") as? String
    }

    @Test func askSiriReadsTheSelectedText() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        let size = CGSize(width: 466, height: 678)
        let layout = PageLayout.compute(.init(size: size, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: nil, divisionIsActive: false, camera: nil,
                                              margins: .standard, fontSize: 19, allowSpread: true, fullBleed: true))
        session.configure(style: ReaderEngineTests.style, textSize: layout.textSize)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = PagerController(session: session)
        controller.pageTurn = .slide
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.apply(layout: layout, palette: .paper, location: ReadingLocation(spineIndex: 2, textOffset: 0), animated: false)
        controller.currentSpread?.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        // The old state: the pager itself first responder, as it was while the menu was up.
        // UIKit reads nothing from it (no text input), which is the empty Siri prompt.
        #expect(controller.becomeFirstResponder())
        #expect(try Self.assistantText(from: controller.view) == nil)

        // Long press and lift on a sentence: the menu opens and the selection is offered.
        #expect(controller.selectSentence(atFraction: 0.5))
        let copied = try #require(controller.trimmedSelection()?.1, "nothing selected")
        #expect(copied.count > 10 && copied.contains { $0.isLetter }, "\(copied)")
        let chapter = try #require(session.paginatedChapter(2))
        #expect(chapter.textStorage.string.contains(copied), "the selection is not the book's text: \(copied)")
        let input = controller.selectionInput
        #expect(input.isFirstResponder)
        let firstResponder = NSSelectorFromString("_firstResponder")
        try #require(window.responds(to: firstResponder))
        #expect(window.perform(firstResponder)?.takeUnretainedValue() as? NSObject === input,
                "the window's first responder is not the selection")

        // What UIKit hands Siri is what Copy copies, from the edit menu's own interaction (the
        // item's path) and from anywhere in the window.
        let menu = try #require(controller.view.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
        #expect(try Self.assistantText(from: menu) == copied)
        #expect(try Self.assistantText(from: controller.view) == copied)
        #expect(try Self.assistantText(from: controller) == copied)

        // Read-only and no keyboard.
        #expect(input.inputView?.bounds.height == 0)
        #expect(!input.isEditable)
        #expect(!input.isUserInteractionEnabled)

        // It sits over the selection: the system's geometry for it is where the text is drawn.
        let full = try #require(input.selectedTextRange)
        let rects = input.selectionRects(for: full).map { input.convert($0.rect, to: controller.view) }
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { controller.view.bounds.contains($0) })

        // Clearing the selection takes it back: UIKit reads nothing, the pager is first responder again.
        controller.clearSelection()
        #expect(!input.isFirstResponder)
        #expect(controller.isFirstResponder)
        #expect(try Self.assistantText(from: controller.view) == nil)
    }

    /// The `UITextInput` arithmetic over the offered text, in UTF-16 units (an emoji is two).
    @Test func theOfferedTextIsTheWholeSelectedDocument() throws {
        let input = SelectionTextInput()
        let text = "“Who are you?” 🐛 said the Caterpillar."
        #expect(!input.offer(text, lineRects: [CGRect(x: 10, y: 20, width: 200, height: 24)]),
                "a view in no window cannot become the first responder")
        #expect(input.text == text && input.hasText)
        #expect(input.frame == CGRect(x: 10, y: 20, width: 200, height: 24))
        let all = try #require(input.selectedTextRange)
        #expect(input.text(in: all) == text)
        #expect(input.offset(from: input.beginningOfDocument, to: input.endOfDocument) == text.utf16.count)
        let start = try #require(input.position(from: input.beginningOfDocument, offset: 1))
        let end = try #require(input.position(from: start, offset: 3))
        let word = try #require(input.textRange(from: start, to: end))
        #expect(input.text(in: word) == "Who")
        #expect(input.compare(start, to: end) == .orderedAscending)
        #expect(input.position(from: input.endOfDocument, offset: 1) == nil)
        #expect(input.position(from: end, in: .left, offset: 3).map { input.offset(from: input.beginningOfDocument, to: $0) } == 1)
        // Typing, replacing and moving the selection change nothing: the handles own the selection.
        input.insertText("x")
        input.replace(all, withText: "")
        input.selectedTextRange = word
        #expect(input.text == text)
        let stillAll = try #require(input.selectedTextRange)
        #expect(input.text(in: stillAll) == text)
        input.withdraw()
        #expect(!input.hasText && !input.canBecomeFirstResponder)
    }
}
