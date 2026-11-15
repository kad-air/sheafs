import SwiftUI

/// The running conversation in the Ask pane: every turn, oldest at the top, the newest at the bottom
/// (the pane scrolls there), each its quoted passage and question, then the answer and its passages.
/// It is drawn from `Turn`s only, and nothing in a turn is particular to who answered: `AskModel`'s
/// exchanges map onto them (`AskModel.thread`), and another backend that keeps its own thread can
/// fill the same view.
struct AskThread: View {
    /// One question and its answer as the pane shows them.
    struct Turn: Identifiable, Equatable {
        enum Status: Equatable {
            /// Asked, nothing written yet; `note` says what is going on, if anything.
            case waiting(note: String?)
            /// The answer is coming in (it may still be empty).
            case answering
            case done
            /// It stopped: what was written stays, `message` says why.
            case failed(String)
        }

        /// A place in the book the answer came from; tapping it turns there.
        struct Source: Identifiable, Equatable {
            var id = UUID()
            var location: ReadingLocation
            var chapter: String
            var snippet: String
        }

        var id: UUID
        var question: String
        /// The passage the question was about (picked in the book), quoted over it.
        var passage: String?
        var answer: String
        var status: Status
        /// Where and when it was asked, for a turn from an earlier opening ("Chapter 22 · yesterday").
        var caption: String?
        /// Empty when the backend doesn't cite.
        var sources: [Source] = []
        /// The heading the sources fold under ("Found in 3 passages").
        var sourcesTitle: String?
    }

    let turns: [Turn]
    var onGo: (ReadingLocation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(turns) { turn in
                AskTurnView(turn: turn, onGo: onGo)
                    .id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AskThread.Turn {
    init(_ exchange: AskModel.Exchange) {
        id = exchange.id
        question = exchange.question
        passage = exchange.subject
        answer = exchange.answer
        switch exchange.state {
        case .lookingUp: status = .waiting(note: "Looking through what you’ve read…")
        case .answering: status = .answering
        case .done: status = .done
        case .failed(let message): status = .failed(message)
        }
        caption = exchange.restored ? exchange.caption : nil
        // The passages are scored against the answer once it is in; until then they are lookups.
        if exchange.state == .done, !exchange.sources.isEmpty {
            sources = exchange.sources.map { Source(id: $0.id, location: $0.location, chapter: $0.chapter, snippet: $0.snippet) }
            let passages = sources.count == 1 ? "1 passage" : "\(sources.count) passages"
            let summaries = exchange.summaryCount
            sourcesTitle = summaries > 0
                ? "Found in \(passages) and \(summaries) chapter \(summaries == 1 ? "summary" : "summaries")"
                : "Found in \(passages)"
        }
    }

    /// The thread for a list of exchanges, in their order (`AskModel` keeps them oldest first).
    static func thread(_ exchanges: [AskModel.Exchange]) -> [Self] { exchanges.map(Self.init) }
}

extension AskModel {
    /// The conversation about this book as the pane shows it: the saved questions, then this
    /// opening's, oldest first.
    var thread: [AskThread.Turn] { AskThread.Turn.thread(exchanges) }
}

/// One turn of the thread: the question as a bubble on the trailing side, the answer under it.
private struct AskTurnView: View {
    let turn: AskThread.Turn
    var onGo: (ReadingLocation) -> Void
    @State private var showSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = turn.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            question
                .frame(maxWidth: .infinity, alignment: .trailing)
            answer
            if !turn.sources.isEmpty {
                DisclosureGroup(turn.sourcesTitle ?? "Passages", isExpanded: $showSources) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(turn.sources) { source in
                            Button {
                                onGo(source.location)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.chapter).font(.caption).foregroundStyle(.secondary)
                                    Text(source.snippet + "…").font(.footnote).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let passage = turn.passage {
                Text("“\(passage)”")
                    .italic()
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("About: \(passage)")
            }
            Text(turn.question)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
        .padding(.leading, 28)
    }

    @ViewBuilder
    private var answer: some View {
        switch turn.status {
        case .waiting(let note):
            if let note {
                Label(note, systemImage: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        case .answering where turn.answer.isEmpty:
            ProgressView()
        case .failed(let message):
            if !turn.answer.isEmpty { Text(turn.answer) }
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        default:
            Text(turn.answer)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}
