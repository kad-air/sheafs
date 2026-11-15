import Foundation
import Observation
import SheafsKit

/// "Ask about the book": the panel's side of Ask. Owned by `ReaderView` for the reader's life, so
/// the provider's passage index stays while the panel comes and goes. It holds the conversation
/// (`exchanges`, oldest first): the provider's saved one, asked for once when the model is made,
/// then each question asked here, its answer streaming in. Who answers and keeps the conversation
/// is the `AskProvider`: Apple's on-device model (`OnDeviceAskProvider`, finished answers kept per
/// book in `AskHistoryStore`), unless this build's plugin supplies another for the book.
@Observable
@MainActor
final class AskModel {
    struct Source: Identifiable, Hashable {
        let id = UUID()
        var location: ReadingLocation
        var chapter: String
        var snippet: String
    }

    struct Exchange: Identifiable {
        enum State: Equatable {
            case lookingUp
            case answering
            case done
            case failed(String)
        }
        let id = UUID()
        var question: String
        /// The passage it was asked about (picked in the book), as the model was given it.
        var subject: String?
        var answer = ""
        var state = State.lookingUp
        var sources: [Source] = []
        var summaryCount = 0
        var askedAt = Date.now
        /// The chapter the reader was in when asking.
        var chapter = ""
        /// What the answer was made within.
        var limit: ReadingLimit
        /// How far the reader had read, in words of the book, when the provider counts so.
        var wordsRead: Int?
        /// Asked while the book was open before: shown, but not followed up on (`ask`).
        var restored = false

        init(question: String, subject: String? = nil, chapter: String, limit: ReadingLimit) {
            self.question = question
            self.subject = subject
            self.chapter = chapter
            self.limit = limit
        }

        /// A turn of the provider's saved conversation.
        init(_ turn: AskTurn) {
            question = turn.question
            subject = turn.subject
            answer = turn.answer
            state = .done
            sources = turn.sources
            summaryCount = turn.summaryCount
            askedAt = turn.askedAt
            chapter = turn.chapter
            limit = turn.limit ?? ReadingLimit(spineIndex: 0, textOffset: 0)
            wordsRead = turn.wordsRead
            restored = true
        }

        var turn: AskTurn {
            AskTurn(question: question, subject: subject, answer: answer, askedAt: askedAt, limit: limit,
                    wordsRead: wordsRead, chapter: chapter, sources: sources, summaryCount: summaryCount)
        }
    }

    /// A passage picked in the book to ask about, with its text as the model will be given it.
    struct Subject: Equatable {
        var passage: AskSubject
        var text: String
    }

    /// The question the draft starts with when a passage is attached.
    static let subjectQuestion = "What does this mean?"

    let session: BookSession
    /// Apple's on-device model for this book: the provider, unless a plugin's is (which may hand
    /// it questions).
    let onDevice: OnDeviceAskProvider
    /// Who answers and keeps the conversation.
    let provider: any AskProvider
    /// The on-device model's chapter summaries (written only while it is answering this book).
    var recaps: RecapBuilder { onDevice.recaps }
    var draft = ""
    /// The passage the next question is about (the selection menu's Ask), quoted in the panel.
    private(set) var subject: Subject?
    private(set) var exchanges: [Exchange] = []
    private(set) var availability: AskAvailability
    /// The end of what the reader has read: set by the reader when the panel opens, and moved on
    /// as they turn pages with it open.
    var limit = ReadingLimit(spineIndex: 0, textOffset: 0)
    private var answering: Task<Void, Never>?

    /// `provider`: makes the provider from the on-device one; nil asks this build's plugin
    /// (`SheafsPlugin.askProvider(for:)`), and without one the on-device model answers.
    init(session: BookSession, bookID: UUID, provider makeProvider: ((AskProviderContext) -> (any AskProvider)?)? = nil) {
        self.session = session
        let onDevice = OnDeviceAskProvider(session: session, bookID: bookID)
        self.onDevice = onDevice
        let context = AskProviderContext(book: session.book, session: session, onDevice: onDevice)
        provider = (makeProvider ?? { Plugins.current?.askProvider(for: $0) })(context) ?? onDevice
        availability = provider.availability
        if provider === onDevice {
            // On this device it is at hand: there from the start, as before providers.
            exchanges = onDevice.savedTurns.map(Exchange.init)
        } else {
            Task { await loadConversation() }
        }
    }

    var isBusy: Bool { answering != nil }

    /// Where answers come from, when it isn't the on-device model (`AskProvider.about`).
    var about: String? { provider.about }
    /// What the reader should know about the next answer (`AskProvider.notice`).
    var notice: String? { provider.notice }

