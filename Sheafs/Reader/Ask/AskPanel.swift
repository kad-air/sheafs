import SwiftUI

/// The Ask panel: floats over the bottom of the page like the quick appearance panel, so the
/// reader stays in the book. It shows one answer at a time (the newest, or one picked from the
/// history) with the passages it was found in; tapping a passage turns to its page with the panel
/// still up, and "Back to page N" returns. The history lists every saved question for this book.
struct AskPanel: View {
    @Bindable var model: AskModel
    /// The tallest the answer or the history may grow before it scrolls.
    var maxHeight: CGFloat
    /// "Back to page N" after a passage was opened (the panel may cover the page's own button).
    var backLabel: String?
    var onBack: () -> Void
    var onGo: (ReadingLocation) -> Void
    var onClose: () -> Void
    /// The answer being read: nil is the newest.
    @State private var shown: UUID?
    @State private var showHistory = false
    @State private var confirmClear = false
    @State private var contentHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    private static let suggestions = [
        "What has happened so far?",
        "What happened in the last chapter?",
        "Who are the main characters so far?",
    ]

    private var exchange: AskModel.Exchange? {
        if let shown, let picked = model.exchanges.first(where: { $0.id == shown }) { return picked }
        return model.exchanges.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                Group {
                    if !model.availability.isAvailable {
                        Label(model.availability.message, systemImage: "apple.intelligence")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if showHistory {
                        historyList
                    } else if let exchange {
                        ExchangeCard(exchange: exchange, onGo: onGo)
                            .id(exchange.id)
                    } else {
                        intro
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxHeight))
            inputBar
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: 460)
        .glassEffect(in: .rect(cornerRadius: 26))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onAppear { model.refreshAvailability() }
        .onChange(of: model.exchanges.count) { old, new in
            // A new question shows its answer; the history closes for it.
            if new > old {
                shown = nil
                showHistory = false
            }
        }
        .confirmationDialog("Delete all questions about this book?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete Questions", role: .destructive) {
                model.clear()
                shown = nil
                showHistory = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let backLabel {
                Button(backLabel, systemImage: "arrow.uturn.backward", action: onBack)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .background(.fill.tertiary, in: Capsule())
            } else {
                Label("Ask About the Book", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(showHistory ? "Hide Earlier Questions" : "Earlier Questions",
                   systemImage: showHistory ? "clock.fill" : "clock.arrow.circlepath") {
                withAnimation(.snappy) { showHistory.toggle() }
            }
            .labelStyle(.iconOnly)
            .frame(width: 40, height: 40)
            .background(.fill.tertiary, in: Circle())
            .disabled(model.exchanges.isEmpty)
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 40)
                .background(.fill.tertiary, in: Circle())
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button(suggestion) { model.ask(suggestion) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: Capsule())
                    .disabled(model.isBusy)
            }
            Text("Answers come from Apple’s on-device model and use only the text up to the end of this page, so they can’t give away what happens next. Nothing leaves your device. \(recapLine)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recapLine: String {
        let progress = model.recaps.progress
        guard progress.total > 0 else { return "Ask also writes short summaries of the chapters you’ve finished, in the background." }
        if progress.done == progress.total { return "Summaries of all \(progress.total) finished chapters are ready." }
        return "Summaries of finished chapters: \(progress.done) of \(progress.total) ready."
    }

    /// Every question about this book, newest first; tap one to read its answer again.
    private var historyList: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(model.exchanges.reversed()) { exchange in
                Button {
                    shown = exchange.id
                    withAnimation(.snappy) { showHistory = false }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exchange.question)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(exchange.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            Button("Delete All Questions", role: .destructive) { confirmClear = true }
                .font(.footnote)
                .padding(.top, 4)
                .disabled(model.isBusy)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about the story so far", text: $model.draft, axis: .vertical)
                .lineLimit(1 ... 3)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { model.ask() }
                .disabled(!model.availability.isAvailable)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.fill.tertiary, in: .rect(cornerRadius: 20))
            if model.isBusy {
                Button("Stop", systemImage: "stop.fill") { model.cancel() }
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: Circle())
            } else {
                Button("Ask", systemImage: "arrow.up") { model.ask() }
                    .labelStyle(.iconOnly)
                    .fontWeight(.semibold)
                    .frame(width: 40, height: 40)
                    .background(.fill.tertiary, in: Circle())
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.availability.isAvailable)
            }
        }
    }
}

