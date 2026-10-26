import AVFoundation
import MediaPlayer
import UIKit
import os

/// Turns pages with the volume buttons: up = next page, down = previous (`Press.turnsForward`; the
/// owner's choice, the reverse of Kindle and Readest).
///
/// iOS has no public volume-button event outside a camera session (`AVCaptureEventInteraction` is
/// delivered only to apps actively using the camera), so this is the usual trick, the one Readest
/// uses too: an active audio session makes `outputVolume` observable, every press is a step from
/// the last reading (`PressReader`), and a hidden `MPVolumeView`'s slider puts the volume straight
/// back after EVERY press, so the level is back where it was within a few milliseconds and the
/// system volume HUD stays away (an `MPVolumeView` on screen suppresses it). The session is
/// `.playback` + `.mixWithOthers`: nothing is played, and other apps' audio keeps going. On stop
/// the user's volume is restored and the session deactivated. The approach is credited in the
/// README; Readest is AGPL, so its code must not be copied into this MIT tree.
final class VolumeButtonPager {
    enum Press: Equatable {
        case up, down

        /// Volume up turns to the next page.
        nonisolated var turnsForward: Bool {
            switch self {
            case .up: true
            case .down: false
            }
        }
    }

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var originalVolume: Float = 0.5
    private var reader = PressReader(previous: 0.5, reference: 0.5)
    private var onPress: ((Press) -> Void)?
    private(set) var isRunning = false

    /// The volume view's slider: searched for in its subtree each time, else the one it had when it
    /// was made (Readest keeps that one, which works on devices). On the iOS 27.1 simulator the
    /// view swaps its slider for a label once it is in a window (no volume route there); the
    /// `[volume] view made / start` lines log the tree both times, to see what a device does.
    private var slider: UISlider? { volumeView.flatMap(Self.firstSlider(in:)) ?? madeSlider }
    private var madeSlider: UISlider?

    /// The volume view's subview classes, nested, for the log.
    private static func tree(_ view: UIView) -> String {
        let children = view.subviews.map(tree).joined(separator: ", ")
        return String(describing: type(of: view)) + (children.isEmpty ? "" : "[\(children)]")
    }

    private static func firstSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider ?? firstSlider(in: subview) { return slider }
        }
        return nil
    }

    /// Starts listening; the hidden volume view goes into `host`'s window.
    func start(host: UIView, onPress: @escaping (Press) -> Void) {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            VolumeLog.shared.note("audio session failed: \(error.localizedDescription)")
            return
        }
        self.onPress = onPress
        isRunning = true
        // On screen and all but transparent: on iOS 27 (iPhone Duo, build 7) an off-screen volume
        // view no longer kept the system volume HUD away.
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        (host.window ?? host).addSubview(view)
        volumeView = view
        madeSlider = Self.firstSlider(in: view)
        VolumeLog.shared.note("view made: \(Self.tree(view))")
        // outputVolume is only current a moment after the session activates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, isRunning else { return }
            originalVolume = session.outputVolume
            let reference = PressReader.reference(for: originalVolume)
            reader = PressReader(previous: originalVolume, reference: reference)
            VolumeLog.shared.note("start: category=\(session.category.rawValue) otherAudio=\(session.isOtherAudioPlaying) volume=\(self.originalVolume) reference=\(reference) slider=\(self.slider != nil) view=\(self.volumeView.map(Self.tree) ?? "nil")")
            observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let volume = change.newValue else { return }
                DispatchQueue.main.async { self?.volumeChanged(volume) }
            }
            putBack()
            probeIfAsked()
        }
    }

    /// Debug: `-SheafsVolumeProbe up,down,…` moves the volume one step through the slider for each
    /// entry, `-SheafsVolumeProbeGap` seconds apart (0.8 by default), starting 1.5 s after arming:
    /// what a button press does, for the simulator (which has no volume buttons, and no volume
    /// route, so there it changes nothing) and for `scripts/check-volume-device` on a phone.
    private func probeIfAsked() {
        let defaults = UserDefaults.standard
        guard let list = defaults.string(forKey: "SheafsVolumeProbe") else { return }
        let steps = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let gap = defaults.object(forKey: "SheafsVolumeProbeGap").map { _ in defaults.double(forKey: "SheafsVolumeProbeGap") } ?? 0.8
        for (index, direction) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + gap * Double(index)) { [weak self] in
                guard let self, isRunning else { return }
                // From the reference, where every put-back leaves the volume; 1/16 is iOS's nominal
                // step, and the device rounds it onto its own grid like a press.
                let target = reader.reference + (direction == "up" ? 0.0625 : -0.0625)
                VolumeLog.shared.note("probe \(index + 1)/\(steps.count) \(direction): slider=\(self.slider != nil) → \(target)")
                slider?.value = target
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observation?.invalidate()
        observation = nil
        VolumeLog.shared.note("stop: restoring volume=\(self.originalVolume)")
        slider?.value = originalVolume
        let view = volumeView
        volumeView = nil
        madeSlider = nil
        onPress = nil
        // Let the slider's restore reach the system before the view (and the session) go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            view?.removeFromSuperview()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func volumeChanged(_ volume: Float) {
        guard isRunning else { return }
        let press = reader.read(volume, at: ProcessInfo.processInfo.systemUptime)
        VolumeLog.shared.note("outputVolume=\(volume) press=\(press.map { "\($0)" } ?? "none") reference=\(self.reader.reference)")
        guard let press else { return }
        putBack()
        onPress?(press)
    }

    /// Puts the volume back to the reference, after every press (and at the start if the reference
    /// clamp moved it), so the level a press changed is back within milliseconds.
    private func putBack() {
        guard let slider, reader.needsPutBack else { return }
        VolumeLog.shared.note("put back: \(reader.previous) → \(reader.reference) (slider at \(slider.value))")
        reader.didPutBack(at: ProcessInfo.processInfo.systemUptime)
        // The slider follows the system volume lazily; if it still holds the target, setting it is a
        // no-op, so move it to the real volume first.
        slider.value = reader.previous
        slider.value = reader.reference
    }
}