    /// The panel opened: ask the provider again whether it can answer, and (unless it is the
    /// on-device one) for the conversation as it is now: one kept elsewhere may have moved on
    /// since (asked on another device, or an answer that finished after the app went away).
    func refreshAvailability() {
        availability = provider.availability
        Task {
            await provider.refresh()
            availability = provider.availability
            if provider !== onDevice, !isBusy { await loadConversation() }
        }
    }

    /// The provider's saved conversation, then what it doesn't have: questions asked here that
    /// are still being answered or failed (a finished one is in the provider's by then).
    private func loadConversation() async {
        let saved = await provider.conversation()
        exchanges = saved.map(Exchange.init) + exchanges.filter { !$0.restored && $0.state != .done }
    }

    /// Attaches a passage picked in the book as the subject of the next question, and starts the
    /// draft with `subjectQuestion`. 🔴 Its text is cut to the current limit like everything else
    /// the model sees (`AskSubject.text`); a passage wholly past it is refused (false).
    @discardableResult
    func attach(_ passage: AskSubject) -> Bool {
        guard let text = passage.text(in: session.chapters, limit: limit) else {
            AskEngine.log.notice("ask: subject \(passage.spineIndex):\(passage.range.lowerBound) refused, past the limit")
            return false
        }
        subject = Subject(passage: passage, text: text)
        draft = Self.subjectQuestion
        return true
    }

    func detachSubject() {
        if draft == Self.subjectQuestion { draft = "" }
        subject = nil
    }

    /// The reader moved (the on-device model summarises chapters finished since).
    func readerMoved(to spine: Int) { provider.readerMoved(to: spine) }

    func ask(_ text: String? = nil) {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, answering == nil else { return }
        availability = provider.availability
        guard availability.isAvailable else { return }
        draft = ""
        // The attached passage goes with this question, cut to the limit again as it is now.
        let subject = self.subject.flatMap { $0.passage.text(in: session.chapters, limit: limit) }
        self.subject = nil
        // A follow-up builds on the last answer from this opening, and only one made within the
        // current limit (an answer from further on would carry what lies past it).
        var earlier: (question: String, answer: String)?
        if let last = exchanges.last(where: { $0.state == .done }), !last.restored, admits(last.limit) {
            // "What does this mean?" says nothing without the passage it was about.
            let asked = last.subject.map { "\(last.question) (about the passage “\($0.prefix(200))”)" } ?? last.question
            earlier = (asked, last.answer)
        }
        let chapter = session.chapterTitle(for: limit.spineIndex) ?? "Chapter \(limit.spineIndex + 1)"
        exchanges.append(Exchange(question: question, subject: subject, chapter: chapter, limit: limit))
        let id = exchanges[exchanges.count - 1].id
        let request = AskQuestion(text: question, subject: subject, earlier: earlier, limit: limit)
        answering = Task {
            await provider.answer(request) { apply($0, to: id) }
            // A provider that returned without finishing was stopped, or let the question go.
            if let exchange = exchanges.first(where: { $0.id == id }), exchange.state == .lookingUp || exchange.state == .answering {
                update(id) { $0.state = .failed(Task.isCancelled ? "Stopped." : "No answer came back.") }
            }
            answering = nil
            if exchanges.contains(where: { $0.id == id && $0.state == .done }) { await keepConversation() }
        }
    }

    func cancel() {
        answering?.cancel()
    }

    /// Forgets this book's questions and answers, the saved ones too.
    func clear() {
        cancel()
        exchanges.removeAll()
        Task { await provider.clear() }
    }

    /// Moves the limit on (never back) while the panel is open and the reader turns pages.
    func extendLimit(to newer: ReadingLimit) {
        if !admits(newer) { limit = newer }
    }

    /// Whether `other` is at or before the current limit.
    private func admits(_ other: ReadingLimit) -> Bool {
        other.spineIndex < limit.spineIndex || (other.spineIndex == limit.spineIndex && other.textOffset <= limit.textOffset)
    }

    private func keepConversation() async {
        await provider.keep(exchanges.filter { $0.state == .done && !$0.answer.isEmpty }.map(\.turn))
    }

    private func update(_ id: UUID, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    private func apply(_ progress: AskUpdate, to id: UUID) {
        update(id) { exchange in
            switch progress {
            case .answering(let sources, let summaryCount):
                exchange.state = .answering
                exchange.answer = ""
                exchange.summaryCount = summaryCount
                exchange.sources = sources
            case .text(let text):
                exchange.answer = text
            case .done(let sources):
                exchange.state = .done
                if let sources { exchange.sources = sources }
            case .failed(let message):
                exchange.state = .failed(message)
            }
        }
    }
}
