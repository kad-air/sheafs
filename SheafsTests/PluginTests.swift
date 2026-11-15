import Testing
import Foundation
import SheafsKit
@testable import Sheafs

private final class BundleMarker {}

/// An Ask provider that answers from a script and records what it was asked, kept and told.
@MainActor
private final class ScriptedProvider: AskProvider {
    var availability = AskAvailability.available
    var about: String? = "Answers come from elsewhere."
    var notice: String?
    var saved: [AskTurn] = []
    var script: [AskUpdate] = []
    /// Answers nothing until cancelled.
    var hangs = false
    private(set) var asked: [AskQuestion] = []
    private(set) var kept: [[AskTurn]] = []
    private(set) var cleared = 0
    private(set) var refreshed = 0
    private(set) var moves: [Int] = []

    func refresh() async {
        refreshed += 1
        notice = "Checked again."
    }

    func conversation() async -> [AskTurn] { saved }

    func answer(_ question: AskQuestion, report: (AskUpdate) -> Void) async {
        asked.append(question)
        while hangs, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        if Task.isCancelled { return }
        for update in script { report(update) }
    }

    func keep(_ turns: [AskTurn]) async { kept.append(turns) }
    func clear() async { cleared += 1 }
    func readerMoved(to spine: Int) { moves.append(spine) }
}

/// A plugin that hands every book to one provider, and one that adds nothing.
@MainActor
private final class ProviderPlugin: SheafsPlugin {
    let provider: ScriptedProvider
    private(set) var contexts: [AskProviderContext] = []
    init(_ provider: ScriptedProvider) { self.provider = provider }
    func askProvider(for context: AskProviderContext) -> (any AskProvider)? {
        contexts.append(context)
        return provider
    }
}

@MainActor
private final class EmptyPlugin: SheafsPlugin {}

/// The plugin seam (`SheafsPlugin`, `AskProvider`): without a plugin Ask is the on-device model
/// as before; a plugin's provider answers into the same conversation, which it loads and keeps.
@MainActor
struct PluginTests {
    static func alice() async throws -> BookSession {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        try #require(session.isReady)
        return session
    }

