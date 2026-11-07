import SwiftUI
import UIKit
import os

/// How long the screen stays on after the last page turn or touch while a book is open
/// (`ReaderSettings.screenAwake`). After that the system's Auto-Lock takes over again, so a book
/// left open on the table goes dark instead of staying lit until the battery runs out.
enum ScreenAwakeWindow: Int, CaseIterable, Identifiable {
    /// The system's Auto-Lock decides, as in any other app.
    case off = 0
    case twoMinutes = 2
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30

    static let standard = ScreenAwakeWindow.fiveMinutes

    var id: Self { self }
    /// Seconds the screen stays on after the last turn or touch; nil for `.off`.
    var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue * 60) }
    var title: String { self == .off ? "Off" : "\(rawValue) min" }
}

/// Holds the screen on while the reader is in use and lets it sleep once the pages stop turning.
///
/// `UIApplication.isIdleTimerDisabled` held true for as long as a book was open kept the screen lit
/// for hours after the reader put the phone down. Now every page turn and every touch (`activity`)
/// holds it on for `window` seconds; when that passes with neither, the flag goes back to false and
/// the system's Auto-Lock dims and locks the screen as usual (so the screen goes dark `window` plus
/// the Auto-Lock time after the last turn). Nothing here locks the screen itself: there is no
/// public API for that, and the user's Auto-Lock is theirs.
///
/// Activities only record the time; the one pending check reschedules itself to the latest
/// deadline, so a touch costs a `Date`, not a new timer.
@MainActor
final class ScreenAwake {
    /// Seconds the screen stays on after the last activity; nil when the system decides.
    private(set) var window: TimeInterval?
    /// The idle timer is off (the screen held on) because of us.
    private(set) var isHolding = false
    private(set) var lastActivity: Date?
    private var pending: Task<Void, Never>?
    private let setIdleTimerDisabled: (Bool) -> Void
    /// Schedules a check; false in tests, which call `check(at:)` themselves.
    private let schedules: Bool

    init(setIdleTimerDisabled: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
         schedules: Bool = true) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
        self.schedules = schedules
    }

    /// Starts (or restarts) with `window` seconds, counting from now; nil lets the system decide.
    func start(window: TimeInterval?, reason: String, at now: Date = .now) {
        self.window = window
        cancelCheck()
        if let window {
            note("window \(Int(window)) s (\(reason))")
            activity(reason, at: now)
        } else {
            note("off (\(reason)): the system's Auto-Lock decides")
            lastActivity = nil
            hold(false, reason: reason)
        }
    }

    /// A page turn, a touch, the app coming back: the screen stays on for another `window`.
    func activity(_ reason: String, at now: Date = .now) {
        guard let window else { return }
        note("activity: \(reason)")
        lastActivity = now
        if !isHolding { hold(true, reason: reason) }
        if pending == nil { schedule(after: window) }
    }

    /// Lets the screen sleep if `window` has passed since the last activity; else checks again at
    /// the new deadline.
    func check(at now: Date = .now) {
        pending = nil
        guard let window, let lastActivity, isHolding else { return }
        let left = lastActivity.addingTimeInterval(window).timeIntervalSince(now)
        if left <= 0.05 {
            hold(false, reason: "no page turn or touch for \(Int(now.timeIntervalSince(lastActivity))) s")
        } else {
            schedule(after: left)
        }
    }

    /// The reader closed: the idle timer goes back to the system for the rest of the app.
    func stop(reason: String) {
        cancelCheck()
        lastActivity = nil
        window = nil
        hold(false, reason: reason)
    }

    private func hold(_ on: Bool, reason: String) {
        isHolding = on
        setIdleTimerDisabled(on)
        if schedules {
            // Read back from UIKit: what the system was actually told.
            note("idle timer \(on ? "OFF, screen held on" : "ON, Auto-Lock decides") (\(reason));"
                 + " isIdleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled)")
        }
    }

    private func schedule(after seconds: TimeInterval) {
        cancelCheck()
        guard schedules else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    private func cancelCheck() {
        pending?.cancel()
        pending = nil
    }

    /// stdout (`simctl launch --console-pty`, `devicectl … --console`) and the unified log, where
    /// `scripts/check-screen-awake` times it against SpringBoard's own idle-timer lines.
    private func note(_ message: String) {
        guard schedules else { return }
        print("[awake] \(message)")
        Self.log.notice("[awake] \(message, privacy: .public)")
    }

    private static let log = Logger(subsystem: "io.sheafs.reader", category: "awake")
}

/// Reports every touch that begins in the window it is in, without taking part in it: a gesture
/// recognizer on the WINDOW that fails at once, so the reader's sheets and panels (presented in the
/// same window) count as use too, and no other gesture waits for it or loses its touches.
struct TouchActivityReader: UIViewRepresentable {
    var onTouch: () -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) { view.witness.onTouch = onTouch }

    final class Probe: UIView {
        let witness = TouchWitness()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if witness.view !== window {
                witness.view?.removeGestureRecognizer(witness)
                window?.addGestureRecognizer(witness)
            }
        }

        override func removeFromSuperview() {
            witness.view?.removeGestureRecognizer(witness)
            super.removeFromSuperview()
        }
    }

    final class TouchWitness: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onTouch: (() -> Void)?

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch?()
            state = .failed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
