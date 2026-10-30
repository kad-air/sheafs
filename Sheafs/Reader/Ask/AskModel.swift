import Foundation
import Observation
import SheafsKit

/// "Ask about the book": questions answered by Apple's on-device model from the text up to the
/// reader's place. Owned by `ReaderView` for the reader's life, so the conversation and the passage
/// index stay while the sheet comes and goes. Each question: look the read part up (search words
/// from the model, cut to names the text has), gather passages and chapter summaries within the
/// model's small context (`AskContextBuilder`), stream the answer.
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
        var answer = ""
        var state = State.lookingUp
        var sources: [Source] = []
        var summaryCount = 0
    }

    let session: BookSession
    let recaps: RecapBuilder
    var draft = ""
    private(set) var exchanges: [Exchange] = []
    private(set) var availability = AskEngine.availability
    /// The end of what the reader has read: set by the reader before the sheet opens.
    var limit = ReadingLimit(spineIndex: 0, textOffset: 0)
    private var indexed: (limit: ReadingLimit, index: PassageIndex)?
    private var answering: Task<Void, Never>?

    init(session: BookSession, bookID: UUID) {
        self.session = session
        recaps = RecapBuilder(session: session, store: RecapStore(bookID: bookID))
    }

    var isBusy: Bool { answering != nil }

    func refreshAvailability() { availability = AskEngine.availability }

    /// The reader moved: summarise chapters finished since.
    func readerMoved(to spine: Int) { recaps.start(before: spine) }

    func ask(_ text: String? = nil) {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, answering == nil else { return }
        refreshAvailability()
        guard availability.isAvailable else { return }
        draft = ""
        let earlier = exchanges.last { $0.state == .done }.map { (question: $0.question, answer: $0.answer) }
        exchanges.append(Exchange(question: question))
        let id = exchanges[exchanges.count - 1].id
        answering = Task {
            recaps.pause()
            await answer(question, earlier: earlier, id: id)
            recaps.resume()
            answering = nil
        }
    }

    func cancel() {
        answering?.cancel()
    }

    func clear() {
        cancel()
        exchanges.removeAll()
    }

    private func update(_ id: UUID, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    private func answer(_ question: String, earlier: (question: String, answer: String)?, id: UUID) async {
        let limit = self.limit
        let index = await passageIndex(for: limit)
        guard !Task.isCancelled else { return update(id) { $0.state = .failed("Stopped.") } }

        // Search words: the model's (names, other names of the same people, key words) kept to the
        // ones the read text has, then the question's own words.
        let suggested = await AskEngine.searchTerms(question: question, earlier: earlier?.question, names: index.topNames(150))
        let terms = index.presentTerms(suggested + PassageIndex.words(question))
        AskEngine.log.info("ask: terms \(terms.joined(separator: ", "), privacy: .private)")

        let chapters = session.chapters.count
        var labels: [Int: String] = [:]
        for spine in 0 ..< chapters { labels[spine] = session.chapterTitle(for: spine) ?? "Chapter \(spine + 1)" }
        let summaries = recaps.recaps(before: limit.spineIndex)
        let earlierLength = earlier.map { $0.question.count + min(400, $0.answer.count) } ?? 0
        var budget = AskEngine.contextBudget(question: question, earlier: earlierLength)

        for attempt in 0 ..< 2 {
            let context = AskContextBuilder.build(index: index, terms: terms, recaps: summaries, limit: limit,
                                                  budget: budget, chapterLabel: { labels[$0] ?? "Chapter \($0 + 1)" })
            update(id) {
                $0.state = .answering
                $0.answer = ""
                $0.summaryCount = context.recaps.count
                $0.sources = context.excerpts.filter { $0.kind == .found }.prefix(8).map { excerpt in
                    Source(location: ReadingLocation(spineIndex: excerpt.passage.spineIndex, textOffset: excerpt.passage.range.lowerBound),
                           chapter: labels[excerpt.passage.spineIndex] ?? "",
                           snippet: String(excerpt.passage.text.prefix(160)))
                }
            }
            if context.excerpts.isEmpty && context.recaps.isEmpty {
                return update(id) { $0.state = .failed("There’s nothing read yet to answer from.") }
            }
            let prompt = AskEngine.answerPrompt(question: question, context: context.text, earlier: earlier)
            do {
                for try await partial in AskEngine.answer(prompt: prompt) {
                    update(id) { $0.answer = partial }
                }
                if Task.isCancelled { return update(id) { $0.state = .failed("Stopped.") } }
                return update(id) { $0.state = .done }
            } catch {
                switch AskEngine.classify(error) {
                case .contextTooLong where attempt == 0:
                    AskEngine.log.notice("ask: context too long at \(budget), retrying smaller")
                    budget = budget * 3 / 5
                case .declined:
                    return update(id) { $0.state = .failed("The on-device model declined to answer this one.") }
                case .contextTooLong, .other:
                    AskEngine.log.error("ask failed: \(error)")
                    return update(id) { $0.state = .failed(Task.isCancelled ? "Stopped." : "Couldn’t answer: \(error.localizedDescription)") }
                }
            }
        }
    }

    /// The read part's passages and index, built off the main actor and kept until the reader moves.
    private func passageIndex(for limit: ReadingLimit) async -> PassageIndex {
        if let indexed, indexed.limit == limit { return indexed.index }
        let chapters = session.chapters
        let index = await Task.detached(priority: .userInitiated) {
            PassageIndex(passages: ReadSoFar.passages(chapters: chapters, limit: limit))
        }.value
        indexed = (limit, index)
        return index
    }
}
