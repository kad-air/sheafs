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
    func beginMarkup() { controller?.beginMarkup() }
    func endMarkup() { controller?.endMarkup() }
    func commitMarkup() { controller?.commitMarkup() }
#if DEBUG
    func drawMarkupDemo(_ spec: String) -> Int { controller?.drawMarkupDemo(spec) ?? 0 }
#endif
    var hostView: UIView? { controller?.viewIfLoaded }
}

/// The full-screen reading experience for one book.
struct ReaderView: View {
    let book: Book
    @Query private var annotations: [Annotation]
    @Query private var bookmarks: [Bookmark]
    @Query private var sketches: [Sketch]

    init(book: Book) {
        self.book = book
        let id = book.id
        _annotations = Query(filter: #Predicate<Annotation> { $0.bookID == id },
                             sort: [SortDescriptor(\Annotation.spineIndex), SortDescriptor(\Annotation.startOffset)])
        _bookmarks = Query(filter: #Predicate<Bookmark> { $0.bookID == id },
                           sort: [SortDescriptor(\Bookmark.spineIndex), SortDescriptor(\Bookmark.textOffset)])
        _sketches = Query(filter: #Predicate<Sketch> { $0.bookID == id },
                          sort: [SortDescriptor(\Sketch.spineIndex), SortDescriptor(\Sketch.startOffset)])
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
    /// The page holding the position has a bookmark. State, refreshed after the inputs change
    /// (`refreshBookmarkHere`), so the body never reads the pagination cache: every prefetch would
    /// otherwise re-run the whole reader body.
    @State private var bookmarkHere = false
    /// The contents sheet's segment, kept between openings.
    @State private var contentsTab = ContentsView.ContentsTab.contents
    @State private var showAppearance = false
    /// The small panel over the bottom of the page; `showAppearance` is the detailed sheet behind it.
    @State private var showQuickAppearance = false
    @State private var geometry = SteadyPageGeometry()
    @State private var regions: WindowRegions?
    @State private var orientation: UIInterfaceOrientation = .unknown
    @State private var footnote: Footnote?
    @State private var editingAnnotation: Annotation?
    /// A UIKit sheet the pager put up (the share sheet, Look Up): SwiftUI can't see it, and the
    /// volume buttons must be the volume again while it is up.
    @State private var pagerSheet = false
    @State private var remotePrompt: RemotePrompt?
    @State private var pagerProxy = PagerProxy()
    @State private var volumeButtons = VolumeButtonPager()
    @State private var pushTask: Task<Void, Never>?
    @State private var sliderValue: Double = 0
    @State private var isScrubbing = false
    @State private var trail = ReturnTrail()
    @State private var showSearch = false
    /// The Ask panel over the bottom of the page (`AskPanel`).
    @State private var showAsk = false
    /// Ask about the book (`AskModel`), made when the book is ready and Ask is on; kept for the
    /// reader's life so the passage index survives the panel closing.
    @State private var ask: AskModel?
    /// Find-in-book, made the first time the search opens; kept so reopening shows the last results.
    @State private var search: BookSearchModel?
    /// The contents sheet's Search button: the search opens once that sheet is gone.
    @State private var searchAfterContents = false
    /// The searched query's hits in the chapter jumped to, painted until the next turn or tap.
    @State private var foundMarks: [HighlightMark] = []
    /// The picture open full screen, if any.
    @State private var viewedImage: ViewedImage?
    /// Marking up the pages with PencilKit (the toolbar's Markup button; Done ends it).
    @State private var markingUp = false

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
            } else if showAsk {
                askPanel
                    .frame(maxWidth: quickPanelWidth ?? .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            // Over everything, the bars included; the reader's forced colour scheme still applies.
            if let viewedImage {
                ImageViewer(viewed: viewedImage, palette: palette, division: regions?.division,
                            divisionIsActive: regions?.divisionIsActive ?? false, orientation: orientation) {
                    closeImage()
                }
                .transition(.opacity)
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
                ContentsView(session: session, book: book, annotations: annotations, bookmarks: bookmarks, sketches: sketches,
                             tab: $contentsTab, onSelect: { location in
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
        .onChange(of: askRunning, initial: true) { _, running in
            runAsk(running)
        }
        .onDisappear {
            ask?.recaps.stop()
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
                                marks: annotations.map(\.mark) + foundMarks, bookmarks: bookmarks.map(\.mark), sketches: sketches.compactMap(\.mark), highlightColor: settings.highlightColor, pageTurn: settings.pageTurn, proxy: pagerProxy,
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
                                onSelectionAction: handle(selection:),
                                onSystemSheet: { pagerSheet = $0 },
                                onSketchEdits: { library.apply($0, for: book) })
                    if let deck = layout.deckFrame {
                        ReaderDeck(session: session, palette: palette, proxy: pagerProxy,
                                   showContents: $showContents, showAppearance: $showQuickAppearance,
                                   onSearch: openSearch,
                                   isBookmarked: bookmarkHere, onToggleBookmark: toggleBookmark) { location in
                            jump(to: location)
                        }
                        .frame(width: deck.width, height: deck.height)
                        .offset(x: deck.minX, y: deck.minY)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if markingUp, let page = layout.pageFrames.last {
                        // Over the running head of the page that holds the position, clear of a
                        // fold; the tool picker takes the bottom of the screen.
                        MarkupBar(onPrevious: { pagerProxy.turn(forward: false) }, onDone: endMarkup,
                                  onNext: { pagerProxy.turn(forward: true) })
                            .position(x: page.midX, y: page.minY + max(24, layout.textInsets.top - 20))
                            .transition(.opacity)
                    }
                    // The Ask panel carries its own "Back to page N" (it may cover the folio).
                    if !chromeVisible, !showQuickAppearance, !showAsk, !markingUp, let page = layout.pageFrames.last {
                        backButton(session)
                            // Over the folio of the page that holds the position (the right page of a spread).
                            .position(x: page.midX, y: page.maxY - PageLayout.footerHeight / 2 + 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.snappy, value: trail)
                .onChange(of: BookmarkInputs(location: session.location, textSize: layout.textSize, style: style,
                                             marks: bookmarks.map(\.mark)), initial: true) {
                    // After the pager's update has laid the page out for the new position or size.
                    DispatchQueue.main.async { refreshBookmarkHere() }
                }
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
        if settings.askEnabled {
            ToolbarItem(placement: .primaryAction) {
                Button("Ask About the Book", systemImage: "bubble.left.and.text.bubble.right") { openAsk() }
                    .disabled(session?.isReady != true)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Appearance", systemImage: "textformat.size") { openQuickAppearance() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Markup", systemImage: "pencil.tip.crop.circle") { startMarkup() }
                .disabled(session?.isReady != true)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(bookmarkHere ? "Remove Bookmark" : "Add Bookmark", systemImage: bookmarkHere ? "bookmark.fill" : "bookmark") {
                toggleBookmark()
            }
            .disabled(session?.isReady != true)
        }
        .visibilityPriority(.high)
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
    /// sheet up (contents, appearance, a note, a footnote) they change the volume again. The
    /// floating panels (quick appearance, Ask) leave them turning pages, as the edge taps do. Leaving
    /// the foreground stops them, so Control Center's volume works and they re-arm on return.
    private var volumeButtonsArmed: Bool {
        (settings.volumeButtonsTurn || volumeProbeRequested) && scenePhase == .active && session?.isReady == true && regions != nil
            && !showContents && !showAppearance && !showSearch && footnote == nil && editingAnnotation == nil && !pagerSheet
            && viewedImage == nil
    }

    /// `-SheafsVolumeProbe` (a debug launch argument) arms the buttons whatever the setting says.
    private var volumeProbeRequested: Bool {
        UserDefaults.standard.string(forKey: "SheafsVolumeProbe") != nil
    }

    private func armVolumeButtons(_ armed: Bool) {
        VolumeLog.shared.note("armed=\(armed): setting=\(settings.volumeButtonsTurn) scene=\(scenePhase) "
            + "ready=\(session?.isReady == true) regions=\(regions != nil) contents=\(showContents) "
            + "appearance=\(showAppearance) search=\(showSearch) ask=\(showAsk) footnote=\(footnote != nil) note=\(editingAnnotation != nil) "
            + "systemSheet=\(pagerSheet) image=\(viewedImage != nil)")
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
            } else if showAsk {
                closeAsk()
            } else {
                withAnimation(.snappy) { chromeVisible.toggle() }
            }
        case .previous, .next:
            break // the pager turns the page itself
        case .link(let href, let spine):
            open(link: href, from: spine)
        case .annotation(let id):
            editingAnnotation = annotations.first { $0.id == id }
        case .image(let tap):
            open(image: tap)
        }
    }

    /// Opens a tapped picture full screen, at its own resolution (decoded off the main actor).
    private func open(image tap: ImageTap) {
        guard let session else { return }
        let alt = session.imageBlock(spineIndex: tap.spineIndex, textOffset: tap.textOffset)?.alt
        Task {
            guard let image = await session.fullImage(source: tap.source, spineIndex: tap.spineIndex) else {
                print("[image] can't decode \(tap.source) (spine \(tap.spineIndex))")
                log.error("image \(tap.source, privacy: .public) could not be decoded")
                return
            }
            withAnimation(.snappy) {
                chromeVisible = false
                showQuickAppearance = false
                showAsk = false
                viewedImage = ViewedImage(image: image, alt: alt, source: tap.source, pageFrame: tap.pageFrame)
            }
        }
    }

    private func closeImage() {
        print("[image] viewer closed")
        withAnimation(.snappy) { viewedImage = nil }
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

    // MARK: Markup

    /// Draws on the pages with PencilKit: the bars go, a canvas covers the spread and the tool
    /// picker comes up; the markup bar turns pages and ends it.
    private func startMarkup() {
        withAnimation(.snappy) {
            chromeVisible = false
            showQuickAppearance = false
            showAsk = false
            markingUp = true
        }
        pagerProxy.beginMarkup()
    }

    private func endMarkup() {
        pagerProxy.endMarkup()
        withAnimation(.snappy) { markingUp = false }
    }

    // MARK: Bookmarks

    /// The page that holds the reading position (the right-hand page of a spread), from the layout
    /// on screen; nil until it is laid out (never lays one out: see `BookSession.laidOutChapter`).
    /// Not for the body: it reads the pagination cache.
    private func currentPage() -> (chapter: PaginatedChapter, page: Int)? {
        guard let session, session.isReady, let chapter = session.laidOutChapter(session.location.spineIndex) else { return nil }
        return (chapter, chapter.pageIndex(containing: session.location.textOffset))
    }

    /// What decides whether the page holding the position has a bookmark.
    private struct BookmarkInputs: Equatable {
        var location: ReadingLocation
        var textSize: CGSize
        var style: TypesetStyle
        var marks: [BookmarkMark]
    }

    /// Whether the current page holds a bookmark: any whose offset falls in its character range,
    /// so a bookmark made at another text size still counts. Called outside the body only.
    private func refreshBookmarkHere() {
        let here = !bookmarks(onCurrentPageOf: bookmarks).isEmpty
        if here != bookmarkHere { bookmarkHere = here }
    }

    /// The bookmarks on the current page, from the layout on screen (outside the body only).
    private func bookmarks(onCurrentPageOf list: [Bookmark]) -> [Bookmark] {
        guard let (chapter, page) = currentPage() else { return [] }
        let ids = Set(chapter.bookmarks(list.map(\.mark), onPage: page).map(\.id))
        return list.filter { ids.contains($0.id) }
    }

    /// Marks the current page at its first character, or unmarks it (every bookmark on it).
    private func toggleBookmark() {
        guard let session, let (chapter, page) = currentPage() else { return }
        let here = bookmarks(onCurrentPageOf: library.bookmarks(for: book))
        if !here.isEmpty {
            for bookmark in here { library.delete(bookmark) }
            log.info("bookmark removed at \(chapter.spineIndex):\(page) (\(here.count))")
            print("[bookmark] removed \(here.count) on spine=\(chapter.spineIndex) page=\(page)")
            return
        }
        let start = ReadingLocation(spineIndex: chapter.spineIndex, textOffset: chapter.range(ofPage: page).location)
        var label = Bookmark.label(in: chapter.textStorage.string as NSString, at: start.textOffset)
        // A page that starts in a table: the label is its rows' text, not their object characters.
        if start.spineIndex < session.chapters.count, let block = session.chapters[start.spineIndex].block(containing: start.textOffset),
           case .table = block.kind {
            let quoted = session.chapters[start.spineIndex].displayText(in: start.textOffset ..< min(session.chapters[start.spineIndex].textLength, start.textOffset + 240))
            label = Bookmark.label(in: quoted as NSString, at: 0)
        }
        let bookmark = Bookmark(bookID: book.id, spineIndex: start.spineIndex, textOffset: start.textOffset,
                                xpointer: session.xpointer(for: start)?.serialized, label: label)
        library.add(bookmark)
        log.info("bookmark added at \(start.spineIndex):\(start.textOffset)")
        print("[bookmark] added spine=\(start.spineIndex) offset=\(start.textOffset) pointer=\(bookmark.xpointer ?? "-") label=\(bookmark.label)")
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
            showAsk = false
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
            // A note in a table: its row's cells, not the row's object character.
            var text = block.text
            if case .table(let table) = block.kind { text = table.plainText(atOffset: target.textOffset - block.textOffset) }
            footnote = Footnote(text: text, location: target)
        } else {
            jump(to: target)
        }
    }

    /// Every jump (link, contents, note, slider, synced position) remembers where it left from,
    /// so the "Back to page N" button can return there. Showing a page by hand never reports a
    /// location change, so the found hits are dropped here (a search jump paints its own after).
    private func jump(to location: ReadingLocation) {
        guard let session else { return }
        if !foundMarks.isEmpty { foundMarks = [] }
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

    // MARK: Ask

    /// Ask runs (summarising finished chapters in the background) while it is on, the book is
    /// ready and the app is in front.
    private var askRunning: Bool {
        settings.askEnabled && scenePhase == .active && session?.isReady == true
    }

    private func runAsk(_ running: Bool) {
        guard running, let session else {
            ask?.recaps.stop()
            return
        }
        if ask == nil { ask = AskModel(session: session, bookID: book.id) }
        ask?.readerMoved(to: session.location.spineIndex)
    }

    /// A passage tapped in the panel turns to its page with the panel still up; the panel's own
    /// "Back to page N" returns.
    @ViewBuilder
    private var askPanel: some View {
        if let ask, let session {
            AskPanel(model: ask, maxHeight: askPanelHeight,
                     backLabel: trail.isEmpty ? nil : trail.lastPage.map { "Back to page \($0)" } ?? "Back",
                     onBack: goBack,
                     onGo: { location in
                         jump(to: session.pageStart(showing: location.textOffset, inSpine: location.spineIndex))
                     },
                     onClose: closeAsk)
        }
    }

    /// The tallest the panel's answer may grow before it scrolls: the whole panel, header and
    /// input bar included, stays under half the screen, so the page stays in view.
    private var askPanelHeight: CGFloat {
        let height = geometry.reading?.size.height ?? 700
        return max(140, height * 0.5 - AskPanel.chromeHeight)
    }

    private func openAsk() {
        guard let session, session.isReady else { return }
        if ask == nil { ask = AskModel(session: session, bookID: book.id) }
        ask?.limit = readingLimit(session)
        withAnimation(.snappy) {
            chromeVisible = false
            showQuickAppearance = false
            showAsk = true
        }
    }

    private func closeAsk() {
        withAnimation(.snappy) { showAsk = false }
    }

    /// 🔴 The end of what the reader can see: the end of the page holding the position (the right
    /// page of a spread), else the position itself. Ask never reads past it.
    private func readingLimit(_ session: BookSession) -> ReadingLimit {
        let location = session.location
        if let chapter = session.laidOutChapter(location.spineIndex) {
            let page = chapter.range(ofPage: chapter.pageIndex(containing: location.textOffset))
            return ReadingLimit(spineIndex: location.spineIndex, textOffset: page.location + page.length)
        }
        return ReadingLimit(spineIndex: location.spineIndex, textOffset: location.textOffset)
    }

    private func openSearch() {
        guard let session, session.isReady else { return }
        if search == nil { search = BookSearchModel(session: session) }
        withAnimation(.snappy) {
            chromeVisible = false
            showQuickAppearance = false
            showAsk = false
        }
        showSearch = true
    }

    private func goBack() {
        guard let session, let place = trail.back() else { return }
        if !foundMarks.isEmpty { foundMarks = [] }
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
        ask?.readerMoved(to: location.spineIndex)
        // Turning on with the panel up reads further: the next question may use the new page.
        if showAsk, let ask { ask.extendLimit(to: readingLimit(session)) }
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
        pagerProxy.commitMarkup()
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
        if fresh.reanchor(annotations) + fresh.reanchor(bookmarks) + fresh.reanchor(sketches) > 0 { library.save() }
        book.lastOpenedAt = .now
        library.save()
        library.publishRecentBook()
        goToFromLaunchArgument(session: fresh)
        openAppearanceFromLaunchArgument()
        searchFromLaunchArgument()
        askFromLaunchArgument()
        bookmarkFromLaunchArgument(session: fresh)
        openImageFromLaunchArgument(session: fresh)
#if DEBUG
        demoFromLaunchArguments(session: fresh)
#endif
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

    /// `-SheafsBookmark toggle|jump` toggles the bookmark on the page at the position, or jumps
    /// (`jump(to:)`, so with a "Back to page N" trail) to the book's first bookmark, once the page is
    /// laid out; `-SheafsContents contents|bookmarks|notes` opens the contents sheet on that
    /// segment. Once per launch, for simulator checks (the simulator can't be tapped headless).
    private func bookmarkFromLaunchArgument(session: BookSession) {
        guard !Self.bookmarkArgumentConsumed else { return }
        Self.bookmarkArgumentConsumed = true
        let defaults = UserDefaults.standard
        let action = defaults.string(forKey: "SheafsBookmark")
        let segment = defaults.string(forKey: "SheafsContents")
        guard action != nil || segment != nil else { return }
        Task {
            // The pager appears once the window's regions are known, and lays the page out then.
            var waited = 0
            while session.laidOutChapter(session.location.spineIndex) == nil, waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            try? await Task.sleep(for: .seconds(1))
            switch action {
            case "toggle": toggleBookmark()
            case "jump":
                if let first = library.bookmarks(for: book).first {
                    print("[bookmark] jump to spine=\(first.spineIndex) offset=\(first.textOffset)")
                    jump(to: first.location)
                } else {
                    print("[bookmark] jump: the book has no bookmarks")
                }
            case nil: break
            case let other?: print("[bookmark] unknown action \(other)")
            }
            switch segment {
            case "contents": contentsTab = .contents
            case "bookmarks": contentsTab = .bookmarks
            case "notes": contentsTab = .notes
            default: break
            }
            if segment != nil { showContents = true }
        }
    }

    private static var bookmarkArgumentConsumed = false

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
    /// simulator check reaches the results and the painted hits without taps; `-SheafsSearchBack`
    /// then goes back 3 s later, as the "Back to page N" capsule would (the hits must go).
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
            // `-SheafsSearchBack`: then "Back to page N", as a tap on the capsule would.
            guard UserDefaults.standard.bool(forKey: "SheafsSearchBack") else { return }
            try? await Task.sleep(for: .seconds(3))
            print("[search] back (launch argument), found marks before: \(foundMarks.count)")
            goBack()
            print("[search] back done, found marks after: \(foundMarks.count)")
        }
    }

    private static var searchArgumentConsumed = false

    /// `-SheafsAsk <question>` opens the Ask panel once the book is ready and asks it (whatever the
    /// setting says), printing the availability, the answer and its sources as `[ask]` lines, so a
    /// simulator or device run can be checked without typing. `-SheafsAskOpen 1` only opens the
    /// panel and prints how many saved questions it holds; `-SheafsAskSource <n>` then turns to the
    /// answer's nth passage (1-based), the panel staying up.
    private func askFromLaunchArgument() {
        guard !Self.askArgumentConsumed else { return }
        Self.askArgumentConsumed = true
        let defaults = UserDefaults.standard
        let question = defaults.string(forKey: "SheafsAsk") ?? ""
        guard !question.isEmpty || defaults.string(forKey: "SheafsAskOpen") != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            openAsk()
            guard let ask else { return }
            print("[ask] availability: \(ask.availability) limit: \(ask.limit.spineIndex):\(ask.limit.textOffset) "
                + "saved: \(ask.exchanges.count)")
            for exchange in ask.exchanges {
                print("[ask] saved: \(exchange.question) (\(exchange.caption), \(exchange.sources.count) sources)")
            }
            if !question.isEmpty {
                ask.ask(question)
                var waited = 0
                while ask.isBusy, waited < 1200 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
            }
            guard let last = ask.exchanges.last else { return print("[ask] no exchange") }
            print("[ask] state: \(last.state)")
            print("[ask] answer: \(last.answer)")
            for source in last.sources {
                print("[ask] source \(source.location.spineIndex):\(source.location.textOffset) \(source.chapter): \(source.snippet.prefix(80))")
            }
            let pick = defaults.integer(forKey: "SheafsAskSource")
            if pick > 0, pick <= last.sources.count, let session {
                let location = last.sources[pick - 1].location
                jump(to: session.pageStart(showing: location.textOffset, inSpine: location.spineIndex))
                print("[ask] opened source \(pick); panel shown: \(showAsk) trail: \(trail.stops.count)")
            }
        }
    }

    private static var askArgumentConsumed = false

#if DEBUG
    /// Debug, for App Store screenshots (the simulator has no Pencil and can't long-press):
    /// `-SheafsHighlightDemo "<phrase>|<phrase>…"` highlights the first place in the book each
    /// phrase occurs, through the highlight colours in turn (`-SheafsHighlightNote <text>` puts a
    /// note on the first); `-SheafsMarkupDemo "page=<phrase>|underline=<phrase>|circle=<phrase>|bracket=<phrase>|note=<text>"`
    /// turns to the first phrase (the page starts there), starts markup, draws `ScreenshotDemo`'s strokes on
    /// the canvases and ends it 1.5 s later as Done would (saving them as markings), unless
    /// `-SheafsMarkupStay YES` leaves markup up. Once per launch; prints `[demo]` lines.
    private func demoFromLaunchArguments(session: BookSession) {
        guard !Self.demoArgumentConsumed else { return }
        Self.demoArgumentConsumed = true
        let defaults = UserDefaults.standard
        if let list = defaults.string(forKey: "SheafsHighlightDemo") {
            let existing = library.annotations(for: book)
            let colours = HighlightColor.allCases
            for (number, phrase) in list.split(separator: "|").map(String.init).enumerated() {
                guard let hit = ScreenshotDemo.find(phrase, in: session.chapters) else {
                    print("[demo] highlight: \"\(phrase)\" is not in the book")
                    continue
                }
                guard !existing.contains(where: { $0.spineIndex == hit.spineIndex && $0.startOffset == hit.range.location }) else {
                    print("[demo] highlight: \"\(phrase)\" is highlighted already")
                    continue
                }
                let text = session.chapters[hit.spineIndex].displayText(in: hit.range.location ..< NSMaxRange(hit.range))
                let annotation = add(TextSelection(spineIndex: hit.spineIndex, range: hit.range), text: text,
                                     color: colours[number % colours.count])
                if number == 0, let note = defaults.string(forKey: "SheafsHighlightNote") { annotation.note = note }
                print("[demo] highlight \(hit.spineIndex):\(hit.range.location)+\(hit.range.length) \(annotation.color.rawValue)")
            }
            library.save()
        }
        guard let spec = defaults.string(forKey: "SheafsMarkupDemo"),
              let first = ScreenshotDemo.parse(spec).first(where: { $0.kind != "note" }) else { return }
        guard let hit = ScreenshotDemo.find(first.value, in: session.chapters) else {
            print("[demo] markup: \"\(first.value)\" is not in the book")
            return
        }
        // The first phrase starts the (right-hand) page: the first layout breaks the page at the
        // position, so the passage after it is on screen whatever the page size.
        session.location = session.clamp(ReadingLocation(spineIndex: hit.spineIndex, textOffset: hit.range.location))
        persist(session.location)
        print("[demo] markup: page of \(hit.spineIndex):\(hit.range.location) → \(session.location.spineIndex):\(session.location.textOffset)")
        Task {
            var waited = 0
            while pagerProxy.controller == nil || session.laidOutChapter(session.location.spineIndex) == nil, waited < 150 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            try? await Task.sleep(for: .seconds(1.5))
            startMarkup()
            try? await Task.sleep(for: .seconds(1))
            let drawn = pagerProxy.drawMarkupDemo(spec)
            print("[demo] markup: drew \(drawn) strokes")
            guard !defaults.bool(forKey: "SheafsMarkupStay") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            endMarkup()
            try? await Task.sleep(for: .seconds(1))
            print("[demo] markup: done, \(library.sketches(for: book).count) markings saved")
        }
    }

    private static var demoArgumentConsumed = false
#endif

    /// `-SheafsOpenImage <n>` moves to the book's nth picture (1-based, reading order) and, once its
    /// page is up, first SINGLE-taps its middle through `PagerController.tap(at:)` (the single-tap
    /// recognizer's action: it must only toggle the bars, like any centre tap), then double-taps it
    /// through `PagerController.doubleTap(at:)` (the double-tap recognizer's action, behind the same
    /// `acceptsDoubleTap` check its `shouldReceive` makes), so the simulator can check the gestures'
    /// decisions and the viewer without a finger. `-SheafsOpenImageSide left` (a spread) shows the
    /// picture's page on the LEFT, by moving to the page after it. `-SheafsCloseImageAfter <s>`
    /// closes the viewer that many seconds after it opened, as ✕ does.
    private func openImageFromLaunchArgument(session: BookSession) {
        guard !Self.imageArgumentConsumed else { return }
        Self.imageArgumentConsumed = true
        let wanted = UserDefaults.standard.integer(forKey: "SheafsOpenImage")
        guard wanted > 0 else { return }
        let pictures = session.imageLocations()
        guard wanted <= pictures.count else {
            print("[image] -SheafsOpenImage \(wanted): the book has \(pictures.count) pictures")
            return
        }
        let target = pictures[wanted - 1]
        let onLeft = UserDefaults.standard.string(forKey: "SheafsOpenImageSide") == "left"
        print("[image] -SheafsOpenImage \(wanted) → \(target.spineIndex):\(target.textOffset)\(onLeft ? " on the left page" : "")")
        session.location = target
        let closeAfter = UserDefaults.standard.double(forKey: "SheafsCloseImageAfter")
        Task {
            var moved = !onLeft
            // The pager appears once the window's regions are known, then lays the spread out.
            for _ in 0 ..< 150 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let controller = pagerProxy.controller,
                      let point = controller.imageCentre(spineIndex: target.spineIndex, textOffset: target.textOffset) else { continue }
                if !moved {
                    // The spread shows the page holding the position on the right: go to the page after
                    // the picture's, and the picture's page is on the left.
                    guard let chapter = session.laidOutChapter(target.spineIndex) else { continue }
                    let page = chapter.pageIndex(containing: target.textOffset)
                    session.location = page + 1 < chapter.pageCount
                        ? ReadingLocation(spineIndex: target.spineIndex, textOffset: chapter.range(ofPage: page + 1).location)
                        : ReadingLocation(spineIndex: target.spineIndex + 1, textOffset: 0)
                    moved = true
                    continue
                }
                // Until the pager has re-shown the spread, the picture is still on the right.
                if onLeft, point.x >= controller.view.bounds.midX { continue }
                print("[image] picture's middle at \(point) in a view \(controller.view.bounds.size) wide")
                controller.tap(at: point)
                try? await Task.sleep(for: .milliseconds(1500))
                print("[image] after a single tap on the picture the viewer is \(viewedImage == nil ? "closed" : "OPEN")")
                guard controller.doubleTap(at: point) else {
                    print("[image] the double tap did not take the picture")
                    return
                }
                if closeAfter > 0 {
                    for _ in 0 ..< 50 where viewedImage == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .seconds(closeAfter))
                    if viewedImage != nil { closeImage() }
                }
                return
            }
            print("[image] -SheafsOpenImage \(wanted): picture never appeared on a page")
        }
    }

    private static var imageArgumentConsumed = false

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
    let bookmarks: [Bookmark]
    var sketches: [Sketch] = []
    @Binding var tab: ContentsTab
    var onSelect: (ReadingLocation) -> Void
    var onSearch: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    enum ContentsTab: Hashable { case contents, bookmarks, notes }

    private var title: String {
        switch tab {
        case .contents: "Contents"
        case .bookmarks: "Bookmarks"
        case .notes: "Notes"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if tab == .notes {
                    NotesListView(session: session, annotations: annotations, sketches: sketches, onSelect: onSelect)
                } else if tab == .bookmarks {
                    BookmarksListView(session: session, bookmarks: bookmarks, onSelect: onSelect)
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Picker("Section", selection: $tab) {
                    Text("Contents").tag(ContentsTab.contents)
                    Text("Bookmarks").tag(ContentsTab.bookmarks)
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
                if tab != .contents, !annotations.isEmpty || !bookmarks.isEmpty || !sketches.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: NotesListView.markdown(book: book, session: session, annotations: annotations,
                                                               bookmarks: bookmarks, sketches: sketches),
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
    /// The page that holds the position has a bookmark.
    var isBookmarked: Bool
    var onToggleBookmark: () -> Void
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
                Button(isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                       systemImage: isBookmarked ? "bookmark.fill" : "bookmark", action: onToggleBookmark)
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
        // The surface the page stands on (`TabletopBaseView` runs from the page's edge to here).
        .background(Color(uiColor: palette.surface))
    }
}
