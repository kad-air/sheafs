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
    var hostView: UIView? { controller?.viewIfLoaded }
}

/// The full-screen reading experience for one book.
struct ReaderView: View {
    let book: Book
    @Query private var annotations: [Annotation]

    init(book: Book) {
        self.book = book
        let id = book.id
        _annotations = Query(filter: #Predicate<Annotation> { $0.bookID == id },
                             sort: [SortDescriptor(\Annotation.spineIndex), SortDescriptor(\Annotation.startOffset)])
    }

    @Environment(\.dismiss) private var dismiss
    /// The device's Light/Dark setting, from the window scene (`SystemColorSchemeReader`).
    @State private var systemScheme: ColorScheme?
    @Environment(\.colorScheme) private var environmentScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ReaderSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(SyncService.self) private var sync

    @State private var session: BookSession?
    @State private var chromeVisible = false
    @State private var showContents = false
    @State private var showAppearance = false
    /// The small panel over the bottom of the page; `showAppearance` is the detailed sheet behind it.
    @State private var showQuickAppearance = false
    @State private var geometry = SteadyPageGeometry()
    @State private var regions: WindowRegions?
    @State private var orientation: UIInterfaceOrientation = .unknown
    @State private var footnote: Footnote?
    @State private var editingAnnotation: Annotation?
    @State private var remotePrompt: RemotePrompt?
    @State private var pagerProxy = PagerProxy()
    @State private var volumeButtons = VolumeButtonPager()
    @State private var pushTask: Task<Void, Never>?
    @State private var sliderValue: Double = 0
    @State private var isScrubbing = false
    @State private var trail = ReturnTrail()
    @State private var showSearch = false
    /// Find-in-book, made the first time the search opens; kept so reopening shows the last results.
    @State private var search: BookSearchModel?
    /// The contents sheet's Search button: the search opens once that sheet is gone.
    @State private var searchAfterContents = false
    /// The searched query's hits in the chapter jumped to, painted until the next turn or tap.
    @State private var foundMarks: [HighlightMark] = []

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

