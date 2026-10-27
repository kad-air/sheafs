import SwiftUI
import UIKit
import os

/// One page's identity in the pager.
struct PageSlot: Hashable {
    var spineIndex: Int
    var page: Int
}

enum ReaderTap {
    case previous, next, center
    case link(href: String, spineIndex: Int)
    /// A tap on an existing highlight.
    case annotation(id: UUID)
}

/// A run of selected text in one chapter.
struct TextSelection: Hashable {
    var spineIndex: Int
    var range: NSRange
}

/// What the user asked for from the selection menu.
enum SelectionAction {
    case highlight(TextSelection, text: String, color: HighlightColor)
    case note(TextSelection, text: String, color: HighlightColor)
}

/// Hosts a `UIPageViewController` whose units are spreads of one or two pages.
struct ReaderPager: UIViewControllerRepresentable {
    let session: BookSession
    let layout: PageLayout
    let style: TypesetStyle
    let palette: ReaderPalette
    let location: ReadingLocation
    let tapTurnsPages: Bool
    let marks: [HighlightMark]
    let bookmarks: [BookmarkMark]
    let highlightColor: HighlightColor
    let pageTurn: PageTurnStyle
    let proxy: PagerProxy
    var onLocationChange: (ReadingLocation) -> Void
    var onTap: (ReaderTap) -> Void
    var onSelectionAction: (SelectionAction) -> Void
    /// A UIKit sheet (share, Look Up) went up (true) or away (false).
    var onSystemSheet: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> PagerController {
        let controller = PagerController(session: session)
        proxy.controller = controller
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: PagerController, context: Context) {
        configure(controller)
    }

    private func configure(_ controller: PagerController) {
        controller.onLocationChange = onLocationChange
        controller.onTap = onTap
        controller.onSelectionAction = onSelectionAction
        controller.onSystemSheet = onSystemSheet
        controller.tapTurnsPages = tapTurnsPages
        controller.highlightColor = highlightColor
        controller.pageTurn = pageTurn
        session.configure(style: style, textSize: layout.textSize)
        controller.apply(marks: marks)
        controller.apply(bookmarks: bookmarks)
        controller.apply(layout: layout, palette: palette, location: location, animated: false)
    }
}

