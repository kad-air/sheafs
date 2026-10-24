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
}

/// Hosts a `UIPageViewController` whose units are spreads of one or two pages.
struct ReaderPager: UIViewControllerRepresentable {
    let session: BookSession
    let layout: PageLayout
    let style: TypesetStyle
    let palette: ReaderPalette
    let location: ReadingLocation
    let tapTurnsPages: Bool
    let proxy: PagerProxy
    var onLocationChange: (ReadingLocation) -> Void
    var onTap: (ReaderTap) -> Void

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
        controller.tapTurnsPages = tapTurnsPages
        session.configure(style: style, textSize: layout.textSize)
        controller.apply(layout: layout, palette: palette, location: location, animated: false)
    }
}

final class PagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    let session: BookSession
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                             options: [.interPageSpacing: 0])
    private(set) var layout = PageLayout(pageFrames: [], textInsets: .zero, deckFrame: nil)
    private(set) var palette = ReaderPalette.paper
    /// The location of the first page of the visible spread.
    private(set) var displayedLocation: ReadingLocation?
    var onLocationChange: ((ReadingLocation) -> Void)?
    var onTap: ((ReaderTap) -> Void)?
    var tapTurnsPages = true
    /// The style generation the visible spread was built with; a change re-lays out at the same place.
    private var appliedStyle: TypesetStyle?

    init(session: BookSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        disableInsetAdjustment()
    }

    /// The page layout already accounts for safe areas; UIKit must not shift the pages again when
    /// the bars appear (otherwise every chrome toggle moves the text). The page controller's
    /// scroll view is created lazily, so this runs on every layout pass.
    private func disableInsetAdjustment() {
        pager.view.subviews.compactMap { $0 as? UIScrollView }.forEach { scrollView in
            if scrollView.contentInsetAdjustmentBehavior != .never {
                scrollView.contentInsetAdjustmentBehavior = .never
            }
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
        guard session.isReady, !layout.pageFrames.isEmpty, session.style != nil else { return }
        appliedStyle = session.style
        if layoutChanged || paletteChanged || styleChanged || displayedLocation == nil || displayedLocation != location {
            show(location: location, animated: animated && !layoutChanged)
        }
    }

    /// Shows the spread starting at `location`. A chapter laid out for the first time at this size
    /// breaks its pages at the location, so that line is the first on its page.
    func show(location: ReadingLocation, animated: Bool, direction: UIPageViewController.NavigationDirection = .forward) {
        guard let chapter = session.paginatedChapter(location.spineIndex, anchor: location.textOffset) else { return }
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
        let spread = SpreadViewController(session: session, slots: slots, layout: layout, palette: palette)
        return spread
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

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let spread = pager.viewControllers?.first as? SpreadViewController,
              let location = spread.location else { return }
        displayedLocation = location
        onLocationChange?(location)
        session.prefetch(around: location.spineIndex)
    }

    // MARK: Taps

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        if let spread = pager.viewControllers?.first as? SpreadViewController,
           let link = spread.link(at: view.convert(point, to: spread.view)) {
            onTap?(.link(href: link.href, spineIndex: link.spineIndex))
            return
        }
        let width = view.bounds.width
        if tapTurnsPages, point.x < width * 0.22 {
            turnPage(forward: false)
            onTap?(.previous)
        } else if tapTurnsPages, point.x > width * 0.78 {
            turnPage(forward: true)
            onTap?(.next)
        } else {
            onTap?(.center)
        }
    }

    func turnPage(forward: Bool) {
        guard let current = pager.viewControllers?.first else { return }
        let target = forward ? pageViewController(pager, viewControllerAfter: current)
                             : pageViewController(pager, viewControllerBefore: current)
        guard let spread = target as? SpreadViewController, let location = spread.location else { return }
        displayedLocation = location
        pager.setViewControllers([spread], direction: forward ? .forward : .reverse, animated: true) { [weak self] done in
            if done {
                self?.onLocationChange?(location)
                self?.session.prefetch(around: location.spineIndex)
            }
        }
    }
}

/// One or two pages side by side.
final class SpreadViewController: UIViewController {
    let session: BookSession
    let slots: [PageSlot?]
    let layout: PageLayout
    let palette: ReaderPalette
    private var pageViews: [PageView] = []

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
            pageView.occlusions = layout.occlusions.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (index, frame) in layout.pageFrames.enumerated() where index < pageViews.count {
            pageViews[index].frame = frame
        }
    }

    /// The link under a point in this controller's view, if any.
    func link(at point: CGPoint) -> (href: String, spineIndex: Int)? {
        for (index, pageView) in pageViews.enumerated() where pageView.frame.contains(point) {
            guard index < slots.count, let slot = slots[index], let chapter = pageView.chapter else { continue }
            let local = view.convert(point, to: pageView)
            guard let characterIndex = pageView.characterIndex(at: local),
                  characterIndex < chapter.textStorage.length,
                  let href = chapter.textStorage.attribute(.link, at: characterIndex, effectiveRange: nil) as? String else { continue }
            return (href, slot.spineIndex)
        }
        return nil
    }
}
