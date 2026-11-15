import Foundation
import SheafsKit

/// Sheafs' own Ask provider: questions answered by Apple's on-device model from the text up to
/// the reader's place. Each question: look the read part up (search words from the model, cut to
/// names the text has), gather passages and chapter summaries within the model's small context
/// (`AskContextBuilder`), stream the answer. The passage index stays while the reader is open;
/// the conversation is kept per book on this device (`AskHistoryStore`).
@MainActor
final class OnDeviceAskProvider: AskProvider {
    let session: BookSession
    let recaps: RecapBuilder
    private let history: AskHistoryStore
    private var indexed: (limit: ReadingLimit, index: PassageIndex)?

    init(session: BookSession, bookID: UUID) {
        self.session = session
        recaps = RecapBuilder(session: session, store: RecapStore(bookID: bookID))
        history = AskHistoryStore(bookID: bookID)
    }

    var availability: AskAvailability { AskEngine.availability }
    var about: String? { nil }
    var notice: String? { nil }

    func refresh() async {}

    /// The conversation saved on this device.
    var savedTurns: [AskTurn] { history.entries.map(AskTurn.init) }

    func conversation() async -> [AskTurn] { savedTurns }

    func keep(_ turns: [AskTurn]) async { history.save(turns.map(\.entry)) }

    func clear() async { history.save([]) }

    /// Summarise chapters finished since.
    func readerMoved(to spine: Int) { recaps.start(before: spine) }

    func answer(_ question: AskQuestion, report: (AskUpdate) -> Void) async {
        recaps.pause()
        defer { recaps.resume() }
        let limit = question.limit, subject = question.subject, earlier = question.earlier
        let index = await passageIndex(for: limit)
        guard !Task.isCancelled else { return report(.failed("Stopped.")) }

        // Search words: the model's (names, other names of the same people, key words) kept to the
        // ones the read text has, then the question's own words.
        let suggested = await AskEngine.searchTerms(question: question.text, earlier: earlier?.question, subject: subject,
                                                    names: index.topNames(150))
        let terms = index.presentTerms(suggested + PassageIndex.words(question.text))
        AskEngine.log.info("ask: terms \(terms.joined(separator: ", "), privacy: .private)")

        let chapters = session.chapters.count
        var labels: [Int: String] = [:]
        for spine in 0 ..< chapters { labels[spine] = session.chapterTitle(for: spine) ?? "Chapter \(spine + 1)" }
        let summaries = recaps.recaps(before: limit.spineIndex)
        let earlierLength = earlier.map { $0.question.count + min(400, $0.answer.count) } ?? 0
        var budget = AskEngine.contextBudget(question: question.text, earlier: earlierLength, subject: subject?.utf16.count ?? 0)

        func source(for excerpt: AskContext.Excerpt) -> AskModel.Source {
            AskModel.Source(location: ReadingLocation(spineIndex: excerpt.passage.spineIndex, textOffset: excerpt.passage.range.lowerBound),
                            chapter: labels[excerpt.passage.spineIndex] ?? "",
                            snippet: String(excerpt.passage.text.prefix(160)))
        }

        for attempt in 0 ..< 2 {
            let context = AskContextBuilder.build(index: index, terms: terms, recaps: summaries, limit: limit,
                                                  budget: budget, chapterLabel: { labels[$0] ?? "Chapter \($0 + 1)" })
            report(.answering(sources: context.excerpts.filter { $0.kind == .found }.prefix(8).map(source(for:)),
                              summaryCount: context.recaps.count))
            if context.excerpts.isEmpty && context.recaps.isEmpty {
                return report(.failed("There’s nothing read yet to answer from."))
            }
            let prompt = AskEngine.answerPrompt(question: question.text, context: context.text, names: index.topNames(15),
                                                earlier: earlier, subject: subject)
            var answer = ""
            do {
                for try await partial in AskEngine.answer(prompt: prompt) {
                    answer = partial
                    report(.text(partial))
                }
                if Task.isCancelled { return report(.failed("Stopped.")) }
                // Cite what the answer drew on (recent passages included), not every match; an
                // answer that shares nothing with them keeps the matches it was looked up in.
                let cited = context.citations(for: answer, question: question.text)
                return report(.done(sources: cited.isEmpty ? nil : cited.map(source(for:))))
            } catch {
                switch AskEngine.classify(error) {
                case .contextTooLong where attempt == 0:
                    AskEngine.log.notice("ask: context too long at \(budget), retrying smaller")
                    budget = budget * 3 / 5
                case .declined:
                    return report(.failed("The on-device model declined to answer this one."))
                case .contextTooLong, .other:
                    AskEngine.log.error("ask failed: \(error)")
                    return report(.failed(Task.isCancelled ? "Stopped." : "Couldn’t answer: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// The read part's passages and index, built off the main actor and kept until the reader moves.
    private func passageIndex(for limit: ReadingLimit) async -> PassageIndex {
        if let indexed, indexed.limit == limit { return indexed.index }
        let chapters = session.chapters
        let index = await Task.detached(priority: .userInitiated) {
            // Title pages and half-titles (a line or two) match every question about the hero named
            // in the title and tell the model nothing; leave such short chapters out.
            let passages = ReadSoFar.passages(chapters: chapters, limit: limit)
                .filter { chapters[$0.spineIndex].textLength >= 400 }
            return PassageIndex(passages: passages)
        }.value
        indexed = (limit, index)
        return index
    }
}

extension AskTurn {
    /// A question saved on this device (`AskHistoryStore`).
    init(_ entry: AskHistoryStore.Entry) {
        self.init(question: entry.question, subject: entry.subject, answer: entry.answer, askedAt: entry.askedAt,
                  limit: ReadingLimit(spineIndex: entry.limitSpine, textOffset: entry.limitOffset),
                  chapter: entry.chapter,
                  sources: entry.sources.map {
                      AskModel.Source(location: ReadingLocation(spineIndex: $0.spineIndex, textOffset: $0.textOffset),
                                      chapter: $0.chapter, snippet: $0.snippet)
                  },
                  summaryCount: entry.summaryCount)
    }

    /// As saved on this device.
    var entry: AskHistoryStore.Entry {
        AskHistoryStore.Entry(question: question, subject: subject, answer: answer,
                              sources: sources.map { .init(spineIndex: $0.location.spineIndex, textOffset: $0.location.textOffset,
                                                           chapter: $0.chapter, snippet: $0.snippet) },
                              summaryCount: summaryCount, askedAt: askedAt, chapter: chapter,
                              limitSpine: limit?.spineIndex ?? 0, limitOffset: limit?.textOffset ?? 0)
    }
}