final class PagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    let session: BookSession
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                             options: [.interPageSpacing: 0])
    private(set) var layout = PageLayout(pageFrames: [], textInsets: .zero, deckFrame: nil)
    private(set) var palette = ReaderPalette.paper
    /// The location of the first page of the visible spread.
    private(set) var displayedLocation: ReadingLocation?
    var onLocationChange: ((ReadingLocation) -> Void)?
    var onTap: ((ReaderTap) -> Void)?
    var onSelectionAction: ((SelectionAction) -> Void)?
    var onSystemSheet: ((Bool) -> Void)?
    var tapTurnsPages = true
    var highlightColor = HighlightColor.yellow
    /// How pages turn: a flipping leaf (the default) or the page controller's slide. The flip
    /// needs Metal and respects Reduce Motion; otherwise pages slide.
    var pageTurn = PageTurnStyle.flip { didSet { if pageTurn != oldValue { updateTurnStyle() } } }
    private lazy var flip = PageFlipDriver(host: self)
    private var flipPan: UIPanGestureRecognizer?
    var pagerView: UIView { pager.view }
    /// The style generation the visible spread was built with; a change re-lays out at the same place.
    private var appliedStyle: TypesetStyle?

    // Selection: a long press selects the word under the finger and grows it by words while the
    // finger moves; the handles then adjust it by characters, and the edit menu acts on it.
    private(set) var selection: TextSelection?
    private var selectionAnchor: NSRange?
    private let startHandle = SelectionHandleView(isStart: true)
    private let endHandle = SelectionHandleView(isStart: false)
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private weak var scrollView: UIScrollView?
    private let log = Logger(subsystem: "io.sheafs.reader", category: "pager")

    init(session: BookSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.background
        addChild(pager)
        view.addSubview(pager.view)
        pager.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.view.topAnchor.constraint(equalTo: view.topAnchor),
            pager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pager.didMove(toParent: self)
        pager.dataSource = self
        pager.delegate = self
        disableInsetAdjustment()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.4
        press.delegate = self
        view.addGestureRecognizer(press)
        view.addInteraction(editMenu)
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            handle.tintColor = palette.link
            view.addSubview(handle)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHandlePan(_:)))
            handle.addGestureRecognizer(pan)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleFlipPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        // Selecting text wins: the pan waits for the long press to fail, and never fires on a handle.
        pan.require(toFail: press)
        for handle in [startHandle, endHandle] {
            for handlePan in handle.gestureRecognizers ?? [] { pan.require(toFail: handlePan) }
        }
        view.addGestureRecognizer(pan)
        flipPan = pan
        updateTurnStyle()
    }

    private var flipsPages: Bool {
        pageTurn == .flip && !UIAccessibility.isReduceMotionEnabled && flip.isSupported
    }

    /// Flipping takes over the horizontal pan from the page controller's scroll view.
    private func updateTurnStyle() {
        guard isViewLoaded else { return }
        flip.finishNow()
        let flips = flipsPages
        flipPan?.isEnabled = flips
        pager.view.subviews.compactMap { $0 as? UIScrollView }.forEach { $0.isScrollEnabled = !flips }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        disableInsetAdjustment()
    }

    /// The page layout already accounts for safe areas; UIKit must not shift the pages again when
    /// the bars appear (otherwise every chrome toggle moves the text). The page controller's
    /// scroll view is created lazily, so this runs on every layout pass. The same pass makes the
    /// page swipe yield to the selection handles.
    private func disableInsetAdjustment() {
        pager.view.subviews.compactMap { $0 as? UIScrollView }.forEach { scrollView in
            if scrollView.contentInsetAdjustmentBehavior != .never {
                scrollView.contentInsetAdjustmentBehavior = .never
            }
            if self.scrollView !== scrollView {
                self.scrollView = scrollView
                for handle in [startHandle, endHandle] {
                    for pan in handle.gestureRecognizers ?? [] { scrollView.panGestureRecognizer.require(toFail: pan) }
                }
            }
            if scrollView.isScrollEnabled == flipsPages { scrollView.isScrollEnabled = !flipsPages }
        }
    }

    // MARK: Configuration

    func apply(layout: PageLayout, palette: ReaderPalette, location: ReadingLocation, animated: Bool) {
        let layoutChanged = layout != self.layout
        let paletteChanged = palette != self.palette
        let styleChanged = session.style != appliedStyle
        self.layout = layout
        self.palette = palette
        view.backgroundColor = palette.background
        startHandle.tintColor = palette.link
        endHandle.tintColor = palette.link
        guard session.isReady, !layout.pageFrames.isEmpty, session.style != nil else { return }
        appliedStyle = session.style
        if layoutChanged || paletteChanged || styleChanged {
            flip.finishNow()
            flip.invalidateTextures()
        }
        // A turn in flight owns the pager; it announces its location when the leaf lands.
        guard !flip.isActive else { return }
        if layoutChanged || paletteChanged || styleChanged || displayedLocation == nil || displayedLocation != location {
            show(location: location, animated: animated && !layoutChanged)
            autoFlipForScreenshots()
            autoSelectForScreenshots()
        }
    }

    private var autoFlipped = false

    /// Debug: `-SheafsFlipAuto forward|back` (with `-SheafsFlipFreeze <amount>` and optionally
    /// `-SheafsFlipGrab <0…1 down the page>`) starts one turn on its own once the book is up,
    /// so a screenshot can catch the leaf mid-air.
    private func autoFlipForScreenshots() {
        let defaults = UserDefaults.standard
        guard !autoFlipped, let direction = defaults.string(forKey: "SheafsFlipAuto") else { return }
        autoFlipped = true
        let grab = defaults.object(forKey: "SheafsFlipGrab") == nil ? 0.5 : defaults.double(forKey: "SheafsFlipGrab")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let frame = layout.pageFrames.last else { return }
            let point = CGPoint(x: frame.maxX - 20, y: frame.minY + frame.height * grab)
            turnPage(forward: direction != "back", from: point)
        }
    }

    /// The book's highlights; the visible spread repaints when they change, later spreads read
    /// them from the session as they appear.
    func apply(marks: [HighlightMark]) {
        guard marks != session.marks else { return }
        session.marks = marks
        currentSpread?.refreshMarks()
        flip.invalidateTextures()
    }

    /// The book's bookmarks; like the highlights, the visible spread redraws its ribbons and the
    /// flip's cached leaves are dropped (they would show the old ribbon).
    func apply(bookmarks: [BookmarkMark]) {
        guard bookmarks != session.bookmarks else { return }
        session.bookmarks = bookmarks
        currentSpread?.refreshMarks()
        flip.invalidateTextures()
    }

    /// Shows the spread starting at `location`. A chapter laid out for the first time at this size
    /// breaks its pages at the location, so that line is the first on its page.
    func show(location: ReadingLocation, animated: Bool, direction: UIPageViewController.NavigationDirection = .forward) {
        guard let chapter = session.paginatedChapter(location.spineIndex, anchor: location.textOffset) else { return }
        clearSelection()
        flip.finishNow(announce: false)
        let page = chapter.pageIndex(containing: location.textOffset)
        let spread = makeSpread(anchoredAt: PageSlot(spineIndex: location.spineIndex, page: page))
        displayedLocation = spread.location
        pager.setViewControllers([spread], direction: direction, animated: animated)
        session.prefetch(around: location.spineIndex)
    }

    /// In a spread the reading position is the right-hand page, like a book open to where you are:
    /// the left page shows what came just before it (or stays blank at the very start).
    private func makeSpread(anchoredAt page: PageSlot) -> SpreadViewController {
        guard layout.isSpread else { return makeSpread(slots: [page]) }
        if let previous = previousSlot(before: page) {
            return makeSpread(slots: [previous, page])
        }
        return makeSpread(slots: [nil, page])
    }

    private func makeSpread(slots: [PageSlot?]) -> SpreadViewController {
        SpreadViewController(session: session, slots: slots, layout: layout, palette: palette)
    }

    var currentSpread: SpreadViewController? { pager.viewControllers?.first as? SpreadViewController }

    /// The spread after or before the visible one, or nil at the end of the book.
    func adjacentSpread(forward: Bool) -> SpreadViewController? {
        guard let current = currentSpread else { return nil }
        let target = forward ? pageViewController(pager, viewControllerAfter: current)
                             : pageViewController(pager, viewControllerBefore: current)
        return target as? SpreadViewController
    }

    /// Puts `spread` in the pager without animation (the flip shows the turn, over it).
    func install(spread: SpreadViewController, location: ReadingLocation, forward: Bool) {
        displayedLocation = location
        pager.setViewControllers([spread], direction: forward ? .forward : .reverse, animated: false)
        view.layoutIfNeeded()
    }

    /// Reports a landed turn's location (saves the position) and lays out the neighbours.
    func announce(location: ReadingLocation) {
        onLocationChange?(location)
        session.prefetch(around: location.spineIndex)
    }

    // MARK: Slot arithmetic

    func nextSlot(after slot: PageSlot) -> PageSlot? {
        guard let chapter = session.paginatedChapter(slot.spineIndex) else { return nil }
        if slot.page + 1 < chapter.pageCount {
            return PageSlot(spineIndex: slot.spineIndex, page: slot.page + 1)
        }
        var next = slot.spineIndex + 1
        while next < session.chapterCount {
            if session.paginatedChapter(next) != nil { return PageSlot(spineIndex: next, page: 0) }
            next += 1
        }
        return nil
    }

    func previousSlot(before slot: PageSlot) -> PageSlot? {
        if slot.page > 0 { return PageSlot(spineIndex: slot.spineIndex, page: slot.page - 1) }
        var previous = slot.spineIndex - 1
        while previous >= 0 {
            if let chapter = session.paginatedChapter(previous) {
                return PageSlot(spineIndex: previous, page: chapter.pageCount - 1)
            }
            previous -= 1
        }
        return nil
    }

    // MARK: Data source

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let spread = viewController as? SpreadViewController, let last = spread.lastSlot else { return nil }
        var slots: [PageSlot?] = []
        var cursor = last
        for _ in 0 ..< layout.pageFrames.count {
            guard let next = nextSlot(after: cursor) else { break }
            slots.append(next)
            cursor = next
        }
        guard !slots.isEmpty else { return nil }
        while slots.count < layout.pageFrames.count { slots.append(nil) }
        return makeSpread(slots: slots)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let spread = viewController as? SpreadViewController, let first = spread.firstSlot else { return nil }
        var slots: [PageSlot?] = []
        var cursor = first
        for _ in 0 ..< layout.pageFrames.count {
            guard let previous = previousSlot(before: cursor) else { break }
            slots.insert(previous, at: 0)
            cursor = previous
        }
        guard !slots.isEmpty else { return nil }
        while slots.count < layout.pageFrames.count { slots.append(nil) }
        return makeSpread(slots: slots)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        clearSelection()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let spread = currentSpread, let location = spread.location else { return }
        displayedLocation = location
        onLocationChange?(location)
        session.prefetch(around: location.spineIndex)
    }

    // MARK: Taps

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The tap and the long press are exclusive: a tap recognises on finger-up however long
        // the hold was, and would clear the selection the press just made. Once the press begins
        // the tap is cancelled. (Not `require(toFail:)`: that would delay every page-turn tap.)
        let pair = [gestureRecognizer, otherGestureRecognizer]
        if pair.contains(where: { $0 is UITapGestureRecognizer }), pair.contains(where: { $0 is UILongPressGestureRecognizer }) {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The handles have their own pans; taps and presses on them must not reach the page.
        !(touch.view is SelectionHandleView)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        if selection != nil {
            clearSelection()
            return
        }
        if let spread = currentSpread {
            let local = view.convert(point, to: spread.view)
            if let mark = spread.mark(at: local) {
                onTap?(.annotation(id: mark.id))
                return
            }
            if let link = spread.link(at: local) {
                onTap?(.link(href: link.href, spineIndex: link.spineIndex))
                return
            }
        }
        let width = view.bounds.width
        if tapTurnsPages, point.x < width * 0.22 {
            turnPage(forward: false, from: point)
            onTap?(.previous)
        } else if tapTurnsPages, point.x > width * 0.78 {
            turnPage(forward: true, from: point)
            onTap?(.next)
        } else {
            onTap?(.center)
        }
    }

    @objc private func handleFlipPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            print("[flip] pan began; flips=\(flipsPages) scrollEnabled=\(scrollView?.isScrollEnabled ?? false)")
            clearSelection()
        }
        flip.handlePan(gesture)
    }

    /// Turns a page; `point` is where the finger was (a tap), so that corner leads the flip.
    func turnPage(forward: Bool, from point: CGPoint? = nil) {
        clearSelection()
        if flipsPages {
            flip.turn(forward: forward, from: point)
            return
        }
        guard let spread = adjacentSpread(forward: forward), let location = spread.location else { return }
        displayedLocation = location
        pager.setViewControllers([spread], direction: forward ? .forward : .reverse, animated: true) { [weak self] done in
            if done {
                self?.onLocationChange?(location)
                self?.session.prefetch(around: location.spineIndex)
            }
        }
    }

    // MARK: Selection

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let spread = currentSpread else { return }
        let point = view.convert(gesture.location(in: view), to: spread.view)
        switch gesture.state {
        case .began:
            editMenu.dismissMenu()
            guard let hit = spread.character(at: point), let chapter = session.paginatedChapter(hit.spineIndex) else {
                selectionAnchor = nil
                return
            }
            let word = chapter.wordRange(at: hit.index)
            selectionAnchor = word
            scrollView?.isScrollEnabled = false
            setSelection(TextSelection(spineIndex: hit.spineIndex, range: word))
        case .changed:
            guard let anchor = selectionAnchor, let current = selection,
                  let hit = spread.nearestCharacter(to: point, inSpine: current.spineIndex),
                  let chapter = session.paginatedChapter(current.spineIndex) else { return }
            let word = chapter.wordRange(at: hit.index)
            setSelection(TextSelection(spineIndex: current.spineIndex, range: NSUnionRange(anchor, word)))
        case .ended, .cancelled, .failed:
            scrollView?.isScrollEnabled = !flipsPages
            selectionAnchor = nil
            if gesture.state == .ended, selection != nil { presentMenu() }
        default:
            break
        }
    }

    @objc private func handleHandlePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? SelectionHandleView, let spread = currentSpread, var current = selection else { return }
        switch gesture.state {
        case .began:
            editMenu.dismissMenu()
            scrollView?.isScrollEnabled = false
        case .changed:
            let point = view.convert(gesture.location(in: view), to: spread.view)
            guard let hit = spread.nearestCharacter(to: point, inSpine: current.spineIndex) else { return }
            let end = NSMaxRange(current.range)
            if handle.isStart {
                let start = min(hit.index, end - 1)
                current.range = NSRange(location: start, length: end - start)
            } else {
                let newEnd = max(current.range.location + 1, hit.index + (hit.fraction >= 0.5 ? 1 : 0))
                current.range = NSRange(location: current.range.location, length: newEnd - current.range.location)
            }
            setSelection(current)
        case .ended, .cancelled, .failed:
            scrollView?.isScrollEnabled = !flipsPages
            if selection != nil { presentMenu() }
        default:
            break
        }
    }

    private func setSelection(_ new: TextSelection?) {
        selection = new
        currentSpread?.selection = new
        layoutHandles()
    }

    func clearSelection() {
        guard selection != nil else { return }
        editMenu.dismissMenu()
        setSelection(nil)
    }

    /// The selection's rects in this controller's view.
    private func selectionRects() -> [CGRect] {
        guard let selection, let spread = currentSpread else { return [] }
        return spread.rects(for: selection).map { spread.view.convert($0, to: view) }
    }

    private func layoutHandles() {
        let rects = selectionRects()
        guard let first = rects.first, let last = rects.last else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        startHandle.isHidden = false
        endHandle.isHidden = false
        startHandle.place(at: CGPoint(x: first.minX, y: first.minY), lineHeight: first.height)
        endHandle.place(at: CGPoint(x: last.maxX, y: last.maxY), lineHeight: last.height)
        view.bringSubviewToFront(startHandle)
        view.bringSubviewToFront(endHandle)
    }

    private func presentMenu() {
        let rects = selectionRects()
        guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { return }
        becomeFirstResponder()
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: union.midX, y: union.minY)))
    }

    /// The share sheet for a quote, as text and as a card in the reader's theme and typeface,
    /// anchored to the selection (a popover where the display is wide enough). The selection
    /// clears as it does for Copy.
    private func shareQuote(_ selection: TextSelection, text: String) {
        let rects = selectionRects()
        let anchor = rects.dropFirst().reduce(rects.first, { $0?.union($1) })
            ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        clearSelection()
        let credit = AnnotationExport.Credit(title: session.book.title, author: session.book.author,
                                             chapter: session.chapterTitle(for: selection.spineIndex))
        let started = Date()
        let sheet = QuoteShare.sheet(text: text, credit: credit, palette: palette, font: session.style?.font ?? .newYork)
        log.notice("share quote: spine \(selection.spineIndex) range \(selection.range.location)+\(selection.range.length), sheet made in \(Int(Date().timeIntervalSince(started) * 1000)) ms, presenting from \(String(describing: self.presentedViewController == nil ? "self" : "self (busy)"))")
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = anchor
        // Called once the sheet is gone, whether an activity ran or it was cancelled.
        sheet.completionWithItemsHandler = { [weak self, log] activity, completed, _, error in
            log.notice("share quote: \(activity?.rawValue ?? "dismissed") completed=\(completed) error=\(String(describing: error))")
            self?.onSystemSheet?(false)
        }
        onSystemSheet?(true)
        present(sheet, animated: true) { [log] in log.notice("share quote: sheet presented") }
    }

    private var autoSelected = false

    /// Debug: `-SheafsSelect <0…1>` selects the sentence at that fraction of the reading position's
    /// page once the book is up and opens the selection menu, as a long press would; with
    /// `-SheafsSelectThen share` it then shares it, as tapping Share would.
    private func autoSelectForScreenshots() {
        let defaults = UserDefaults.standard
        guard !autoSelected, defaults.object(forKey: "SheafsSelect") != nil else { return }
        autoSelected = true
        let fraction = min(1, max(0, defaults.double(forKey: "SheafsSelect")))
        let then = defaults.string(forKey: "SheafsSelectThen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let slot = currentSpread?.lastSlot, let chapter = session.paginatedChapter(slot.spineIndex) else { return }
            let page = chapter.range(ofPage: slot.page)
            let string = chapter.textStorage.string as NSString
            guard page.length > 0 else { return }
            let index = min(NSMaxRange(page) - 1, page.location + Int(Double(page.length) * fraction))
            var sentence = chapter.wordRange(at: index)
            string.enumerateSubstrings(in: string.paragraphRange(for: NSRange(location: index, length: 0)),
                                       options: .bySentences) { _, range, _, stop in
                if NSLocationInRange(index, range) { sentence = range; stop.pointee = true }
            }
            let visible = NSIntersectionRange(sentence, page)
            log.notice("auto select: spine \(slot.spineIndex) page \(slot.page) range \(visible.location)+\(visible.length)")
            guard visible.length > 0 else { return }
            setSelection(TextSelection(spineIndex: slot.spineIndex, range: visible))
            presentMenu()
            guard then == "share" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let (trimmed, text) = trimmedSelection() else { return }
                editMenu.dismissMenu()
                shareQuote(trimmed, text: text)
            }
        }
    }

    /// The selected text, trimmed of the whitespace a word drag may have swept in, with the
    /// selection shrunk to match.
    private func trimmedSelection() -> (TextSelection, String)? {
        guard let selection, let chapter = session.paginatedChapter(selection.spineIndex) else { return nil }
        let string = chapter.textStorage.string as NSString
        let range = NSIntersectionRange(selection.range, NSRange(location: 0, length: string.length))
        guard range.length > 0 else { return nil }
        var start = range.location, end = NSMaxRange(range)
        let blank = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = Unicode.Scalar(string.character(at: start)), blank.contains(scalar) { start += 1 }
        while end > start, let scalar = Unicode.Scalar(string.character(at: end - 1)), blank.contains(scalar) { end -= 1 }
        guard end > start else { return nil }
        let trimmed = NSRange(location: start, length: end - start)
        return (TextSelection(spineIndex: selection.spineIndex, range: trimmed), string.substring(with: trimmed))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        let rects = selectionRects()
        return rects.dropFirst().reduce(rects.first, { $0?.union($1) }) ?? .null
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let (trimmed, text) = trimmedSelection() else { return nil }
        let colour = highlightColor
        var children: [UIMenuElement] = [
            UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.clearSelection()
                self?.onSelectionAction?(.highlight(trimmed, text: text, color: colour))
            },
            UIAction(title: "Note", image: UIImage(systemName: "note.text")) { [weak self] _ in
                self?.clearSelection()
                self?.onSelectionAction?(.note(trimmed, text: text, color: colour))
            },
            UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), children: HighlightColor.allCases.map { option in
                UIAction(title: option.title, image: UIImage(systemName: "circle.fill")?.withTintColor(option.base, renderingMode: .alwaysOriginal),
                         state: option == colour ? .on : .off) { [weak self] _ in
                    self?.clearSelection()
                    self?.onSelectionAction?(.highlight(trimmed, text: text, color: option))
                }
            }),
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = text
                self?.clearSelection()
            },
        ]
        // Not for a selection of nothing but an illustration: there are no words to quote.
        if !AnnotationExport.quoteText(text).isEmpty {
            children.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.shareQuote(trimmed, text: text)
            })
        }
        if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text) {
            children.append(UIAction(title: "Look Up", image: UIImage(systemName: "character.book.closed")) { [weak self] _ in
                guard let self else { return }
                clearSelection()
                let lookUp = LookUpController(term: text)
                lookUp.onDismiss = { [weak self] in self?.onSystemSheet?(false) }
                onSystemSheet?(true)
                present(lookUp, animated: true)
            })
        }
        return UIMenu(children: children)
    }
}

