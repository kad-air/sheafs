import SwiftUI
import UIKit

/// The Input Debug screen's capture surface, under everything else on the screen (the toolbar,
/// the tag picker and the toggles sit above it and take their own touches; the log lets touches
/// through unless paused). It holds first responder for presses, offers priority key commands,
/// and logs raw touches and every gesture the remote might synthesize.
struct InputCaptureView: UIViewControllerRepresentable {
    let session: InputDebugSession

    func makeUIViewController(context: Context) -> InputCaptureController {
        InputCaptureController(session: session)
    }

    func updateUIViewController(_ controller: InputCaptureController, context: Context) {}
}

final class InputCaptureController: UIViewController, UIGestureRecognizerDelegate {
    private let session: InputDebugSession
    private var log: InputDebugLog { session.log }
    /// Live touches by identity: their number in the log and their coalesced moves.
    private var touches: [ObjectIdentifier: (number: Int, tally: MoveTally)] = [:]
    private var touchCount = 0
    private var panStart: TimeInterval = 0
    private var longPressStart: TimeInterval = 0
    private var lastHoverRow: TimeInterval = 0
    private var inWindow = false

    init(session: InputDebugSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let view = WindowWatchingView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        view.onWindowChange = { [weak self] window in self?.windowChanged(window) }
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedScrollTypesMask = .all
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        var recognizers: [UIGestureRecognizer] = [tap, doubleTap, longPress, pan, hover]
        for direction in [UISwipeGestureRecognizer.Direction.up, .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            recognizers.append(swipe)
        }
        for recognizer in recognizers {
            // Every recognizer sees every touch, and none cancels or delays the raw touches.
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            view.addGestureRecognizer(recognizer)
        }
    }

    private func windowChanged(_ window: UIWindow?) {
        inWindow = window != nil
        if inWindow {
            session.start(host: view)
            // Next turn: SwiftUI may still be settling its own responders.
            DispatchQueue.main.async { [weak self] in self?.takeFirstResponder(reason: "appeared") }
        } else {
            session.stop()
            if isFirstResponder { _ = resignFirstResponder() }
        }
    }

    // MARK: First responder

    override var canBecomeFirstResponder: Bool { true }

    /// Done was tapped: the screen is on its way out, so losing first responder is expected.
    private var isLeaving: Bool {
        sequence(first: self as UIViewController, next: \.parent).contains { $0.isBeingDismissed || $0.isMovingFromParent }
    }

