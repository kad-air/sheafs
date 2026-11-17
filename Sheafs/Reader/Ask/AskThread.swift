import SwiftUI

/// The running conversation in the Ask pane: every turn, oldest at the top, the newest at the bottom
/// (the pane scrolls there), each its quoted passage and question, then the answer and its passages.
/// It draws `AskTurn`s, the one turn type: `AskModel.turns` as whichever provider filled them (the
/// on-device model's saved history, or a plugin's own thread). Nothing in a turn is particular to
/// who answered.
struct AskThread: View {
    let turns: [AskTurn]
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

extension AskTurn {
    /// Where and when it was asked, for a turn from an earlier opening: "Chapter 22 · yesterday". A
    /// provider that counts how far was read in words, not chapters, says that instead ("6,206
    /// words in · yesterday"). Nil for this opening's turns.
    var caption: String? {
        guard restored else { return nil }
        let when = askedAt.formatted(.relative(presentation: .named))
        if chapter.isEmpty, let wordsRead { return "\(wordsRead.formatted()) words in · \(when)" }
        return chapter.isEmpty ? when : "\(chapter) · \(when)"
    }

    /// The passages listed under the answer: the ones it was scored against once it is in; until
    /// then they are lookups, and none show.
    var citedSources: [Source] { status == .done ? sources : [] }

    /// The heading the passages fold under ("Found in 3 passages and 1 chapter summary").
    var sourcesTitle: String {
        let passages = sources.count == 1 ? "1 passage" : "\(sources.count) passages"
        return summaryCount > 0
            ? "Found in \(passages) and \(summaryCount) chapter \(summaryCount == 1 ? "summary" : "summaries")"
            : "Found in \(passages)"
    }
}

/// One turn of the thread: the question as a bubble on the trailing side, the answer under it,
/// its markdown drawn (`AskAnswerText`).
private struct AskTurnView: View {
    let turn: AskTurn
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
            if !turn.citedSources.isEmpty {
                DisclosureGroup(turn.sourcesTitle, isExpanded: $showSources) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(turn.citedSources) { source in
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
            if let passage = turn.subject {
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
            if !turn.answer.isEmpty { AskAnswerText(markdown: turn.answer) }
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        default:
            AskAnswerText(markdown: turn.answer, streaming: turn.status == .answering)
        }
    }
}