/// Look Up, telling the pager when it has gone (it has no completion handler of its own).
final class LookUpController: UIReferenceLibraryViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        onDismiss?()
        onDismiss = nil
    }
}

/// An iOS-style selection handle: a knob on a stem, the knob above the line at the start and
/// below it at the end. The touch target is wider than the drawing.
final class SelectionHandleView: UIView {
    let isStart: Bool
    private let knob: CGFloat = 11
    private var lineHeight: CGFloat = 20

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts the stem on the line's edge at `point` (its top at the start, its bottom at the end).
    func place(at point: CGPoint, lineHeight: CGFloat) {
        self.lineHeight = max(12, lineHeight)
        let width: CGFloat = 44
        let height = self.lineHeight + knob + 4
        frame = CGRect(x: point.x - width / 2, y: isStart ? point.y - knob - 4 : point.y - self.lineHeight,
                       width: width, height: height)
        setNeedsDisplay()
    }

    override func tintColorDidChange() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(tintColor.cgColor)
        let x = bounds.midX
        if isStart {
            ctx.fillEllipse(in: CGRect(x: x - knob / 2, y: 0, width: knob, height: knob))
            ctx.fill(CGRect(x: x - 1, y: knob - 1, width: 2, height: bounds.height - knob + 1))
        } else {
            ctx.fill(CGRect(x: x - 1, y: 0, width: 2, height: bounds.height - knob + 1))
            ctx.fillEllipse(in: CGRect(x: x - knob / 2, y: bounds.height - knob, width: knob, height: knob))
        }
    }
}

