import AVFoundation
import MediaPlayer
import UIKit
import os

/// Turns pages with the volume buttons: down = next page, up = previous (like Kindle and Readest).
///
/// iOS has no public volume-button event outside a camera session, so this is the usual trick:
/// an active audio session makes `outputVolume` observable, every press is a step from the last
/// reading (`PressReader`), and a hidden `MPVolumeView`'s slider puts the volume straight back, so
/// the level never really changes and the system volume HUD stays away (an `MPVolumeView` in the
/// window suppresses it). The session is `.playback` + `.mixWithOthers` (Readest's, proven on
/// devices): nothing is played, and other apps' audio keeps going. On stop the user's volume is
/// restored and the session deactivated. The approach is credited in the README; Readest is
/// AGPL, so its code must not be copied into this MIT tree.
final class VolumeButtonPager {
    enum Press: Equatable { case up, down }

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
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.isUserInteractionEnabled = false
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

    /// Debug: `-SheafsVolumeProbe up|down` moves the volume one step through the slider 1.5 s after
    /// starting, standing in for a button press (the simulator has no volume buttons).
    private func probeIfAsked() {
        guard let direction = UserDefaults.standard.string(forKey: "SheafsVolumeProbe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, isRunning else { return }
            let target = reader.reference + (direction == "up" ? 0.0625 : -0.0625)
            VolumeLog.shared.note("probe: slider=\(self.slider != nil) → \(target)")
            slider?.value = target
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
        VolumeLog.shared.note("outputVolume=\(volume) press=\(press.map { "\($0)" } ?? "none") slider=\(self.slider != nil)")
        guard let press else { return }
        putBack()
        onPress?(press)
    }

    /// Moves the volume back to the reference, so the next press reads in either direction.
    private func putBack() {
        guard let slider, abs(reader.previous - reader.reference) > PressReader.tolerance else { return }
        reader.didPutBack(at: ProcessInfo.processInfo.systemUptime)
        slider.value = reader.reference
    }
}

/// Turns `outputVolume` readings into presses. A press is a step from the PREVIOUS reading, so the
/// direction is right even if the slider fails to put the volume back; the reading that answers a
/// put-back (the reference, shortly after asking for it) is not a press.
struct PressReader {
    nonisolated static let tolerance: Float = 0.01
    /// How long after a put-back its reading may arrive.
    nonisolated static let putBackWindow: TimeInterval = 0.5

    private(set) var previous: Float
    let reference: Float
    private var putBackAt: TimeInterval?

    nonisolated init(previous: Float, reference: Float) {
        self.previous = previous
        self.reference = reference
    }

    /// The level presses are put back to: the user's volume, kept a step away from both ends
    /// so a press in either direction moves it (iOS steps the volume by 1/16).
    nonisolated static func reference(for volume: Float) -> Float {
        min(max(volume, 0.125), 0.875)
    }

    nonisolated mutating func didPutBack(at time: TimeInterval) {
        putBackAt = time
    }

    nonisolated mutating func read(_ volume: Float, at time: TimeInterval) -> VolumeButtonPager.Press? {
        defer { previous = volume }
        if let putBackAt, time - putBackAt < Self.putBackWindow, abs(volume - reference) < Self.tolerance {
            self.putBackAt = nil
            return nil
        }
        if volume > previous + Self.tolerance { return .up }
        if volume < previous - Self.tolerance { return .down }
        return nil
    }
}
