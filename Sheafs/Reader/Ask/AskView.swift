import SwiftUI

/// The Ask sheet: questions and answers about the story so far, each answer with the passages it
/// was found in (tap one to go there, which closes the sheet and leaves a "Back to page N" stop).
struct AskView: View {
    @Bindable var model: AskModel
    var onGo: (ReadingLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private static let suggestions = [
        "What has happened so far?",
        "What happened in the last chapter?",
        "Who are the main characters so far?",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !model.availability.isAvailable {
                        ContentUnavailableView("Ask Isn’t Available", systemImage: "apple.intelligence",
                                               description: Text(model.availability.message))
                    } else if model.exchanges.isEmpty {
                        intro
                    }
                    ForEach(model.exchanges) { exchange in
                        ExchangeView(exchange: exchange, onGo: onGo)
                            .id(exchange.id)
                    }
                }
                .listStyle(.insetGrouped)
                .onChange(of: model.exchanges.last?.answer) { _, _ in
                    if let last = model.exchanges.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Ask About the Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !model.exchanges.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear", systemImage: "trash") { model.clear() }
                            .disabled(model.isBusy)
                    }
                }
            }
        }
        .onAppear { model.refreshAvailability() }
    }

    private var intro: some View {
        Section {
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button(suggestion) { model.ask(suggestion) }
            }
        } header: {
            Text("Try asking")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Answers come from Apple’s on-device model and use only the text up to the end of this page, so they can’t give away what happens next. Nothing leaves your device.")
                Text(recapLine)
            }
        }
    }

    private var recapLine: String {
        let progress = model.recaps.progress
        guard progress.total > 0 else { return "Ask also writes short summaries of the chapters you’ve finished, in the background." }
        if progress.done == progress.total { return "Summaries of all \(progress.total) finished chapters are ready." }
        return "Summaries of finished chapters: \(progress.done) of \(progress.total) ready. The rest are being written while you read."
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about the story so far", text: $model.draft, axis: .vertical)
                .lineLimit(1 ... 4)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { model.ask() }
                .disabled(!model.availability.isAvailable)
            if model.isBusy {
                Button("Stop", systemImage: "stop.circle.fill") { model.cancel() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
            } else {
                Button("Ask", systemImage: "arrow.up.circle.fill") { model.ask() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.availability.isAvailable)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct ExchangeView: View {
    let exchange: AskModel.Exchange
    var onGo: (ReadingLocation) -> Void

    var body: some View {
        Section {
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
                    .textSelection(.enabled)
            }
            if exchange.state == .done, !exchange.sources.isEmpty {
                DisclosureGroup(sourcesTitle) {
                    ForEach(exchange.sources) { source in
                        Button {
                            onGo(source.location)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.chapter).font(.caption).foregroundStyle(.secondary)
                                Text(source.snippet + "…").font(.footnote).lineLimit(3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.footnote)
            }
        } header: {
            Text(exchange.question)
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    private var sourcesTitle: String {
        let passages = exchange.sources.count == 1 ? "1 passage" : "\(exchange.sources.count) passages"
        guard exchange.summaryCount > 0 else { return "Found in \(passages)" }
        return "Found in \(passages) and \(exchange.summaryCount) chapter \(exchange.summaryCount == 1 ? "summary" : "summaries")"
    }
}

/// Settings → Ask About the Book: the switch, whether the device can run it, and the stored summaries.
struct AskSettingsView: View {
    @Environment(ReaderSettings.self) private var settings
    @State private var availability = AskEngine.availability
    @State private var storedBooks = RecapStore.storedBookCount
    @State private var confirmDelete = false

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
        }
        .confirmationDialog("Delete all chapter summaries?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Summaries", role: .destructive) {
                RecapStore.deleteAll()
                storedBooks = 0
            }
        }
    }
}
