import Testing
import Foundation
import UIKit
import SwiftUI
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// Ask beside the book on the Duo's inner display: Ask on the left of the fold, the book live on the
/// right as the spread's right page, unchanged; floating over the page everywhere else. The fold is
/// the region the Duo simulator reports for its hinge (455.5, 0, 40 × 669, flat and in book pose).
@MainActor
struct AskPresentationTests {
    static let inner = CGSize(width: 951, height: 669)
    static let hinge = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    static func layout(size: CGSize, fold: CGRect?, active: Bool) -> PageLayout {
        PageLayout.compute(.init(size: size, safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
                                 division: fold, divisionIsActive: active, camera: nil,
                                 margins: .standard, fontSize: 19, allowSpread: true, fullBleed: true))
    }

    @Test func theInnerDisplayPutsAskLeftOfTheFoldAndKeepsTheRightPage() throws {
        let spread = Self.layout(size: Self.inner, fold: Self.hinge, active: false)
        let asking = AskPresentation.choose(for: spread, division: Self.hinge, window: Self.inner)
        guard case .beside(let pane, let book) = asking else {
            Issue.record("the inner display's spread floats Ask: \(asking)")
            return
        }
        // The pane is the left page's side, the book the right page's; neither reaches into the hinge.
        #expect(pane == CGRect(x: 0, y: 0, width: 453, height: 669))
        #expect(book == CGRect(x: 498, y: 0, width: 453, height: 669))
        #expect(pane.maxX <= Self.hinge.minX && book.minX >= Self.hinge.maxX)
        #expect(asking.bookFrame(in: Self.inner) == book)
        // One page, the spread's right one, where it was and the same size: no text moves, the
        // pagination (keyed by the text size) is the spread's.
        let single = asking.pages(spread)
        #expect(single.pageFrames.count == 1)
        let inWindow = try #require(single.pageFrames.first).offsetBy(dx: book.minX, dy: book.minY)
        #expect(inWindow == spread.pageFrames[1])
        #expect(single.textSize == spread.textSize)
        #expect(single.textInsets == spread.textInsets)
    }

    /// Book pose and flat lay the spread out identically, so Ask sits the same in both; a zero-width
    /// inactive fold (what the device may report flat) too.
    @Test func bookPoseAndFlatPresentAskTheSame() {
        let flat = AskPresentation.choose(for: Self.layout(size: Self.inner, fold: Self.hinge, active: false),
                                          division: Self.hinge, window: Self.inner)
        let folded = AskPresentation.choose(for: Self.layout(size: Self.inner, fold: Self.hinge, active: true),
                                            division: Self.hinge, window: Self.inner)
        let line = CGRect(x: 475.5, y: 0, width: 0, height: 669)
        let thin = AskPresentation.choose(for: Self.layout(size: Self.inner, fold: line, active: false),
                                          division: line, window: Self.inner)
        #expect(flat.isBeside)
        #expect(folded == flat)
        #expect(thin == flat)
    }

    /// Everywhere else today's floating panel stays: the cover display, inner portrait (a horizontal
    /// fold), tabletop, and a fold-less spread (iPad landscape).
    @Test func everywhereElseAskFloats() {
        let cover = CGSize(width: 466, height: 678)
        #expect(AskPresentation.choose(for: Self.layout(size: cover, fold: nil, active: false),
                                       division: nil, window: cover) == .floating)
        let portrait = CGSize(width: 669, height: 951)
        let across = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        #expect(AskPresentation.choose(for: Self.layout(size: portrait, fold: across, active: false),
                                       division: across, window: portrait) == .floating)
        let tabletop = Self.layout(size: portrait, fold: across, active: true)
        #expect(tabletop.deckFrame != nil)
        #expect(AskPresentation.choose(for: tabletop, division: across, window: portrait) == .floating)
        let iPad = CGSize(width: 1194, height: 834)
        let wide = Self.layout(size: iPad, fold: nil, active: false)
        #expect(wide.isSpread)
        #expect(AskPresentation.choose(for: wide, division: nil, window: iPad) == .floating)
        // Floating changes nothing about the pages.
        let spread = Self.layout(size: Self.inner, fold: Self.hinge, active: false)
        #expect(AskPresentation.floating.pages(spread) == spread)
        #expect(AskPresentation.floating.bookFrame(in: Self.inner) == CGRect(origin: .zero, size: Self.inner))
    }

    /// A real pager on the inner display: opening Ask (the beside layout) keeps the page that holds
    /// the position, alone; closing it brings the spread back with that page on the right again.
    @Test func openingAndClosingAskKeepsTheReadingPage() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        let spread = Self.layout(size: Self.inner, fold: Self.hinge, active: false)
        let asking = AskPresentation.choose(for: spread, division: Self.hinge, window: Self.inner)
        let bookFrame = asking.bookFrame(in: Self.inner)
        session.configure(style: ReaderEngineTests.style, textSize: spread.textSize)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.frame = CGRect(origin: .zero, size: Self.inner)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let controller = PagerController(session: session)
        controller.pageTurn = .slide
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)

        func apply(_ layout: PageLayout, frame: CGRect, at location: ReadingLocation) {
            controller.view.frame = frame
            controller.apply(layout: layout, palette: .paper, location: location, animated: false)
            controller.currentSpread?.loadViewIfNeeded()
            controller.view.layoutIfNeeded()
        }
        // A few pages into chapter 2, as a turn would leave it.
        apply(spread, frame: CGRect(origin: .zero, size: Self.inner), at: ReadingLocation(spineIndex: 2, textOffset: 0))
        let chapter = try #require(session.laidOutChapter(2))
        #expect(chapter.pageCount > 4)
        let reading = ReadingLocation(spineIndex: 2, textOffset: chapter.range(ofPage: 3).location)
        apply(spread, frame: CGRect(origin: .zero, size: Self.inner), at: reading)
        #expect(controller.currentSpread?.slots == [PageSlot(spineIndex: 2, page: 2), PageSlot(spineIndex: 2, page: 3)])

        apply(asking.pages(spread), frame: bookFrame, at: reading)
        #expect(controller.currentSpread?.slots == [PageSlot(spineIndex: 2, page: 3)], "beside Ask: the reading page alone")
        #expect(controller.displayedLocation == reading)
        #expect(session.laidOutChapter(2) === chapter, "the same pagination, not a new layout")
        let page = try #require(controller.currentSpread?.pageViews.first)
        #expect(page.convert(page.bounds, to: window) == spread.pageFrames[1], "the page stays where the right page was")

        apply(spread, frame: CGRect(origin: .zero, size: Self.inner), at: reading)
        #expect(controller.currentSpread?.slots == [PageSlot(spineIndex: 2, page: 2), PageSlot(spineIndex: 2, page: 3)])
    }
}

