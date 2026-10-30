import Foundation
import FoundationModels
import os

/// Whether Apple's on-device model can run here, in words the reader can act on.
nonisolated enum AskAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    case unknown

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available: "Ready on this device."
        case .deviceNotEligible: "This device can’t run Apple Intelligence, which Ask needs."
        case .appleIntelligenceOff: "Turn on Apple Intelligence in the Settings app to use Ask."
        case .modelNotReady: "Apple Intelligence is still getting ready. Try again in a little while."
        case .unknown: "Apple’s on-device model isn’t available right now."
        }
    }
}

/// The reading companion's calls to Apple's on-device model (Foundation Models). Every prompt is
/// built from `ReadSoFar` passages and the summaries made from them, never from the book's later
/// text; the model is never told the book's title or author, so it has less to recall a plot by.
enum AskEngine {
    static let log = Logger(subsystem: "io.sheafs.reader", category: "ask")

    static var availability: AskAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        @unknown default:
            return .unknown
        }
    }

    /// The model's context in tokens, prompt and answer together (4096 when it can't say).
    static var contextTokens: Int {
        let size = SystemLanguageModel.default.contextSize
        return size > 0 ? size : 4096
    }

    /// English runs three to four characters a token (TN3193); invented names and dialogue cost
    /// more, so plan on three.
    static let charactersPerToken = 3.0

    /// Book text is violent, grieving, sometimes cruel: the permissive guardrails are the ones Apple
    /// gives for working on text the user supplies rather than writing new content.
    static var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    // MARK: Search words

    /// Which words to look the question up by: the names it is about, the other names the SAME
    /// characters or places go by among the names the text uses, and a few key words. The caller
    /// keeps only those the read text has (`PassageIndex.presentTerms`).
    static func searchTerms(question: String, earlier: String?, names: [String]) async -> [String] {
        let session = LanguageModelSession(model: model, instructions: """
            You help look things up in a novel. Given a reader's question and the names used in the \
            part they have read, list what to search the text for: the names the question is about, \
            other names from the list that the same character, group or place goes by, and up to \
            three other key words. Most important first.
            """)
        var prompt = "Question: \(question)\n"
        if let earlier { prompt += "Previous question: \(earlier)\n" }
        prompt += "Names in the text: " + names.joined(separator: ", ")
        do {
            let plan = try await session.respond(to: prompt, generating: AskSearchPlan.self,
                                                 options: GenerationOptions(temperature: 0))
            return plan.content.terms
        } catch {
            log.error("search terms failed: \(error)")
            return []
        }
    }

    // MARK: Answers

    static let answerInstructions = """
        You answer a reader's questions about the novel they are reading, using ONLY the excerpts \
        and chapter summaries you are given, which come from the part they have already read. \
        Never use anything you know about this book, its author, adaptations or sequels from \
        elsewhere, and never guess, hint at or foreshadow what happens later. If the excerpts don't \
        answer the question, say you can't tell from what they've read so far. Answer in two to \
        five plain sentences. Say who people are by how the text describes them.
        """

    static func answerPrompt(question: String, context: String, earlier: (question: String, answer: String)?) -> String {
        var prompt = "From the book, up to where the reader is:\n\n\(context)\n\n"
        if let earlier {
            prompt += "They asked before: \(earlier.question)\nYou answered: \(earlier.answer.prefix(400))\n\n"
        }
        return prompt + "Question: \(question)"
    }

    /// The answer as it streams (each element the whole answer so far).
    static func answer(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let session = LanguageModelSession(model: model, instructions: answerInstructions)
                    let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.2,
                                                                                              maximumResponseTokens: responseTokens))
                    for try await snapshot in stream { continuation.yield(snapshot.content) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let responseTokens = 320

    /// How many UTF-16 units of book text fit beside the instructions, the question and the answer.
    static func contextBudget(question: String, earlier: Int) -> Int {
        let fixed = Double(answerInstructions.count + question.count + earlier + 200) / charactersPerToken
        let tokens = Double(contextTokens - responseTokens) - fixed - 150
        return max(1500, Int(tokens * charactersPerToken))
    }

    // MARK: Chapter summaries

    static let recapInstructions = """
        You summarise part of a novel for a reader who has already read it. Write plain prose in \
        the past tense: who appears, what they do, what they learn and what changes. Name people \
        and places as the text names them. Use only the text given; never add anything you know \
        about the book from elsewhere.
        """

    /// The summary of a chapter so far, carried forward over its next part (TN3193's chunk-and-carry).
    static func recap(part: String, carrying summary: String?) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: recapInstructions)
        let prompt: String
        if let summary, !summary.isEmpty {
            prompt = "Summary so far:\n\(summary)\n\nThe text that follows:\n\(part)\n\n"
                + "Rewrite the summary so it covers both, in at most 150 words."
        } else {
            prompt = "Text:\n\(part)\n\nSummarise it in at most 120 words."
        }
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2,
                                                                                        maximumResponseTokens: 260))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How long a part of a chapter may be to fit beside the instructions, a carried summary and
    /// the new summary.
    static var recapPartLength: Int {
        let tokens = Double(contextTokens) - 260 - 300 - Double(recapInstructions.count) / charactersPerToken - 120
        return max(2000, Int(tokens * charactersPerToken * 0.9))
    }

    // MARK: Errors

    enum Failure {
        case contextTooLong
        case declined
        case other(String)
    }

    static func classify(_ error: Error) -> Failure {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextTooLong
            case .guardrailViolation, .refusal: return .declined
            default: return .other(error.localizedDescription)
            }
        }
        return .other(error.localizedDescription)
    }
}

@Generable
nonisolated struct AskSearchPlan {
    @Guide(description: "Names and words to search for, most important first", .maximumCount(10))
    var terms: [String]
}