/// One or two pages side by side.
final class SpreadViewController: UIViewController {
    let session: BookSession
    let slots: [PageSlot?]
    let layout: PageLayout
    let palette: ReaderPalette
    private(set) var pageViews: [PageView] = []
    var selection: TextSelection? {
        didSet { pushSelection() }
    }

    init(session: BookSession, slots: [PageSlot?], layout: PageLayout, palette: ReaderPalette) {
        self.session = session
        self.slots = slots
        self.layout = layout
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var firstSlot: PageSlot? { slots.compactMap { $0 }.first }
    var lastSlot: PageSlot? { slots.compactMap { $0 }.last }
    /// The reading position: the start of the right-hand (last) page of the spread.
    var location: ReadingLocation? {
        guard let last = lastSlot, let chapter = session.paginatedChapter(last.spineIndex) else { return nil }
        return ReadingLocation(spineIndex: last.spineIndex, textOffset: chapter.range(ofPage: last.page).location)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.background
        for (index, frame) in layout.pageFrames.enumerated() {
            let pageView = PageView(frame: frame)
            pageView.palette = palette
            pageView.textInsets = layout.textInsets
            pageView.camera = layout.camera?.offsetBy(dx: -frame.minX, dy: -frame.minY)
            if index < slots.count, let slot = slots[index], let chapter = session.paginatedChapter(slot.spineIndex) {
                pageView.chapter = chapter
                pageView.page = slot.page
                // Running heads like a printed book: book title on a left page, chapter on a right
                // or single page; the folio is the book-wide page number.
                let chapterTitle = session.chapterTitle(for: slot.spineIndex) ?? session.book.title
                pageView.head = (layout.isSpread && index == 0) ? session.book.title : chapterTitle
                pageView.folio = "\(session.bookPages(spineIndex: slot.spineIndex, page: slot.page).page)"
            }
            view.addSubview(pageView)
            pageViews.append(pageView)
        }
        refreshMarks()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshMarks()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (index, frame) in layout.pageFrames.enumerated() where index < pageViews.count {
            pageViews[index].frame = frame
        }
    }

    /// Gives every page the highlights of its chapter (the view keeps the ones on its page) and a
    /// ribbon when a bookmark's offset falls on it.
    func refreshMarks() {
        for (index, pageView) in pageViews.enumerated() {
            guard index < slots.count, let slot = slots[index] else { continue }
            pageView.marks = session.marks.filter { $0.spineIndex == slot.spineIndex }
            pageView.isBookmarked = pageView.chapter.map { !$0.bookmarks(session.bookmarks, onPage: slot.page).isEmpty } ?? false
        }
    }

    private func pushSelection() {
        for (index, pageView) in pageViews.enumerated() {
            guard index < slots.count, let slot = slots[index], let selection, slot.spineIndex == selection.spineIndex else {
                pageView.selection = nil
                continue
            }
            pageView.selection = selection.range
        }
    }

    /// The link under a point in this controller's view, if any.
    func link(at point: CGPoint) -> (href: String, spineIndex: Int)? {
        for (index, pageView) in pageViews.enumerated() where pageView.frame.contains(point) {
            guard index < slots.count, let slot = slots[index], let chapter = pageView.chapter else { continue }
            let local = view.convert(point, to: pageView)
            guard let characterIndex = pageView.characterIndex(at: local),
                  characterIndex < chapter.textStorage.length,
                  let href = chapter.textStorage.attribute(.sheafsLink, at: characterIndex, effectiveRange: nil) as? String else { continue }
            return (href, slot.spineIndex)
        }
        return nil
    }

    /// The highlight under a point in this controller's view, if any.
    func mark(at point: CGPoint) -> HighlightMark? {
        for pageView in pageViews where pageView.frame.contains(point) {
            return pageView.mark(at: view.convert(point, to: pageView))
        }
        return nil
    }

    /// The character under a point, when the point is over text.
    func character(at point: CGPoint) -> (spineIndex: Int, index: Int)? {
        for (index, pageView) in pageViews.enumerated() where pageView.frame.contains(point) {
            guard index < slots.count, let slot = slots[index],
                  let character = pageView.characterIndex(at: view.convert(point, to: pageView)) else { continue }
            return (slot.spineIndex, character)
        }
        return nil
    }

    /// The character of chapter `spine` nearest to a point anywhere in this view: the page under
    /// the point when it shows that chapter, otherwise the nearest such page.
    func nearestCharacter(to point: CGPoint, inSpine spine: Int) -> (index: Int, fraction: CGFloat)? {
        var candidates: [(PageView, CGFloat)] = []
        for (index, pageView) in pageViews.enumerated() {
            guard index < slots.count, let slot = slots[index], slot.spineIndex == spine else { continue }
            let dx = max(0, pageView.frame.minX - point.x, point.x - pageView.frame.maxX)
            candidates.append((pageView, dx))
        }
        guard let (pageView, _) = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        return pageView.nearestCharacter(to: view.convert(point, to: pageView))
    }

    /// The rects of a selection in this controller's view.
    func rects(for selection: TextSelection) -> [CGRect] {
        var result: [CGRect] = []
        for (index, pageView) in pageViews.enumerated() {
            guard index < slots.count, let slot = slots[index], slot.spineIndex == selection.spineIndex else { continue }
            result += pageView.rects(for: selection.range).map { pageView.convert($0, to: view) }
        }
        return result
    }
}
