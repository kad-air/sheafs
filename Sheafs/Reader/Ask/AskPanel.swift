import SwiftUI

/// The Ask panel: floats over the bottom of the page like the quick appearance panel, so the
/// reader stays in the book; beside the book on the Duo's inner display (`AskPresentation`), it runs
/// the window's full height on the left of the fold (`fillsHeight`). It shows the running
/// conversation about this book (`AskThread`, from `AskModel.turns`): the saved questions and this
/// opening's, oldest first, scrolled to the newest. Tapping an answer's passage turns to its page
/// with the panel still up, and "Back to page N" returns.
struct AskPanel: View {
    @Bindable var model: AskModel
    /// The tallest the conversation may grow before it scrolls (floating only).
    var maxHeight: CGFloat
    /// Beside the book: the panel fills the height it is given and the conversation the rest of it.
    var fillsHeight = false
    /// "Back to page N" after a passage was opened (the panel may cover the page's own button).
    var backLabel: String?
    var onBack: () -> Void
    var onGo: (ReadingLocation) -> Void
    var onClose: () -> Void
    @State private var confirmClear = false
    @State private var contentHeight: CGFloat = 0
    /// The attached passage's quote: the answer area gives up that much height to it.
    @State private var subjectHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// What the panel adds around the answer: the header and input bar rows (40 each), the
    /// spacing between the three rows, the padding inside the glass and the gap under it.
    static let chromeHeight: CGFloat = 40 + 40 + 2 * 10 + 2 * 12 + 6

    private static let suggestions = [
        "What has happened so far?",
        "What happened in the last chapter?",
        "Who are the main characters so far?",
    ]

    /// The bottom of the conversation, scrolled to as turns arrive and answers grow.
    private static let end = "end"

    var body: some View {
        let turns = model.turns
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !turns.isEmpty {
                            AskThread(turns: turns, onGo: onGo)
                        }
                        if !model.availability.isAvailable {
                            Label(model.availability.message, systemImage: "apple.intelligence")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if turns.isEmpty {
                            intro
                        }
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom)
                .onAppear { reader.scrollTo(Self.end, anchor: .bottom) }
                .onChange(of: turns.last.map { [$0.id.uuidString, $0.answer, "\($0.status)"] }) {
                    reader.scrollTo(Self.end, anchor: .bottom)
                }
                .onChange(of: fillsHeight) { DispatchQueue.main.async { reader.scrollTo(Self.end, anchor: .bottom) } }
            }
            .frame(height: fillsHeight ? nil : min(contentHeight, max(60, maxHeight - (model.subject == nil ? 0 : subjectHeight))))
            .frame(maxHeight: fillsHeight ? .infinity : nil)
            if let subject = model.subject {
                subjectQuote(subject.text)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height + 10 } action: { subjectHeight = $0 }
            }
            // The provider's word on the next answer (`AskProvider.notice`).
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            inputBar
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: 460, maxHeight: fillsHeight ? .infinity : nil, alignment: .bottom)
        .glassEffect(in: .rect(cornerRadius: 26))
        .padding(.horizontal, 10)
        .padding(.top, fillsHeight ? 10 : 0)
        .padding(.bottom, 6)
        .onAppear { model.refreshAvailability() }
        // `[ask] thread: …` for scripts (`scripts/check-ask-duo`): how many turns the pane holds, in order.
        .onChange(of: turns.map(\.id), initial: true) {
            print("[ask] thread: \(turns.count) turns, oldest first: \(turns.map(\.question).joined(separator: " | "))")
        }
        .confirmationDialog("Delete all questions about this book?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete Questions", role: .destructive) { model.clear() }
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
            Button("Delete All Questions", systemImage: "trash") { confirmClear = true }
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 40)
                .background(.fill.tertiary, in: Circle())
                .disabled(model.turns.isEmpty || model.isBusy)
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 40)
                .background(.fill.tertiary, in: Circle())
        }
    }

    /// The passage picked in the book (the selection menu's Ask), going with the next question; ✕
    /// lets it go and the question is about the book again.
    private func subjectQuote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .italic()
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Asking about: \(text)")
            Button("Remove Passage", systemImage: "xmark.circle.fill") { model.detachSubject() }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Questions about the whole book; not while a passage is attached (it would go with them).
            if model.subject == nil {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { model.ask(suggestion) }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.fill.tertiary, in: Capsule())
                        .disabled(model.isBusy)
                }
            }
            Text(model.about ?? "Answers come from Apple’s on-device model and use only the text up to the end of this page, so they can’t give away what happens next. Nothing leaves your device. \(recapLine)")
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

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(model.subject == nil ? "Ask about the story so far" : "Ask about this passage",
                      text: $model.draft, axis: .vertical)
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
                Text("Adds an Ask button to the reader, and Ask to the menu for selected text, to ask about a passage. Questions about plot and characters are answered by Apple’s on-device model from the text up to your page only, so answers can’t spoil what comes next. While a book is open, Ask also summarises the chapters you’ve finished, in the background, to answer from. Nothing leaves your device.")
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
