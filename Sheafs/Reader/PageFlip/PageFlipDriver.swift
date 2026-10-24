import Metal
import UIKit
import os

/// Runs page turns as flips: builds the scene for a turn (the leaf's pages as textures, what
/// lies beneath), follows the finger or lets the leaf fall on a spring, and hands the pager the
/// destination spread when the leaf has landed. One turn is in flight at a time; a new request
/// finishes the current one on the spot.
final class PageFlipDriver: NSObject {
    private unowned let host: PagerController
    private var flipView: PageFlipView?
    private var textures: [PageSlot: MTLTexture] = [:]
    private var turn: Turn?
    private var displayLink: CADisplayLink?
    /// Debug: launch with `-SheafsFlipFreeze 0.4` to hold every tap turn at that amount (for
    /// screenshots); the next tap completes it.
    private let freeze = UserDefaults.standard.string(forKey: "SheafsFlipFreeze").flatMap(Double.init)
    private let log = Logger(subsystem: "io.sheafs.reader", category: "flip")

    struct Turn {
        /// The spread the turn started from, put back if the leaf falls back.
        let origin: SpreadViewController
        let originLocation: ReadingLocation
        let destination: SpreadViewController
        let location: ReadingLocation
        let forward: Bool
        /// A leaf lifting off its page runs 0 → 1; one falling back onto it (previous page on
        /// a single display) runs 1 → 0.
        let reversed: Bool
        var scene: FlipScene
        var amount: Double
        var grabY: CGFloat
        var spring: FlipSpring?
        var tracking = false
        var fingerStartX: CGFloat = 0
        /// The destination spread has been put in the pager, under the opaque leaf.
        var installed = false

        var width: Double { Double(scene.leafFrame.width) }
        var restingAmount: Double { reversed ? 1 : 0 }
        var landedAmount: Double { reversed ? 0 : 1 }
    }

    init(host: PagerController) {
        self.host = host
        super.init()
    }

    /// False when Metal is unavailable; the pager then slides.
    var isSupported: Bool { ensureView() != nil }
    var isActive: Bool { turn != nil }

    /// Page textures are keyed by slot; a new layout, palette or style makes new pages.
    func invalidateTextures() { textures.removeAll() }

    // MARK: Turning

    /// Starts an animated turn (a tap or a button). Returns false when there is no page that way.
    @discardableResult
    func turn(forward: Bool, from point: CGPoint?) -> Bool {
        finishNow()
        guard var turn = prepare(forward: forward, grabY: point?.y) else { return false }
        if let freeze {
            turn.amount = turn.reversed ? 1 - freeze : freeze
            present(turn)
            return true
        }
        // A tap flicks the leaf: it leaves with some speed and the spring carries it over.
        let kick = turn.reversed ? -2.4 : 2.4
        turn.spring = FlipSpring(value: turn.amount, velocity: kick, target: turn.landedAmount)
        present(turn)
        startDisplayLink()
        return true
    }