    /// The device's Light/Dark setting; the environment's only until the window scene has answered.
    private var deviceScheme: ColorScheme { systemScheme ?? environmentScheme }
    /// The scheme the reader runs in (`ReaderPalette.colorScheme`).
    private var colorScheme: ColorScheme { palette.colorScheme }
    private var palette: ReaderPalette { settings.palette(system: deviceScheme) }
    private var style: TypesetStyle { settings.typesetStyle(system: deviceScheme, language: book.language) }

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
                    if chromeVisible, let session, session.isReady, geometry.reading?.division.map({ $0.width < $0.height }) ?? true {
                        progressStrip(session)
                    }
                }
        }
        .overlay(alignment: .bottomLeading) {
            if showQuickAppearance {
                QuickAppearanceView(onMore: {
                    withAnimation(.snappy) { showQuickAppearance = false }
                    showAppearance = true
                }, onClose: {
                    withAnimation(.snappy) { showQuickAppearance = false }
                })
                .frame(maxWidth: quickPanelWidth ?? .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(colorScheme)
        .background { SystemColorSchemeReader { systemScheme = $0 } }
        .tint(Color(uiColor: palette.link))
        .sheet(isPresented: $showContents, onDismiss: {
            if searchAfterContents {
                searchAfterContents = false
                openSearch()
            }
        }) {
            if let session {
                ContentsView(session: session, book: book, annotations: annotations, onSelect: { location in
                    showContents = false
                    jump(to: location)
                }, onSearch: {
                    searchAfterContents = true
                    showContents = false
                })
            }
        }
        .sheet(isPresented: $showSearch) {
            if let search {
                BookSearchView(model: search) { hit in
                    showSearch = false
                    jump(to: hit)
                }
            }
        }
        .sheet(item: $editingAnnotation) { annotation in
            if let session {
                AnnotationEditorView(annotation: annotation, session: session) { location in
                    editingAnnotation = nil
                    jump(to: location)
                }
                .presentationDetents([.medium, .large])
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
        .onChange(of: volumeButtonsArmed, initial: true) { _, armed in
            armVolumeButtons(armed)
        }
        .onDisappear {
            volumeButtons.stop()
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
        .modifier(GeometryProbe(label: "reader"))
    }

    private func pages(_ session: BookSession) -> some View {
        // The proxy lives inside the safe area, so its size excludes the bars; the layout works in
        // window coordinates (the size plus the insets). The fold comes from the full-window reader
        // in the background (`WindowRegions`); the cover camera is a known spot (`CoverCamera`).
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let full = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                              height: proxy.size.height + insets.top + insets.bottom)
            let shift = CGPoint(x: insets.leading, y: insets.top)
            if let regions {
                // Both displays read full width under the bars' strip; the bars overlay on tap.
                let fresh = PageLayout.Input(size: full, safeArea: insets, division: regions.division,
                                             divisionIsActive: regions.divisionIsActive,
                                             camera: CoverCamera.hole(window: full, hasFold: regions.division != nil,
                                                                      orientation: orientation),
                                             margin: settings.margin, fontSize: settings.fontSize, allowSpread: true,
                                             fullBleed: true)
                let layout = PageLayout.compute(geometry.input(for: fresh))
                ZStack(alignment: .topLeading) {
                    ReaderPager(session: session, layout: layout, style: style, palette: palette,
                                location: session.location, tapTurnsPages: settings.tapToTurn,
                                marks: annotations.map(\.mark) + foundMarks, highlightColor: settings.highlightColor, pageTurn: settings.pageTurn, proxy: pagerProxy,
                                onLocationChange: { location in
                                    if volumeButtons.isRunning {
                                        VolumeLog.shared.note("landed at spine=\(location.spineIndex) offset=\(location.textOffset)")
                                    }
                                    session.location = location
                                    if !foundMarks.isEmpty { foundMarks = [] }
                                    trail.arrived(at: location, samePage: samePage)
                                    persist(location)
                                    if chromeVisible { withAnimation { chromeVisible = false } }
                                },
                                onTap: handle(tap:),
                                onSelectionAction: handle(selection:))
                    if let deck = layout.deckFrame {
                        ReaderDeck(session: session, palette: palette, proxy: pagerProxy,
                                   showContents: $showContents, showAppearance: $showQuickAppearance,
                                   onSearch: openSearch) { location in
                            jump(to: location)
                        }
                        .frame(width: deck.width, height: deck.height)
                        .offset(x: deck.minX, y: deck.minY)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if !chromeVisible, !showQuickAppearance, let page = layout.pageFrames.last {
                        backButton(session)
                            // Over the folio of the page that holds the position (the right page of a spread).
                            .position(x: page.midX, y: page.maxY - PageLayout.footerHeight / 2 + 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.snappy, value: trail)
                .frame(width: full.width, height: full.height, alignment: .topLeading)
                .offset(x: -shift.x, y: -shift.y)
                .onChange(of: fresh, initial: true) { _, new in
                    // A fold, unfold or rotation while the bars are up: drop the bars so the stored
                    // insets are the reading ones, not the bars'.
                    if chromeVisible, let frozen = geometry.reading, frozen.size != new.size {
                        chromeVisible = false
                    }
                    geometry.observe(new, barsVisible: chromeVisible, now: ProcessInfo.processInfo.systemUptime)
                    let used = PageLayout.compute(geometry.input(for: new))
                    print("[layout] size=\(new.size) safe=\(new.safeArea) division=\(String(describing: new.division)) " +
                          "active=\(new.divisionIsActive) camera=\(String(describing: new.camera)) orientation=\(orientation.rawValue) → pages=\(used.pageFrames) " +
                          "textInsets=\(used.textInsets) " +
                          "holding=\(geometry.isHolding(new))")
                }
                .animation(.smooth, value: layout.deckFrame != nil)
            }
        }
        .background {
            GeometryReader { window in
                let fresh = WindowRegions(proxy: window)
                Color.clear.onChange(of: fresh, initial: true) { _, new in regions = new }
                InterfaceOrientationReader { orientation = $0 }
            }
            .ignoresSafeArea()
        }
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
            Button("Search", systemImage: "magnifyingglass") { openSearch() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Appearance", systemImage: "textformat.size") { openQuickAppearance() }
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
            if !trail.isEmpty {
                backButton(session)
            }
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

    /// "136 of 594 · 18 pages left in chapter", like Books; a percentage while scrubbing.
    private func progressLabel(_ session: BookSession) -> String {
        if isScrubbing { return sliderValue.formatted(.percent.precision(.fractionLength(0))) }
        let location = session.location
        guard let chapter = session.paginatedChapter(location.spineIndex) else {
            return session.progress(for: location).formatted(.percent.precision(.fractionLength(0)))
        }
        let page = chapter.pageIndex(containing: location.textOffset)
        let (number, total) = session.bookPages(spineIndex: location.spineIndex, page: page)
        let left = max(0, chapter.pageCount - page - 1)
        let leftText = left == 1 ? "1 page left in chapter" : "\(left) pages left in chapter"
        return "\(number) of \(total) · \(leftText)"
    }

    // MARK: Actions

    /// The volume buttons turn pages only while the book is on screen and the app is active; with a
    /// sheet up (contents, appearance, a note, a footnote) they change the volume again. Leaving
    /// the foreground stops them, so Control Center's volume works and they re-arm on return.
    private var volumeButtonsArmed: Bool {
        (settings.volumeButtonsTurn || volumeProbeRequested) && scenePhase == .active && session?.isReady == true && regions != nil
            && !showContents && !showAppearance && !showSearch && footnote == nil && editingAnnotation == nil
    }

    /// `-SheafsVolumeProbe` (a debug launch argument) arms the buttons whatever the setting says.
    private var volumeProbeRequested: Bool {
        UserDefaults.standard.string(forKey: "SheafsVolumeProbe") != nil
    }

    private func armVolumeButtons(_ armed: Bool) {
        VolumeLog.shared.note("armed=\(armed): setting=\(settings.volumeButtonsTurn) scene=\(scenePhase) "
            + "ready=\(session?.isReady == true) regions=\(regions != nil) contents=\(showContents) "
            + "appearance=\(showAppearance) search=\(showSearch) footnote=\(footnote != nil) note=\(editingAnnotation != nil)")
        guard armed else {
            volumeButtons.stop()
            return
        }
        armVolumeButtonsWhenPagerIsUp(tries: 30)
    }

    /// The pager appears some time after the session is ready (it waits for the window's regions),
    /// so keep looking for it for a few seconds; giving up on the first pass left the buttons dead.
    private func armVolumeButtonsWhenPagerIsUp(tries: Int) {
        guard volumeButtonsArmed, !volumeButtons.isRunning else { return }
        if let host = pagerProxy.hostView, host.window != nil {
            VolumeLog.shared.note("pager found after \(30 - tries) retries")
            volumeButtons.start(host: host) { press in
                let hasPager = pagerProxy.controller != nil
                let at = pagerProxy.controller?.displayedLocation
                VolumeLog.shared.note("turn \(press.turnsForward ? "forward" : "back") pager=\(hasPager) from spine=\(at?.spineIndex ?? -1) offset=\(at?.textOffset ?? -1)")
                pagerProxy.turn(forward: press.turnsForward)
            }
            return
        }
        guard tries > 0 else {
            VolumeLog.shared.note("not armed: no pager in a window (host=\(pagerProxy.hostView != nil))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            armVolumeButtonsWhenPagerIsUp(tries: tries - 1)
        }
    }

    private func handle(tap: ReaderTap) {
        if !foundMarks.isEmpty { foundMarks = [] }
        switch tap {
        case .center:
            if showQuickAppearance {
                withAnimation(.snappy) { showQuickAppearance = false }
            } else {
                withAnimation(.snappy) { chromeVisible.toggle() }
            }
        case .previous, .next:
            break // the pager turns the page itself
        case .link(let href, let spine):
            open(link: href, from: spine)
        case .annotation(let id):
            editingAnnotation = annotations.first { $0.id == id }
        }
    }

    /// Makes a highlight from the selection; a note opens the editor right away.
    private func handle(selection action: SelectionAction) {
        switch action {
        case .highlight(let selection, let text, let color):
            _ = add(selection, text: text, color: color)
        case .note(let selection, let text, let color):
            editingAnnotation = add(selection, text: text, color: color)
        }
    }

    private func add(_ selection: TextSelection, text: String, color: HighlightColor) -> Annotation {
        let start = ReadingLocation(spineIndex: selection.spineIndex, textOffset: selection.range.location)
        let end = ReadingLocation(spineIndex: selection.spineIndex, textOffset: NSMaxRange(selection.range))
        let annotation = Annotation(bookID: book.id, spineIndex: selection.spineIndex,
                                    startOffset: start.textOffset, endOffset: end.textOffset,
                                    startPointer: session?.xpointer(for: start)?.serialized,
                                    endPointer: session?.xpointer(for: end)?.serialized,
                                    text: text, color: color)
        settings.highlightColor = color
        library.add(annotation)
        log.info("highlight \(selection.spineIndex):\(selection.range.location)+\(selection.range.length) \(color.rawValue, privacy: .public)")
        return annotation
    }

    /// Over a vertical fold (a spread, flat or in book pose) the panel keeps to the left page: controls
    /// stay off the fold, and the right page, which holds the reading position, stays in full view.
    private var quickPanelWidth: CGFloat? {
        guard let division = regions?.division, division.height > division.width else { return nil }
        return max(0, division.minX - (geometry.reading?.safeArea.leading ?? 0))
    }

    /// The bars would cover the text being adjusted, so they make way for the panel.
    private func openQuickAppearance() {
        withAnimation(.snappy) {
            chromeVisible = false
            showQuickAppearance = true
        }
    }

    private func open(link href: String, from spine: Int) {
        guard let session else { return }
        if Typesetter.isExternal(href) {
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

    /// Every jump (link, contents, note, slider, synced position) remembers where it left from,
    /// so the "Back to page N" button can return there.
    private func jump(to location: ReadingLocation) {
        guard let session else { return }
        let from = session.location
        let target = session.clamp(location)
        trail.leave(from, page: folio(of: from, session: session), for: target, samePage: samePage)
        log.info("jump \(from.spineIndex):\(from.textOffset) → \(target.spineIndex):\(target.textOffset) trail=\(trail.stops.count)")
        session.location = target
        persist(target)
    }

    /// A search result: lands on the page that shows the hit (its start, not the hit itself, so the
    /// page is cut at a line as usual) through `jump(to:)`, which leaves a "Back to page N" stop,
    /// and paints the query's hits in that chapter until the next turn or tap.
    private func jump(to hit: SearchHit) {
        guard let session else { return }
        let target = session.pageStart(showing: hit.textOffset, inSpine: hit.spineIndex)
        print("[search] jump to hit \(hit.spineIndex):\(hit.textOffset) → page start \(target.spineIndex):\(target.textOffset)")
        jump(to: target)
        foundMarks = (search?.hits(inSpine: hit.spineIndex) ?? [hit]).map { found in
            HighlightMark(id: UUID(), spineIndex: found.spineIndex, range: NSRange(location: found.textOffset, length: found.length),
                          color: .yellow, isUnderline: false, isFound: true)
        }
    }

    private func openSearch() {
        guard let session, session.isReady else { return }
        if search == nil { search = BookSearchModel(session: session) }
        withAnimation(.snappy) {
            chromeVisible = false
            showQuickAppearance = false
        }
        showSearch = true
    }

    private func goBack() {
        guard let session, let place = trail.back() else { return }
        log.info("back to \(place.spineIndex):\(place.textOffset) trail=\(trail.stops.count)")
        session.location = session.clamp(place)
        persist(session.location)
    }

    /// Two locations on the same page of the current pagination.
    private func samePage(_ a: ReadingLocation, _ b: ReadingLocation) -> Bool {
        guard a.spineIndex == b.spineIndex else { return false }
        guard a.textOffset != b.textOffset else { return true }
        guard let chapter = session?.laidOutChapter(a.spineIndex) else { return false }
        return chapter.pageIndex(containing: a.textOffset) == chapter.pageIndex(containing: b.textOffset)
    }

    @ViewBuilder
    private func backButton(_ session: BookSession) -> some View {
        if !trail.isEmpty {
            BackToPageButton(label: trail.lastPage.map { "Back to page \($0)" } ?? "Back", onBack: goBack) {
                trail.clear()
            }
        }
    }

    /// The book-wide number the folio shows for `location`, from the layout on screen (never lays
    /// one out: see `BookSession.laidOutChapter`).
    private func folio(of location: ReadingLocation, session: BookSession) -> Int? {
        guard let chapter = session.laidOutChapter(location.spineIndex) else { return nil }
        return session.bookPages(spineIndex: location.spineIndex, page: chapter.pageIndex(containing: location.textOffset)).page
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
        library.publishRecentBook()
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
        library.publishRecentBook()
        goToFromLaunchArgument(session: fresh)
        openAppearanceFromLaunchArgument()
        searchFromLaunchArgument()
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

    /// `-SheafsAppearance quick|full` opens the quick panel or the detailed sheet once per launch, so
    /// screenshots and simulator checks can reach them without taps. `-SheafsThemeSwitch <theme>`
    /// (paper, sepia, night, black, system) switches the theme 5 s later, as a tap on its swatch would
    /// (`scripts/check-auto-theme`: Night → Automatic must follow the device).
    private func openAppearanceFromLaunchArgument() {
        guard !Self.appearanceArgumentConsumed else { return }
        Self.appearanceArgumentConsumed = true
        if let raw = UserDefaults.standard.string(forKey: "SheafsThemeSwitch"), let theme = ReaderTheme(rawValue: raw) {
            Task {
                try? await Task.sleep(for: .seconds(5))
                print("[theme] launch argument switches the theme to \(theme)")
                settings.theme = theme
            }
        }
        switch UserDefaults.standard.string(forKey: "SheafsAppearance") {
        case "quick": openQuickAppearance()
        case "full": showAppearance = true
        default: break
        }
    }

    private static var appearanceArgumentConsumed = false

    /// `-SheafsGoTo <contents title | 0…1>` moves to a table-of-contents entry (an exact title
    /// first, else the first title containing it) or to the paragraph at a fraction of the book
    /// that follows another paragraph (so the page starts on a whole paragraph, no heading is left
    /// alone on the page before, and the spread is full), once per launch, for screenshots
    /// (`scripts/screenshots`). Unlike `jump(to:)` it leaves no "Back to page N" trail.
    private func goToFromLaunchArgument(session: BookSession) {
        guard !Self.goToArgumentConsumed else { return }
        Self.goToArgumentConsumed = true
        guard let wanted = UserDefaults.standard.string(forKey: "SheafsGoTo"), !wanted.isEmpty else { return }
        let target: ReadingLocation?
        if let fraction = Double(wanted), (0...1).contains(fraction) {
            let spot = session.location(forProgress: fraction)
            let blocks = session.chapters[spot.spineIndex].blocks
            let before = blocks.indices.filter { blocks[$0].textOffset <= spot.textOffset }
            let index = before.last { $0 > 0 && blocks[$0].kind == .paragraph && blocks[$0 - 1].kind == .paragraph }
                ?? before.last
            let start = index.map { blocks[$0].textOffset } ?? spot.textOffset
            target = ReadingLocation(spineIndex: spot.spineIndex, textOffset: start)
        } else {
            let entry = session.flatTOC.first { $0.title.caseInsensitiveCompare(wanted) == .orderedSame }
                ?? session.flatTOC.first { $0.title.localizedCaseInsensitiveContains(wanted) }
            target = entry.flatMap(session.location(for:))
        }
        guard let target else {
            print("[goto] nothing in the contents matches \"\(wanted)\"")
            return
        }
        print("[goto] \(wanted) → \(target.spineIndex):\(target.textOffset)")
        session.location = session.clamp(target)
        persist(session.location)
    }

    private static var goToArgumentConsumed = false

    /// `-SheafsSearch <text>` opens the search sheet with `text` searched, once per launch; with
    /// `-SheafsSearchPick <n>` it then picks the n-th result (1-based) as a tap would, so a
    /// simulator check reaches the results and the painted hits without taps.
    private func searchFromLaunchArgument() {
        guard !Self.searchArgumentConsumed else { return }
        Self.searchArgumentConsumed = true
        guard let text = UserDefaults.standard.string(forKey: "SheafsSearch"), !text.isEmpty else { return }
        openSearch()
        guard let search else { return }
        search.query = text
        search.search(immediately: true)
        let pick = UserDefaults.standard.integer(forKey: "SheafsSearchPick")
        guard pick > 0 else { return }
        Task {
            var waited = 0
            while search.searchedQuery != text || search.isSearching, waited < 200 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            let rows = search.sections.flatMap(\.rows)
            guard pick <= rows.count else {
                print("[search] -SheafsSearchPick \(pick): only \(rows.count) results for \"\(text)\"")
                return
            }
            // Let the sheet finish appearing before it is dismissed.
            try? await Task.sleep(for: .seconds(1.5))
            showSearch = false
            jump(to: rows[pick - 1].hit)
        }
    }

    private static var searchArgumentConsumed = false

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
    let book: Book
    let annotations: [Annotation]
    var onSelect: (ReadingLocation) -> Void
    var onSearch: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var tab = ContentsTab.contents

    enum ContentsTab: Hashable { case contents, notes }

    var body: some View {
        NavigationStack {
            Group {
                if tab == .notes {
                    NotesListView(session: session, annotations: annotations, onSelect: onSelect)
                } else if session.flatTOC.isEmpty {
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
            .navigationTitle(tab == .notes ? "Notes" : "Contents")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Picker("Section", selection: $tab) {
                    Text("Contents").tag(ContentsTab.contents)
                    Text("Notes").tag(ContentsTab.notes)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if tab == .contents, let onSearch {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Search", systemImage: "magnifyingglass", action: onSearch)
                    }
                }
                if tab == .notes, !annotations.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: NotesListView.markdown(book: book, session: session, annotations: annotations),
                                  subject: Text("Notes from \(book.title)")) {
                            Label("Share Notes", systemImage: "square.and.arrow.up")
                        }
                    }
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
    var onSearch: () -> Void
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
                Button("Search", systemImage: "magnifyingglass", action: onSearch)
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
