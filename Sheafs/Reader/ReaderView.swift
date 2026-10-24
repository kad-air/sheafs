import SwiftUI
import SwiftData
import SheafsKit
import UIKit
import os

/// Lets SwiftUI ask the pager controller to turn pages.
@Observable
final class PagerProxy {
    weak var controller: PagerController?
    func turn(forward: Bool) { controller?.turnPage(forward: forward) }
}

/// The full-screen reading experience for one book.
struct ReaderView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ReaderSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(SyncService.self) private var sync

    @State private var session: BookSession?
    @State private var chromeVisible = false
    @State private var showContents = false
    @State private var showAppearance = false
    @State private var layoutInput: PageLayout.Input?
    @State private var footnote: Footnote?
    @State private var remotePrompt: RemotePrompt?
    @State private var pagerProxy = PagerProxy()
    @State private var pushTask: Task<Void, Never>?
    @State private var sliderValue: Double = 0
    @State private var isScrubbing = false

    private let log = Logger(subsystem: "io.sheafs.reader", category: "reader")

    struct Footnote: Identifiable {
        let id = UUID()
        var text: String
        var location: ReadingLocation
    }

    struct RemotePrompt: Identifiable {
        let id = UUID()
        var device: String
        var percentage: Double
        var location: ReadingLocation
        var pointer: String
        var timestamp: Date?
    }

    private var palette: ReaderPalette { ReaderPalette.resolve(settings.theme, colorScheme: colorScheme) }
    private var style: TypesetStyle { settings.typesetStyle(colorScheme: colorScheme, language: book.language) }

    var body: some View {
        NavigationStack {
            surface
                .toolbar { toolbarContent }
                .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
                .toolbarVisibility(chromeVisible ? .visible : .hidden, for: .statusBar)
                // The page is the title; the bar carries only controls (the strip names the book and chapter).
                .toolbar(removing: .title)
                .navigationBarTitleDisplayMode(.inline)
                .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
                .safeAreaInset(edge: .bottom) {
                    if chromeVisible, let session, session.isReady, layoutInput?.division.map({ $0.width < $0.height }) ?? true {
                        progressStrip(session)
                    }
                }
        }
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .tint(Color(uiColor: palette.link))
        .sheet(isPresented: $showContents) {
            if let session {
                ContentsView(session: session) { location in
                    showContents = false
                    jump(to: location)
                }
            }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceView()
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $footnote) { note in
            FootnoteView(note: note) { location in
                footnote = nil
                jump(to: location)
            }
            .presentationDetents([.fraction(0.35), .medium])
        }
        .alert(item: $remotePrompt) { prompt in
            Alert(
                title: Text("Continue from \(prompt.device)?"),
                message: Text("That device is at \(prompt.percentage.formatted(.percent.precision(.fractionLength(0)))) of this book."),
                primaryButton: .default(Text("Continue")) { accept(prompt) },
                secondaryButton: .cancel(Text("Keep My Place"))
            )
        }
        .task { await open() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flush() }
        }
        .onChange(of: settings.keepScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            flush()
        }
    }

    // MARK: Surface

    @ViewBuilder
    private var surface: some View {
        ZStack {
            Color(uiColor: palette.background).ignoresSafeArea()
            if let session {
                switch session.state {
                case .ready:
                    pages(session)
                case .loading:
                    ProgressView("Opening…")
                        .tint(Color(uiColor: palette.secondary))
                case .failed(let message):
                    ContentUnavailableView("Can’t Open Book", systemImage: "book.closed", description: Text(message))
                }
            } else {
                ProgressView()
            }
        }
    }

    private func pages(_ session: BookSession) -> some View {
        // The proxy lives inside the safe area, so its size excludes the bars and its regions are
        // relative to that inset origin. The layout works in window coordinates: expand the size by
        // the insets and shift the regions by them.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let full = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                              height: proxy.size.height + insets.top + insets.bottom)
            let shift = CGPoint(x: insets.leading, y: insets.top)
            let division = proxy.reservedRegions(kind: .division, options: [.includeInactive]).first?
                .frame.offsetBy(dx: shift.x, dy: shift.y)
            let active = !proxy.reservedRegions(kind: .division).isEmpty
            let occlusions = proxy.reservedRegions(kind: .occlusion).map { $0.frame.offsetBy(dx: shift.x, dy: shift.y) }
            let fresh = PageLayout.Input(size: full, safeArea: insets, division: division,
                                         divisionIsActive: active, occlusions: occlusions,
                                         margin: settings.margin, fontSize: settings.fontSize, allowSpread: true)
            let layout = PageLayout.compute(effectiveInput(for: fresh))
            ZStack(alignment: .topLeading) {
                ReaderPager(session: session, layout: layout, style: style, palette: palette,
                            location: session.location, tapTurnsPages: settings.tapToTurn, proxy: pagerProxy,
                            onLocationChange: { location in
                                session.location = location
                                persist(location)
                                if chromeVisible { withAnimation { chromeVisible = false } }
                            },
                            onTap: handle(tap:))
                if let deck = layout.deckFrame {
                    ReaderDeck(session: session, palette: palette, proxy: pagerProxy,
                               showContents: $showContents, showAppearance: $showAppearance) { location in
                        jump(to: location)
                    }
                    .frame(width: deck.width, height: deck.height)
                    .offset(x: deck.minX, y: deck.minY)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: full.width, height: full.height, alignment: .topLeading)
            .offset(x: -shift.x, y: -shift.y)
            .onChange(of: fresh, initial: true) { _, new in
                // A fold, unfold or rotation while the bars are up: drop the bars so the stored
                // insets are the reading ones, not the bars'.
                if chromeVisible, let frozen = layoutInput, frozen.size != new.size {
                    chromeVisible = false
                }
                if !chromeVisible || layoutInput?.size != new.size { layoutInput = new }
            }
            .animation(.smooth, value: layout.deckFrame != nil)
        }
    }

    /// While the chrome is up, keep the chrome-hidden safe areas (so the bars overlay the page instead
    /// of repaginating it) but still follow the fold, the camera and the size.
    private func effectiveInput(for fresh: PageLayout.Input) -> PageLayout.Input {
        var used = fresh
        if chromeVisible, let frozen = layoutInput, frozen.size == fresh.size { used.safeArea = frozen.safeArea }
        return used
    }

    /// Titles from the OPF and the TOC often differ only in quotes or case.
    nonisolated static func sameTitle(_ a: String, _ b: String) -> Bool {
        func fold(_ s: String) -> String {
            s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "“", with: "\"")
                .replacingOccurrences(of: "”", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return fold(a) == fold(b)
    }

    private var currentChapterTitle: String {
        guard let session, session.isReady else { return "" }
        return session.chapterTitle(for: session.location.spineIndex) ?? ""
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Library", systemImage: "chevron.backward") {
                flush()
                dismiss()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Contents", systemImage: "list.bullet") { showContents = true }
        }
        .visibilityPriority(.high)
        ToolbarItem(placement: .primaryAction) {
            Button("Appearance", systemImage: "textformat.size") { showAppearance = true }
        }
        ToolbarOverflowMenu {
            Button("Sync Position Now", systemImage: "arrow.triangle.2.circlepath") {
                Task { await syncNow() }
            }
            .disabled(!sync.isConfigured)
            Button(book.isFinished ? "Mark as Unread" : "Mark as Finished",
                   systemImage: book.isFinished ? "circle" : "checkmark.circle") {
                book.finishedAt = book.isFinished ? nil : .now
                library.save()
            }
        }
    }

    private func progressStrip(_ session: BookSession) -> some View {
        VStack(spacing: 6) {
            Slider(value: Binding(
                get: { isScrubbing ? sliderValue : session.progress(for: session.location) },
                set: { sliderValue = $0 }
            ), in: 0 ... 1) { editing in
                isScrubbing = editing
                if !editing { jump(to: session.location(forProgress: sliderValue)) }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if !currentChapterTitle.isEmpty, !Self.sameTitle(currentChapterTitle, book.title) {
                        Text(currentChapterTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(progressLabel(session))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func progressLabel(_ session: BookSession) -> String {
        let fraction = isScrubbing ? sliderValue : session.progress(for: session.location)
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Actions

    private func handle(tap: ReaderTap) {
        switch tap {
        case .center:
            withAnimation(.snappy) { chromeVisible.toggle() }
        case .previous, .next:
            break // the pager turns the page itself
        case .link(let href, let spine):
            open(link: href, from: spine)
        }
    }

    private func open(link href: String, from spine: Int) {
        guard let session else { return }
        if href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:") {
            if let url = URL(string: href) { openURL(url) }
            return
        }
        guard let target = session.location(forHref: href, fromSpine: spine) else { return }
        let fragment = EPUBPath.split(href).fragment?.lowercased() ?? ""
        let looksLikeNote = ["note", "fn", "foot", "ref", "annot"].contains { fragment.contains($0) }
        if looksLikeNote, let block = session.chapters[target.spineIndex].block(containing: target.textOffset),
           block.textLength < 900 {
            footnote = Footnote(text: block.text, location: target)
        } else {
            jump(to: target)
        }
    }

    private func jump(to location: ReadingLocation) {
        guard let session else { return }
        session.location = session.clamp(location)
        persist(session.location)
    }

    private func persist(_ location: ReadingLocation) {
        guard let session, session.isReady else { return }
        book.spineIndex = location.spineIndex
        book.textOffset = location.textOffset
        book.progress = session.progress(for: location)
        book.xpointer = session.xpointer(for: location)?.serialized
        book.lastOpenedAt = .now
        if book.progress >= 0.985, book.finishedAt == nil { book.finishedAt = .now }
        library.save()
        schedulePush()
    }

    private func schedulePush() {
        pushTask?.cancel()
        let book = book
        pushTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await sync.push(for: book)
        }
    }

    /// Saves and pushes right away (leaving the reader, going to the background).
    private func flush() {
        pushTask?.cancel()
        pushTask = nil
        library.save()
        let book = book
        Task { await sync.push(for: book) }
    }

    private func syncNow() async {
        guard let session else { return }
        await sync.push(for: book)
        if let remote = await sync.pull(for: book) { offer(remote, session: session, force: true) }
    }

    // MARK: Opening and sync

    private func open() async {
        guard session == nil else { return }
        let fresh = BookSession(book: book, fileURL: library.fileURL(for: book))
        session = fresh
        await fresh.load()
        guard fresh.isReady else { return }
        book.lastOpenedAt = .now
        library.save()
        if let remote = await sync.pull(for: book) {
            offer(remote, session: fresh, force: false)
        }
    }

    /// Decides what to do with the server's position: apply it quietly when this device hasn't
    /// moved since the last sync, otherwise ask.
    private func offer(_ remote: KOSyncProgress, session: BookSession, force: Bool) {
        guard remote.progress != book.lastSyncedPointer || force else { return }
        let target: ReadingLocation
        if let pointer = XPointer(parsing: remote.progress), let resolved = session.location(for: pointer) {
            target = resolved
        } else {
            target = session.location(forProgress: remote.percentage)
        }
        let here = session.progress(for: session.location)
        let there = session.progress(for: target)
        guard abs(here - there) > 0.002 || target.spineIndex != session.location.spineIndex else {
            book.lastSyncedPointer = remote.progress
            book.lastSyncedAt = remote.timestamp
            library.save()
            return
        }
        let localMoved = book.xpointer != nil && book.xpointer != book.lastSyncedPointer && book.lastSyncedPointer != nil
        let prompt = RemotePrompt(device: remote.device ?? "another device", percentage: there, location: target,
                                  pointer: remote.progress, timestamp: remote.timestamp)
        if localMoved || force {
            remotePrompt = prompt
        } else {
            accept(prompt)
        }
    }

    private func accept(_ prompt: RemotePrompt) {
        jump(to: prompt.location)
        book.lastSyncedPointer = prompt.pointer
        book.lastSyncedAt = prompt.timestamp
        library.save()
        pushTask?.cancel()
    }
}

// MARK: - Contents

struct ContentsView: View {
    let session: BookSession
    var onSelect: (ReadingLocation) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if session.flatTOC.isEmpty {
                    List(0 ..< session.chapterCount, id: \.self) { index in
                        Button {
                            onSelect(ReadingLocation(spineIndex: index, textOffset: 0))
                        } label: {
                            row(title: session.chapters[index].title ?? "Section \(index + 1)",
                                depth: 0, current: index == session.location.spineIndex)
                        }
                    }
                } else {
                    List(session.flatTOC) { entry in
                        Button {
                            if let location = session.location(for: entry) { onSelect(location) }
                        } label: {
                            row(title: entry.title, depth: entry.depth, current: isCurrent(entry))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(title: String, depth: Int, current: Bool) -> some View {
        HStack {
            Text(title)
                .fontWeight(current ? .semibold : .regular)
                .foregroundStyle(current ? .primary : .primary)
                .padding(.leading, CGFloat(depth) * 18)
            Spacer()
            if current {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.small)
            }
        }
        .contentShape(Rectangle())
    }

    private func isCurrent(_ entry: TOCEntry) -> Bool {
        guard let path = entry.path, let epub = session.epub, let index = epub.spineIndex(forPath: path) else { return false }
        guard index == session.location.spineIndex else { return false }
        // Among entries for this chapter, the last one at or before the current offset is current.
        let siblings = session.flatTOC.filter { $0.path == path }
        let offset = session.location.textOffset
        let chapter = session.chapters[index]
        let candidates = siblings.filter { ($0.fragment.flatMap { chapter.anchorOffsets[$0] } ?? 0) <= offset }
        return candidates.last?.id == entry.id
    }
}

// MARK: - Footnote

struct FootnoteView: View {
    let note: ReaderView.Footnote
    var onGo: (ReadingLocation) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(note.text)
                    .font(.system(.body, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Go to Note") { onGo(note.location) } }
            }
        }
    }
}

// MARK: - Deck (tabletop pose)

/// Controls shown below an active horizontal fold, where the page lives on the upper half.
struct ReaderDeck: View {
    let session: BookSession
    let palette: ReaderPalette
    let proxy: PagerProxy
    @Binding var showContents: Bool
    @Binding var showAppearance: Bool
    var onJump: (ReadingLocation) -> Void
    @Environment(ReaderSettings.self) private var settings
    @State private var value = 0.0
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(session.chapterTitle(for: session.location.spineIndex) ?? session.book.title)
                    .font(.headline)
                    .lineLimit(1)
                Text((scrubbing ? value : session.progress(for: session.location))
                    .formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { scrubbing ? value : session.progress(for: session.location) },
                                  set: { value = $0 }), in: 0 ... 1) { editing in
                scrubbing = editing
                if !editing { onJump(session.location(forProgress: value)) }
            }
            .frame(maxWidth: 480)
            HStack(spacing: 28) {
                Button("Previous Page", systemImage: "chevron.backward") { proxy.turn(forward: false) }
                    .font(.title)
                Button("Contents", systemImage: "list.bullet") { showContents = true }
                Button("Smaller Text", systemImage: "textformat.size.smaller") { settings.fontSize = max(12, settings.fontSize - 1) }
                Button("Larger Text", systemImage: "textformat.size.larger") { settings.fontSize = min(32, settings.fontSize + 1) }
                Button("Appearance", systemImage: "paintpalette") { showAppearance = true }
                Button("Next Page", systemImage: "chevron.forward") { proxy.turn(forward: true) }
                    .font(.title)
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: palette.background))
    }
}
