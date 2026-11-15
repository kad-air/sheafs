import Foundation
import SheafsKit

/// What answers Ask's questions about one book and keeps the conversation about it. Sheafs' own is
/// `OnDeviceAskProvider` (Apple's on-device model, the conversation in Application Support/Ask); a
/// plugin may supply another for a book (`SheafsPlugin.askProvider(for:)`), which may hand questions
/// back to the on-device one (`AskProviderContext.onDevice`). `AskModel` is the panel's side: it
/// holds the conversation as `Exchange`s, asks the provider for it once when made, appends each new
/// question, and hands the finished ones back to `keep`.
@MainActor
protocol AskProvider: AnyObject {
    /// Whether it can answer now; the panel shows `message` when it can't.
    var availability: AskAvailability { get }
    /// Where answers come from, for the panel's introduction, when that isn't Apple's on-device
    /// model with nothing leaving the device (nil: it is, and the panel says so itself).
    var about: String? { get }
    /// What the reader should know about the next answer, shown over the question field (nil: nothing).
    var notice: String? { get }
    /// The panel opened: look again at what `availability` and `notice` say.
    func refresh() async
    /// The conversation so far, oldest first.
    func conversation() async -> [AskTurn]
    /// Answers one question, reporting as it goes (`AskUpdate`), and returns when it is done or
    /// cancelled (the panel's Stop cancels the task). 🔴 Nothing past `question.limit` may reach it.
    func answer(_ question: AskQuestion, report: (AskUpdate) -> Void) async
    /// The conversation after an answer finished, oldest first, to keep for the next opening.
    func keep(_ turns: [AskTurn]) async
    /// Forgets the conversation.
    func clear() async
    /// The reader turned to chapter `spine` while Ask is on.
    func readerMoved(to spine: Int)
}

/// What a provider for one book gets to work with.
struct AskProviderContext {
    let book: Book
    let session: BookSession
    /// Apple's on-device model for this book, for a provider that hands it some questions.
    let onDevice: OnDeviceAskProvider
}

/// One question, as `AskModel.ask` puts it to the provider.
struct AskQuestion {
    var text: String
    /// The passage picked in the book that it is about, already cut to `limit` (`AskSubject.text`).
    var subject: String?
    /// The previous question and answer from this opening, made within `limit`, for a follow-up.
    var earlier: (question: String, answer: String)?
    /// 🔴 The end of what the reader has read: the end of the page holding the position.
    var limit: ReadingLimit
}

/// What a provider reports while it answers.
enum AskUpdate {
    /// It looked the question up and is answering, maybe again (any answer so far is dropped):
    /// the passages it found and how many chapter summaries it was given.
    case answering(sources: [AskModel.Source], summaryCount: Int)
    /// The whole answer so far.
    case text(String)
    /// The answer is complete; `sources`, when given, replace the ones from `answering`.
    case done(sources: [AskModel.Source]?)
    /// It couldn't answer, in words for the reader ("Stopped." when cancelled).
    case failed(String)
}

/// One finished question and answer of a book's conversation, as a provider keeps it.
struct AskTurn: Equatable {
    var question: String
    /// The passage it was asked about, as the provider was given it.
    var subject: String?
    var answer: String
    var askedAt: Date
    /// How far the reader had read: the reading limit it was answered within, when the provider
    /// keeps it in the book's own offsets.
    var limit: ReadingLimit?
    /// The same counted in words of the book, for a provider that measures it so.
    var wordsRead: Int?
    /// The chapter the reader was in ("" when not known).
    var chapter = ""
    /// The passages the answer came from.
    var sources: [AskModel.Source] = []
    var summaryCount = 0
}