    private func takeFirstResponder(reason: String) {
        guard inWindow, !isLeaving, !isFirstResponder else { return }
        let took = becomeFirstResponder()
        session.isFirstResponder = isFirstResponder
        log.add(.note, "first responder \(took ? "taken" : "REFUSED") (\(reason))")
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        session.isFirstResponder = isFirstResponder
        if resigned, inWindow, !isLeaving {
            log.add(.note, "first responder lost; taking it back")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.takeFirstResponder(reason: "regained")
            }
        }
        return resigned
    }

    // MARK: Presses (hardware keys)

    // Only the priority keys are passed on to super (with Priority keys on), where this
    // controller's own key commands take them: a key command fires only for a press the press
    // handlers pass on (seen on the simulator). Everything else is swallowed, so no key reaches
    // SwiftUI (Escape could press Done) or navigates away.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        logPresses("began", presses)
        passOn(presses) { super.pressesBegan($0, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        logPresses("changed", presses)
        passOn(presses) { super.pressesChanged($0, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        logPresses("ended", presses)
        passOn(presses) { super.pressesEnded($0, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        logPresses("cancelled", presses)
        passOn(presses) { super.pressesCancelled($0, with: event) }
    }

    /// The presses a priority key command will take: no modifiers, one of `priorityInputs`.
    private func passOn(_ presses: Set<UIPress>, to next: (Set<UIPress>) -> Void) {
        guard session.priorityKeys else { return }
        let taken = presses.filter { press in
            guard let key = press.key, key.modifierFlags.isEmpty else { return false }
            return Self.priorityInputs.contains(key.charactersIgnoringModifiers)
        }
        if !taken.isEmpty { next(taken) }
    }

    private func logPresses(_ phase: String, _ presses: Set<UIPress>) {
        for press in presses {
            var parts = ["\(phase) type=\(InputNames.pressType(press.type.rawValue))"]
            if let key = press.key {
                parts.append("key=\(InputNames.keyLabel(key.keyCode.rawValue))")
                parts.append("chars=\(InputNames.visible(key.characters))")
                if key.charactersIgnoringModifiers != key.characters {
                    parts.append("ign=\(InputNames.visible(key.charactersIgnoringModifiers))")
                }
                parts.append("mods=\(InputNames.modifiers(key.modifierFlags))")
            } else {
                parts.append("key=nil")
            }
            if press.force > 0 { parts.append(String(format: "force=%.2f", press.force)) }
            log.add(.press, parts.joined(separator: " "))
        }
    }

    // MARK: Key commands (priority over system behaviour)

    /// Arrows, space, return, escape, page up/down, home/end and tab, each asking to come before
    /// the system's own use of the key (focus, text input, scrolling), so a `keycmd` row shows the
    /// input a `UIKeyCommand` would match. Off: presses only.
    override var keyCommands: [UIKeyCommand]? {
        guard session.priorityKeys else { return nil }
        return Self.priorityInputs.map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(keyCommandFired(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    private static let priorityInputs = [
        UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
        UIKeyCommand.inputRightArrow, " ", "\r", "\t", UIKeyCommand.inputEscape, UIKeyCommand.inputPageUp,
        UIKeyCommand.inputPageDown, UIKeyCommand.inputHome, UIKeyCommand.inputEnd,
    ]

    @objc private func keyCommandFired(_ command: UIKeyCommand) {
        log.add(.keyCommand, "input=\(InputNames.visible(command.input ?? "")) mods=\(InputNames.modifiers(command.modifierFlags))")
    }

    // MARK: Touches (raw)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchCount += 1
            let point = touch.location(in: view)
            self.touches[ObjectIdentifier(touch)] = (touchCount, MoveTally(start: point, at: touch.timestamp))
            log.add(.touch, "#\(touchCount) began \(InputNames.touchType(touch.type.rawValue)) at \(InputNames.point(point)) taps=\(touch.tapCount) force=\(String(format: "%.2f", touch.force)) radius=\(String(format: "%.1f", touch.majorRadius))")
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            self.touches[ObjectIdentifier(touch)]?.tally.move(to: touch.location(in: view))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches, "ended") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches, "cancelled") }

    private func endTouches(_ touches: Set<UITouch>, _ phase: String) {
        for touch in touches {
            guard var track = self.touches.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            track.tally.move(to: touch.location(in: view))
            log.add(.touch, "#\(track.number) \(phase) \(InputNames.touchType(touch.type.rawValue)) \(track.tally.summary(at: touch.timestamp)) taps=\(touch.tapCount)")
        }
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        log.add(.gesture, "tap at \(InputNames.point(recognizer.location(in: view))) touches=\(recognizer.numberOfTouches)")
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        log.add(.gesture, "double tap at \(InputNames.point(recognizer.location(in: view)))")
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        let now = ProcessInfo.processInfo.systemUptime
        switch recognizer.state {
        case .began:
            longPressStart = now
            log.add(.gesture, "long press began at \(InputNames.point(recognizer.location(in: view)))")
        case .ended, .cancelled, .failed:
            log.add(.gesture, "long press \(Self.name(recognizer.state)) after \(Int(((now - longPressStart) * 1000).rounded()))ms")
        default: break
        }
    }

    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        let direction = switch recognizer.direction {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        default: "?"
        }
        log.add(.gesture, "swipe \(direction) at \(InputNames.point(recognizer.location(in: view)))")
    }

    /// Begin and end only (the end with the total translation): a scroll wheel or trackpad pan has
    /// no touches.
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let now = ProcessInfo.processInfo.systemUptime
        let kind = recognizer.numberOfTouches == 0 ? "scroll" : "pan"
        switch recognizer.state {
        case .began:
            panStart = now
            log.add(.gesture, "\(kind) began at \(InputNames.point(recognizer.location(in: view))) touches=\(recognizer.numberOfTouches)")
        case .ended, .cancelled, .failed:
            let t = recognizer.translation(in: view), v = recognizer.velocity(in: view)
            log.add(.gesture, "pan \(Self.name(recognizer.state)) Δ\(InputNames.delta(dx: t.x, dy: t.y)) velocity=\(InputNames.delta(dx: v.x, dy: v.y)) \(Int(((now - panStart) * 1000).rounded()))ms")
        default: break
        }
    }

    /// Pointer hover: begin, end, and the position at most every 250 ms in between.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let now = ProcessInfo.processInfo.systemUptime
        let point = InputNames.point(recognizer.location(in: view))
        switch recognizer.state {
        case .began:
            lastHoverRow = now
            log.add(.gesture, "hover began at \(point)")
        case .changed where now - lastHoverRow >= 0.25:
            lastHoverRow = now
            log.add(.gesture, "hover at \(point)")
        case .ended, .cancelled:
            log.add(.gesture, "hover \(Self.name(recognizer.state)) at \(point)")
        default: break
        }
    }

    private static func name(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        default: "state\(state.rawValue)"
        }
    }
}

/// Tells its controller when it enters or leaves a window: the session starts and stops there
/// (more dependable than a representable's appearance calls).
private final class WindowWatchingView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}
