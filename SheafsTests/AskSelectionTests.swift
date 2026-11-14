import Testing
import Foundation
import UIKit
import SwiftUI
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// The selection menu's Ask: offered only when Ask is on and the model can run, it hands the
/// selection (Copy's text) to the Ask panel as the question's subject, and the subject the model is
/// given never runs past the reading limit.
@MainActor
struct AskSelectionTests {
    /// A real pager on Alice's chapter 2 in a window, with a sentence selected and its menu open.
    static func selectedPager() async throws -> (PagerController, BookSession, UIWindow) {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        let size = CGSize(width: 466, height: 678)
        let layout = PageLayout.compute(.init(size: size, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84),
                                              division: nil, divisionIsActive: false, camera: nil,
                                              margin: 24, fontSize: 19, allowSpread: true, fullBleed: true))
        session.configure(style: ReaderEngineTests.style, textSize: layout.textSize)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = PagerController(session: session)
        controller.pageTurn = .slide
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.apply(layout: layout, palette: .paper, location: ReadingLocation(spineIndex: 2, textOffset: 0), animated: false)
        controller.currentSpread?.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        #expect(controller.selectSentence(atFraction: 0.5))
        return (controller, session, window)
    }

    static func titles(_ menu: UIMenu?) -> [String] { menu?.children.map(\.title) ?? [] }

    @Test func askIsOfferedOnlyWhenOnAndAvailable() async throws {
        let (controller, _, window) = try await Self.selectedPager()
        defer { window.isHidden = true }
        controller.offersAsk = false
        controller.askAvailable = { true }
        #expect(!Self.titles(controller.selectionMenu()).contains("Ask"), "Ask is off in Settings")
        controller.offersAsk = true
        controller.askAvailable = { false }
        #expect(!Self.titles(controller.selectionMenu()).contains("Ask"), "the on-device model can't run")
        controller.askAvailable = { true }
        let titles = Self.titles(controller.selectionMenu())
        #expect(titles.prefix(3) == ["Highlight", "Note", "Ask"], "\(titles)")
        #expect(titles.contains("Copy"))
    }

    @Test func askHandsTheSelectionToThePanel() async throws {
        let (controller, session, window) = try await Self.selectedPager()
        defer { window.isHidden = true }
        controller.offersAsk = true
        controller.askAvailable = { true }
        let (selection, copied) = try #require(controller.trimmedSelection())
        var actions: [SelectionAction] = []
        controller.onSelectionAction = { actions.append($0) }
        controller.askAboutSelection()
        #expect(controller.selection == nil, "the selection clears, as for Highlight")
        guard case .ask(let asked, let text) = try #require(actions.first) else {
            Issue.record("the menu's Ask sent \(actions)")
            return
        }
        #expect(asked == selection)
        #expect(text == copied)

        // The panel quotes it as the model will be given it, and starts the question.
        let model = AskModel(session: session, bookID: UUID())
        let chapter = session.chapters[asked.spineIndex]
        model.limit = ReadingLimit(spineIndex: asked.spineIndex, textOffset: chapter.textLength)
        let range = asked.range.location ..< NSMaxRange(asked.range)
        #expect(model.attach(AskSubject(spineIndex: asked.spineIndex, range: range)))
        #expect(model.subject?.text == copied.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(model.draft == AskModel.subjectQuestion)
        model.detachSubject()
        #expect(model.subject == nil && model.draft.isEmpty)
    }

    /// 🔴 The spoiler wall holds for the subject too: a limit inside the selection cuts it there,
    /// and a selection wholly past the limit is not attached.
    @Test func theSubjectStopsAtTheReadingLimit() async throws {
        let (controller, session, window) = try await Self.selectedPager()
        defer { window.isHidden = true }
        let (selection, copied) = try #require(controller.trimmedSelection())
        let range = selection.range.location ..< NSMaxRange(selection.range)
        let model = AskModel(session: session, bookID: UUID())
        let middle = selection.range.location + selection.range.length / 2
        model.limit = ReadingLimit(spineIndex: selection.spineIndex, textOffset: middle)
        #expect(model.attach(AskSubject(spineIndex: selection.spineIndex, range: range)))
        let text = try #require(model.subject?.text)
        #expect(!text.isEmpty)
        #expect(text.utf16.count <= middle - selection.range.location, "text past the limit reached the subject: \(text)")
        #expect(copied.hasPrefix(text), "\(text) is not the start of \(copied)")

        let past = AskModel(session: session, bookID: UUID())
        past.limit = ReadingLimit(spineIndex: selection.spineIndex, textOffset: selection.range.location)
        #expect(!past.attach(AskSubject(spineIndex: selection.spineIndex, range: range)))
        #expect(past.subject == nil && past.draft.isEmpty)
    }

    /// The passage goes into the answer prompt as a quoted block before the question.
    @Test func thePromptQuotesTheSubjectBeforeTheQuestion() throws {
        let prompt = AskEngine.answerPrompt(question: "What does this mean?", context: "## Chapter 1\nSome text.",
                                            names: ["Alice"], earlier: nil, subject: "Curiouser and curiouser!")
        let quote = try #require(prompt.range(of: "\"\"\"\nCuriouser and curiouser!\n\"\"\""))
        let question = try #require(prompt.range(of: "Question: What does this mean?"))
        #expect(quote.upperBound < question.lowerBound)
        #expect(!AskEngine.answerPrompt(question: "Who?", context: "x", names: [], earlier: nil).contains("\"\"\""))
    }

    /// Saved questions keep their passage; files from before it still load.
    @Test func historyKeepsTheSubjectAndReadsOldFiles() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = """
            [{"question":"Who is the Hatter?","answer":"A host.","sources":[],"summaryCount":0,
              "askedAt":"2026-11-01T10:00:00Z","chapter":"VII","limitSpine":8,"limitOffset":900}]
            """
        let entries = try decoder.decode([AskHistoryStore.Entry].self, from: Data(old.utf8))
        #expect(entries.first?.subject == nil)
        var entry = try #require(entries.first)
        entry.subject = "Twinkle, twinkle, little bat!"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try decoder.decode(AskHistoryStore.Entry.self, from: encoder.encode(entry))
        #expect(back == entry)
        #expect(AskModel.Exchange(back).subject == "Twinkle, twinkle, little bat!")
    }
}