    func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let view = host.viewIfLoaded else { return }
        let finger = pan.location(in: view)
        let translation = pan.translation(in: view)
        print("[flip] pan state=\(pan.state.rawValue) at \(Int(finger.x)),\(Int(finger.y)) translation \(Int(translation.x)),\(Int(translation.y)) active=\(turn != nil)")
        switch pan.state {
        case .began, .changed:
            if var turn, turn.tracking {
                turn.amount = amount(for: turn, fingerX: finger.x)
                turn.grabY = finger.y
                present(turn)
                return
            }
            // On a device the pan often begins with no translation at all; the direction comes
            // from the first event that has some. A finger rarely starts dead level, so only a
            // clearly vertical pull is not a turn.
            guard translation != .zero else { return }
            guard abs(translation.x) * 2 >= abs(translation.y) else {
                print("[flip] pan ignored: vertical")
                pan.isEnabled = false
                pan.isEnabled = true
                return
            }
            finishNow()
            guard var turn = prepare(forward: translation.x < 0, grabY: finger.y) else {
                print("[flip] pan: no page \(translation.x < 0 ? "forward" : "backward")")
                pan.isEnabled = false
                pan.isEnabled = true
                return
            }
            turn.tracking = true
            turn.fingerStartX = finger.x - translation.x
            turn.amount = amount(for: turn, fingerX: finger.x)
            present(turn)
        case .ended, .cancelled, .failed:
            guard var turn, turn.tracking else { return }
            turn.tracking = false
            // The leaf keeps the finger's speed; where it would be a moment later decides whether
            // it goes over or falls back.
            let rate = -Double(turn.scene.flip * pan.velocity(in: view).x) / (2 * turn.width)
            let projected = turn.amount + rate * 0.22
            let completes = turn.reversed ? projected <= 0.72 : projected >= 0.28
            let target = completes ? turn.landedAmount : turn.restingAmount
            print("[flip] pan released at \(turn.amount) rate \(rate) → \(completes ? "lands" : "falls back")")
            turn.spring = FlipSpring(value: turn.amount, velocity: max(-8, min(8, rate)), target: target)
            self.turn = turn
            startDisplayLink()
        default:
            break
        }
    }

    /// Ends the turn in flight without animation: a leaf already on its way over lands, a leaf
    /// still under the finger falls back. `announce` false when the caller is about to show a
    /// location of its own (a jump), so the landed one is not reported over it.
    func finishNow(announce: Bool = true) {
        guard let turn else { return }
        stopDisplayLink()
        let landing: Bool
        if turn.tracking {
            landing = false
        } else if let spring = turn.spring {
            landing = spring.target == turn.landedAmount
        } else {
            landing = true // frozen for a screenshot
        }
        finish(turn, landed: landing, announce: announce ? .now : .never)
    }

    // MARK: Scene

    private func ensureView() -> PageFlipView? {
        if let flipView { return flipView }
        guard let hostView = host.viewIfLoaded, let view = PageFlipView.make(frame: hostView.bounds) else { return nil }
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isHidden = true
        hostView.insertSubview(view, aboveSubview: host.pagerView)
        flipView = view
        return view
    }

    /// The scene for a turn: which page is the leaf, what is printed on its back, and what lies
    /// beneath on each side. A spread turns like a book: the leaf's back is the page that lands
    /// face up on the other side. A single display is a pad of sheets printed on one side.
    private func prepare(forward: Bool, grabY: CGFloat?) -> Turn? {
        guard let flipView = ensureView(), let current = host.currentSpread, let originLocation = current.location,
              let destination = host.adjacentSpread(forward: forward), let location = destination.location else { return nil }
        let started = CFAbsoluteTimeGetCurrent()
        destination.loadViewIfNeeded()
        let layout = host.layout
        let frames = layout.pageFrames
        guard !frames.isEmpty else { return nil }
        func texture(_ spread: SpreadViewController, _ index: Int) -> MTLTexture? {
            guard index < spread.pageViews.count, index < spread.slots.count, let slot = spread.slots[index] else { return nil }
            if let cached = textures[slot] { return cached }
            if textures.count >= 8 { textures.removeAll() }
            let made = flipView.makeTexture(for: spread.pageViews[index])
            textures[slot] = made
            return made
        }
        let palette = host.palette
        let scene: FlipScene
        let reversed: Bool
        if layout.isSpread {
            // The leaf is hinged at the spine, the centre of the gutter, and reaches the page's outer
            // edge; the half gutter next to the spine is blank margin on both faces. Turned over it
            // covers the facing page exactly.
            let gap = frames[1].minX - frames[0].maxX
            let spine = frames[0].maxX + gap / 2
            let inset = gap / 2
            if forward {
                let leaf = CGRect(x: spine, y: frames[1].minY, width: frames[1].maxX - spine, height: frames[1].height)
                scene = FlipScene(leafFrame: leaf, hinge: spine, flip: 1, inset: inset,
                                  front: texture(current, 1), back: texture(destination, 0), ghostBack: false,
                                  under: [(frames[0], texture(current, 0)), (frames[1], texture(destination, 1))],
                                  palette: palette)
            } else {
                let leaf = CGRect(x: frames[0].minX, y: frames[0].minY, width: spine - frames[0].minX, height: frames[0].height)
                scene = FlipScene(leafFrame: leaf, hinge: spine, flip: -1, inset: inset,
                                  front: texture(current, 0), back: texture(destination, 1), ghostBack: false,
                                  under: [(frames[1], texture(current, 1)), (frames[0], texture(destination, 0))],
                                  palette: palette)
            }
            reversed = false
        } else if forward {
            scene = FlipScene(leafFrame: frames[0], hinge: frames[0].minX, flip: 1, inset: 0,
                              front: texture(current, 0), back: nil, ghostBack: true,
                              under: [(frames[0], texture(destination, 0))], palette: palette)
            reversed = false
        } else {
            scene = FlipScene(leafFrame: frames[0], hinge: frames[0].minX, flip: 1, inset: 0,
                              front: texture(destination, 0), back: nil, ghostBack: true,
                              under: [(frames[0], texture(current, 0))], palette: palette)
            reversed = true
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        log.debug("prepared \(forward ? "forward" : "backward") turn in \(ms, format: .fixed(precision: 1)) ms")
        return Turn(origin: current, originLocation: originLocation, destination: destination, location: location,
                    forward: forward, reversed: reversed, scene: scene, amount: reversed ? 1 : 0,
                    grabY: grabY ?? scene.leafFrame.midY)
    }

    /// The finger carries the free edge: it is wherever it rested plus the finger's travel.
    private func amount(for turn: Turn, fingerX: CGFloat) -> Double {
        let width = turn.width
        let rest = turn.reversed ? -width : width
        let edge = rest + Double(turn.scene.flip * (fingerX - turn.fingerStartX))
        return min(1, max(0, (width - edge) / (2 * width)))
    }

    private func present(_ turn: Turn) {
        self.turn = turn
        guard let flipView else { return }
        let frame = turn.scene.leafFrame
        let curl = PageCurl.solve(amount: turn.amount, width: turn.width)
        let grab = frame.height > 0 ? Double((turn.grabY - frame.minY) / frame.height) : 0.5
        let wasHidden = flipView.isHidden
        flipView.scene = turn.scene
        flipView.curl = curl
        flipView.tilt = CGFloat(PageCurl.tilt(amount: turn.amount, grab: grab, flat: curl.flat, height: Double(frame.height)))
        flipView.grabY = turn.grabY
        if wasHidden {
            flipView.isHidden = false
            flipView.draw()
            // The destination goes into the pager now, under the opaque leaf, so its pages are
            // drawn while the leaf is in the air and landing is nothing but uncovering them.
            DispatchQueue.main.async { [weak self] in self?.installDestination() }
        } else {
            flipView.setNeedsDisplay()
        }
    }

    private func installDestination() {
        guard var turn, !turn.installed else { return }
        host.install(spread: turn.destination, location: turn.location, forward: turn.forward)
        turn.installed = true
        self.turn = turn
    }

    enum Announce { case never, now, afterLanding }

    /// Uncovers the pager. Landed: the destination is in place (installed now if the turn was
    /// cut short) and the new location is announced, by default a frame later so the save and
    /// the neighbours' pagination never land in the leaf's last frame. Fell back: the origin
    /// spread goes back in.
    private func finish(_ turn: Turn, landed: Bool, announce: Announce) {
        if landed {
            if !turn.installed { host.install(spread: turn.destination, location: turn.location, forward: turn.forward) }
        } else if turn.installed {
            host.install(spread: turn.origin, location: turn.originLocation, forward: !turn.forward)
        }
        flipView?.isHidden = true
        self.turn = nil
        guard landed else { return }
        switch announce {
        case .never: break
        case .now: host.announce(location: turn.location)
        case .afterLanding:
            DispatchQueue.main.async { [weak self] in self?.host.announce(location: turn.location) }
        }
    }

    // MARK: Animation

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard var turn, var spring = turn.spring, !turn.tracking else {
            stopDisplayLink()
            return
        }
        spring.step(max(0.001, link.targetTimestamp - link.timestamp))
        turn.spring = spring
        let overshot = (spring.target == 1 && spring.value >= 1) || (spring.target == 0 && spring.value <= 0)
        if spring.isSettled || overshot {
            stopDisplayLink()
            turn.amount = spring.target
            present(turn)
            finish(turn, landed: spring.target == turn.landedAmount, announce: .afterLanding)
        } else {
            turn.amount = min(1, max(0, spring.value))
            present(turn)
        }
    }
}