/// Turns `outputVolume` readings into presses. A press is a step from the PREVIOUS reading. After
/// every press the volume is put back to the reference, and the reading that answers a put-back is
/// not a press: the first one within `putBackWindow` that lands nearer the reference than the
/// volume was. 🔴 The landing becomes the reference. The device moves in its own steps (an iPhone
/// Duo on iOS 27.1 reports 0.0, 0.05, 0.15, 0.2, 0.25, 0.3), so a put-back to a value off that
/// grid lands beside it (0.125 → 0.15), and build 7, which kept aiming at 0.125, read every
/// landing as a press and turned pages at random. A put-back to a value the device itself
/// reported lands on it exactly (0.25 → 0.25 in the same log), so once the reference is a landing
/// every later put-back is clean. `VolumeButtonTests` replays the device's log.
struct PressReader {
    nonisolated static let tolerance: Float = 0.01
    /// How long after a put-back its reading may arrive.
    nonisolated static let putBackWindow: TimeInterval = 1.0
    /// The reference stays at least this far inside the range, so a press either way moves the
    /// volume (at 0 a down press changes nothing and goes unseen).
    nonisolated static let margin: Float = 0.1

    private(set) var previous: Float
    private(set) var reference: Float
    private var putBackAt: TimeInterval?

    nonisolated init(previous: Float, reference: Float) {
        self.previous = previous
        self.reference = reference
    }

    /// The level put-backs aim for at first: the user's volume, kept inside the range.
    nonisolated static func reference(for volume: Float) -> Float {
        min(max(volume, margin), 1 - margin)
    }

    /// Whether the volume rests off the reference (a press moved it, or the clamp did).
    nonisolated var needsPutBack: Bool {
        abs(previous - reference) > Self.tolerance
    }

    nonisolated mutating func didPutBack(at time: TimeInterval) {
        putBackAt = time
    }

    nonisolated mutating func read(_ volume: Float, at time: TimeInterval) -> VolumeButtonPager.Press? {
        defer { previous = volume }
        if let putBackAt {
            let landing = time - putBackAt < Self.putBackWindow
                && abs(volume - reference) + Self.tolerance < abs(previous - reference)
            if landing || time - putBackAt >= Self.putBackWindow { self.putBackAt = nil }
            if landing {
                reference = volume
                return nil
            }
        }
        if volume > previous + Self.tolerance { return .up }
        if volume < previous - Self.tolerance { return .down }
        return nil
    }
}