extension AskModel.Exchange {
    /// Where and when it was asked: "Chapter 22 · yesterday".
    var caption: String {
        let when = askedAt.formatted(.relative(presentation: .named))
        return chapter.isEmpty ? when : "\(chapter) · \(when)"
    }
}

/// One question, its answer as it streams, and the passages it was found in.
private struct ExchangeCard: View {
    let exchange: AskModel.Exchange
    var onGo: (ReadingLocation) -> Void
    @State private var showSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exchange.question)
                    .font(.headline)
                if exchange.restored {
                    Text(exchange.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            switch exchange.state {
            case .lookingUp:
                Label("Looking through what you’ve read…", systemImage: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
            case .answering where exchange.answer.isEmpty:
                ProgressView()
            case .failed(let message):
                if !exchange.answer.isEmpty { Text(exchange.answer) }
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            default:
                Text(exchange.answer)
                    .font(.body)
                    .textSelection(.enabled)
            }
            if exchange.state == .done, !exchange.sources.isEmpty {
                DisclosureGroup(sourcesTitle, isExpanded: $showSources) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(exchange.sources) { source in
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

    private var sourcesTitle: String {
        let passages = exchange.sources.count == 1 ? "1 passage" : "\(exchange.sources.count) passages"
        guard exchange.summaryCount > 0 else { return "Found in \(passages)" }
        return "Found in \(passages) and \(exchange.summaryCount) chapter \(exchange.summaryCount == 1 ? "summary" : "summaries")"
    }
}

/// Settings → Ask About the Book: the switch, whether the device can run it, and what is stored
/// (the saved questions and the chapter summaries).
struct AskSettingsView: View {
    @Environment(ReaderSettings.self) private var settings
    @State private var availability = AskEngine.availability
    @State private var storedBooks = RecapStore.storedBookCount
    @State private var askedBooks = AskHistoryStore.storedBookCount
    @State private var confirmDelete = false
    @State private var confirmDeleteQuestions = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Ask About the Book", isOn: $settings.askEnabled)
            } footer: {
                Text("Adds an Ask button to the reader. Questions about plot and characters are answered by Apple’s on-device model from the text up to your page only, so answers can’t spoil what comes next. While a book is open, Ask also summarises the chapters you’ve finished, in the background, to answer from. Nothing leaves your device.")
            }
            Section("Apple Intelligence") {
                Label(availability.message, systemImage: availability.isAvailable ? "checkmark.circle" : "exclamationmark.circle")
            }
            Section {
                Button("Delete Questions and Answers", role: .destructive) { confirmDeleteQuestions = true }
                    .disabled(askedBooks == 0)
            } footer: {
                Text(askedBooks == 0 ? "No questions saved."
                     : "Questions and answers are saved for \(askedBooks) \(askedBooks == 1 ? "book" : "books"), to read again from the Ask panel.")
            }
            Section {
                Button("Delete Chapter Summaries", role: .destructive) { confirmDelete = true }
                    .disabled(storedBooks == 0)
            } footer: {
                Text(storedBooks == 0 ? "No summaries stored."
                     : "Summaries are stored for \(storedBooks) \(storedBooks == 1 ? "book" : "books"). They’re written again as you read.")
            }
        }
        .navigationTitle("Ask About the Book")
        .onAppear {
            availability = AskEngine.availability
            storedBooks = RecapStore.storedBookCount
            askedBooks = AskHistoryStore.storedBookCount
        }
        .confirmationDialog("Delete all chapter summaries?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Summaries", role: .destructive) {
                RecapStore.deleteAll()
                storedBooks = 0
            }
        }
        .confirmationDialog("Delete all saved questions and answers?", isPresented: $confirmDeleteQuestions, titleVisibility: .visible) {
            Button("Delete Questions", role: .destructive) {
                AskHistoryStore.deleteAll()
                askedBooks = 0
            }
        }
    }
}