/// The pane's conversation: `AskTurn`s in the model's order (oldest first), each with its quoted
/// passage; nothing in a turn is the on-device model's own, so either provider's turns draw the
/// same. Built from turns directly, not from how a provider stores them (the saved history's order
/// on disk is `scripts/check-ask-duo`'s).
@MainActor
struct AskThreadTests {
    static let limit = ReadingLimit(spineIndex: 2, textOffset: 4000)

    /// A turn from an earlier opening, as the saved history comes back.
    static func saved(_ question: String, subject: String? = nil, answer: String, at seconds: TimeInterval) -> AskTurn {
        AskTurn(question: question, subject: subject, answer: answer, status: .done, askedAt: Date(timeIntervalSince1970: seconds),
                limit: limit, chapter: "Chapter II",
                sources: [AskTurn.Source(location: ReadingLocation(spineIndex: 2, textOffset: 120), chapter: "Chapter II",
                                         snippet: "Curiouser and curiouser")],
                summaryCount: 1, restored: true)
    }

    @Test func theThreadKeepsTheConversationsOrderWithItsPassages() {
        let asking = AskTurn(question: "Why is Alice crying?", answer: "She is too big", status: .answering,
                             limit: Self.limit, chapter: "Chapter II")
        let turns = [
            Self.saved("Who is the White Rabbit?", answer: "A rabbit in a waistcoat Alice follows.", at: 1_000),
            Self.saved("What does this mean?", subject: "Curiouser and curiouser!", answer: "She is so surprised her English slips.", at: 2_000),
            asking,
        ]
        #expect(turns.map(\.question) == ["Who is the White Rabbit?", "What does this mean?", "Why is Alice crying?"])
        #expect(turns.map(\.subject) == [nil, "Curiouser and curiouser!", nil])
        #expect(turns.map(\.status) == [.done, .done, .answering])
        // From an earlier opening: each says where and when it was asked, and keeps its passages.
        #expect(turns[0].caption?.hasPrefix("Chapter II · ") == true)
        #expect(turns[2].caption == nil, "asked in this opening")
        #expect(turns[0].citedSources.map(\.location) == [ReadingLocation(spineIndex: 2, textOffset: 120)])
        #expect(turns[0].sourcesTitle == "Found in 1 passage and 1 chapter summary")
        #expect(turns[2].answer == "She is too big")
    }

    @Test func aQuestionInFlightIsATurnWithoutAnAnswerYet() {
        var turn = AskTurn(question: "What does this mean?", subject: "We’re all mad here.",
                           status: .waiting(note: AskModel.lookingUp), limit: Self.limit, chapter: "Chapter VI")
        turn.sources = [AskTurn.Source(location: ReadingLocation(spineIndex: 6, textOffset: 10), chapter: "Chapter VI", snippet: "mad")]
        #expect(turn.subject == "We’re all mad here.")
        #expect(turn.caption == nil, "asked in this opening")
        guard case .waiting = turn.status else {
            Issue.record("looking up reads as \(turn.status)")
            return
        }
        #expect(turn.citedSources.isEmpty, "the lookups are not the answer's passages yet")

        turn.status = .answering
        turn.answer = "The Cat"
        #expect(turn.status == .answering && turn.answer == "The Cat")
        #expect(turn.citedSources.isEmpty)

        turn.status = .failed("Stopped.")
        #expect(turn.citedSources.isEmpty)

        turn.status = .done
        #expect(turn.citedSources.map(\.chapter) == ["Chapter VI"])
        #expect(turn.sourcesTitle == "Found in 1 passage")
    }

    /// A question asked through the model starts as #89 showed it: waiting, looking through
    /// what's been read, until the provider writes.
    @Test func aNewQuestionWaitsLookingThroughTheBook() async throws {
        let url = try #require(Bundle(for: AskThreadBundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let session = BookSession(book: Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false), fileURL: url)
        await session.load()
        final class Silent: AskProvider {
            var availability = AskAvailability.available
            var about: String? { nil }
            var notice: String? { nil }
            func refresh() async {}
            func conversation() async -> [AskTurn] { [] }
            func answer(_ question: AskQuestion, report: (AskUpdate) -> Void) async {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            }
            func keep(_ turns: [AskTurn]) async {}
            func clear() async {}
            func readerMoved(to spine: Int) {}
        }
        let model = AskModel(session: session, bookID: UUID()) { _ in Silent() }
        model.limit = Self.limit
        model.ask("Who is late?")
        #expect(model.turns.last?.status == .waiting(note: "Looking through what you’ve read…"))
        #expect(model.turns.last?.limit == Self.limit && model.turns.last?.restored == false)
        model.cancel()
    }
}

private final class AskThreadBundleMarker {}