    /// Waits (up to 2 s) for the model's tasks to get there.
    static func settle(_ done: () -> Bool) async {
        for _ in 0 ..< 200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func withoutAPluginTheOnDeviceModelAnswers() async throws {
        #expect(Plugins.current == nil, "Sheafs itself has no plugin")
        let model = AskModel(session: try await Self.alice(), bookID: UUID())
        #expect(model.provider === model.onDevice)
        #expect(model.about == nil && model.notice == nil, "the panel keeps its own on-device wording")
        #expect(model.availability == AskEngine.availability)
    }

    @Test func aPluginsProviderTakesTheBook() async throws {
        let session = try await Self.alice()
        let provider = ScriptedProvider()
        let plugin = ProviderPlugin(provider)
        // Set and cleared with no suspension between, so no other test's model sees it.
        Plugins.current = plugin
        let model = AskModel(session: session, bookID: session.book.id)
        Plugins.current = EmptyPlugin()
        let plain = AskModel(session: session, bookID: session.book.id)
        Plugins.current = nil
        #expect(model.provider === provider)
        let context = try #require(plugin.contexts.first)
        #expect(context.book === session.book && context.session === session)
        #expect(context.onDevice === model.onDevice, "the provider can hand questions to the on-device model")
        #expect(model.about == "Answers come from elsewhere.")
        #expect(plain.provider === plain.onDevice, "a plugin without a provider leaves Ask alone")
    }

    @Test func pluginDefaultsAddNothing() {
        let plugin = EmptyPlugin()
        #expect(plugin.settingsScreens.isEmpty && plugin.libraryScreens.isEmpty)
        #expect(plugin.bookActions(for: Book(title: "A", author: nil, language: nil, fileSize: 1, partialMD5: nil, hasCover: false)).isEmpty)
    }

    @Test func theConversationComesFromTheProvider() async throws {
        let provider = ScriptedProvider()
        let asked = Date(timeIntervalSince1970: 1_800_000_000)
        provider.saved = [
            AskTurn(question: "Who is the Hatter?", answer: "A host.", askedAt: asked, wordsRead: 1200),
            AskTurn(question: "What does this mean?", subject: "Twinkle, twinkle, little bat!", answer: "A parody.",
                    askedAt: asked.addingTimeInterval(60), limit: ReadingLimit(spineIndex: 8, textOffset: 900), chapter: "VII"),
        ]
        let model = AskModel(session: try await Self.alice(), bookID: UUID()) { _ in provider }
        await Self.settle { model.exchanges.count == 2 }
        #expect(model.exchanges.map(\.question) == ["Who is the Hatter?", "What does this mean?"], "oldest first")
        #expect(model.exchanges.allSatisfy { $0.restored && $0.state == .done })
        #expect(model.exchanges[0].wordsRead == 1200)
        #expect(model.exchanges[1].subject == "Twinkle, twinkle, little bat!")
        #expect(model.exchanges[1].limit == ReadingLimit(spineIndex: 8, textOffset: 900))
        #expect(model.exchanges[1].turn == provider.saved[1], "a turn comes back as it went in")
    }

    /// A conversation kept elsewhere is asked for again each time the panel opens; this
    /// opening's finished answers come back from it (no doubles), unfinished ones stay.
    @Test func theProvidersConversationReloadsWhenThePanelOpens() async throws {
        let provider = ScriptedProvider()
        provider.saved = [AskTurn(question: "One?", answer: "1.", askedAt: .now)]
        let model = AskModel(session: try await Self.alice(), bookID: UUID()) { _ in provider }
        await Self.settle { model.exchanges.count == 1 }
        model.limit = ReadingLimit(spineIndex: 2, textOffset: 400)
        provider.script = [.answering(sources: [], summaryCount: 0), .text("2."), .done(sources: nil)]
        model.ask("Two?")
        await Self.settle { !model.isBusy }
        provider.script = [.failed("Offline.")]
        model.ask("Three?")
        await Self.settle { !model.isBusy }
        // The provider has kept "Two?" (and someone asked "Four?" elsewhere meanwhile).
        provider.saved += [AskTurn(question: "Two?", answer: "2.", askedAt: .now), AskTurn(question: "Four?", answer: "4.", askedAt: .now)]
        model.refreshAvailability()
        await Self.settle { model.exchanges.map(\.question) == ["One?", "Two?", "Four?", "Three?"] }
        #expect(model.exchanges.map(\.question) == ["One?", "Two?", "Four?", "Three?"])
        #expect(model.exchanges.last?.state == .failed("Offline."), "the failed question stays, after the saved ones")
    }

    @Test func answersStreamIntoTheConversationAndAreKept() async throws {
        let session = try await Self.alice()
        let provider = ScriptedProvider()
        provider.saved = [AskTurn(question: "Before?", answer: "Yes.", askedAt: .now)]
        let source = AskModel.Source(location: ReadingLocation(spineIndex: 2, textOffset: 10), chapter: "Down the Rabbit-Hole",
                                     snippet: "Alice was beginning")
        provider.script = [.answering(sources: [source], summaryCount: 1), .text("The"), .text("The rabbit."), .done(sources: nil)]
        let model = AskModel(session: session, bookID: UUID()) { _ in provider }
        await Self.settle { model.exchanges.count == 1 }
        let limit = ReadingLimit(spineIndex: 2, textOffset: 400)
        model.limit = limit
        #expect(model.attach(AskSubject(spineIndex: 2, range: 0 ..< 300)))
        let subject = try #require(model.subject?.text)
        model.ask()
        await Self.settle { !model.isBusy }

        let question = try #require(provider.asked.first)
        #expect(question.text == AskModel.subjectQuestion)
        #expect(question.subject == subject, "the passage goes to the provider as cut to the limit")
        #expect(question.limit == limit)
        #expect(question.earlier == nil)
        let last = try #require(model.exchanges.last)
        #expect(last.state == .done && last.answer == "The rabbit." && last.summaryCount == 1)
        #expect(last.sources == [source])
        #expect(last.subject == subject && !last.restored)
        #expect(provider.kept.last?.map(\.question) == ["Before?", AskModel.subjectQuestion], "the whole conversation is kept")

        // A follow-up carries this opening's answer, and names the passage it was about.
        provider.script = [.answering(sources: [], summaryCount: 0), .text("Yes."), .done(sources: [])]
        model.ask("Why?")
        await Self.settle { !model.isBusy }
        let earlier = try #require(provider.asked.last?.earlier)
        #expect(earlier.answer == "The rabbit.")
        #expect(earlier.question.hasPrefix(AskModel.subjectQuestion) && earlier.question.contains("about the passage"))
        #expect(model.exchanges.last?.sources.isEmpty == true, "done's sources replace the ones it looked up")
    }

    @Test func failuresAndStopReachThePanel() async throws {
        let session = try await Self.alice()
        let provider = ScriptedProvider()
        provider.script = [.answering(sources: [], summaryCount: 0), .text("Partly"), .failed("Couldn’t answer: offline")]
        let model = AskModel(session: session, bookID: UUID()) { _ in provider }
        model.limit = ReadingLimit(spineIndex: 2, textOffset: 400)
        model.ask("Who?")
        await Self.settle { !model.isBusy }
        #expect(model.exchanges.last?.state == .failed("Couldn’t answer: offline"))
        #expect(model.exchanges.last?.answer == "Partly")
        #expect(provider.kept.isEmpty, "a failed answer isn't kept")

        provider.hangs = true
        model.ask("Where?")
        await Self.settle { provider.asked.count == 2 }
        model.cancel()
        await Self.settle { !model.isBusy }
        #expect(model.exchanges.last?.state == .failed("Stopped."))

        provider.hangs = false
        provider.script = []
        model.ask("When?")
        await Self.settle { !model.isBusy }
        #expect(model.exchanges.last?.state == .failed("No answer came back."), "a provider that says nothing")
    }

    @Test func availabilityNoticeMovesAndClearGoThroughTheProvider() async throws {
        let session = try await Self.alice()
        let provider = ScriptedProvider()
        provider.availability = .modelNotReady
        let model = AskModel(session: session, bookID: UUID()) { _ in provider }
        model.ask("Who?")
        #expect(provider.asked.isEmpty && model.exchanges.isEmpty, "no question while the provider can't answer")
        #expect(model.availability == .modelNotReady)

        provider.availability = .available
        model.refreshAvailability()
        await Self.settle { provider.refreshed == 1 && model.availability == .available }
        #expect(model.availability == .available)
        #expect(model.notice == "Checked again.")

        model.readerMoved(to: 3)
        #expect(provider.moves == [3])

        provider.script = [.answering(sources: [], summaryCount: 0), .text("A."), .done(sources: nil)]
        model.ask("Who?")
        await Self.settle { !model.isBusy }
        model.clear()
        await Self.settle { provider.cleared == 1 }
        #expect(provider.cleared == 1 && model.exchanges.isEmpty)
    }

    /// The on-device provider's conversation is today's saved history, there from the start.
    @Test func theOnDeviceProviderKeepsTheSavedHistory() async throws {
        let session = try await Self.alice()
        let id = UUID()
        defer { AskHistoryStore.delete(bookID: id) }
        let entry = AskHistoryStore.Entry(question: "Who is the Hatter?", subject: "Twinkle, twinkle", answer: "A host.",
                                          sources: [.init(spineIndex: 8, textOffset: 40, chapter: "VII", snippet: "The table")],
                                          summaryCount: 2, askedAt: Date(timeIntervalSince1970: 1_800_000_000), chapter: "VII",
                                          limitSpine: 8, limitOffset: 900)
        AskHistoryStore(bookID: id).save([entry])

        let model = AskModel(session: session, bookID: id)
        #expect(model.exchanges.map(\.question) == ["Who is the Hatter?"], "loaded with the model, as before")
        let turns = await model.onDevice.conversation()
        let turn = try #require(turns.first)
        #expect(turn.subject == "Twinkle, twinkle" && turn.answer == "A host." && turn.chapter == "VII")
        #expect(turn.limit == ReadingLimit(spineIndex: 8, textOffset: 900) && turn.summaryCount == 2)
        #expect(turn.sources.map(\.location) == [ReadingLocation(spineIndex: 8, textOffset: 40)])
        #expect(turn.entry == entry, "a saved question round-trips")

        await model.onDevice.keep(turns + [AskTurn(question: "And?", answer: "More.", askedAt: .now)])
        #expect(AskHistoryStore(bookID: id).entries.map(\.question) == ["Who is the Hatter?", "And?"])
        await model.onDevice.clear()
        #expect(AskHistoryStore(bookID: id).entries.isEmpty)
    }
}
