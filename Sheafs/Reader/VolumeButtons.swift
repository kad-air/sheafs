import AVFoundation
import MediaPlayer
import UIKit

/// Turns pages with the volume buttons: down = next page, up = previous (like Kindle and Readest).
///
/// iOS has no public volume-button event outside a camera session, so this is the usual trick:
/// an active audio session makes `outputVolume` observable, every press is read as a step away
/// from a reference volume, and a hidden `MPVolumeView`'s slider puts the volume straight back, so
/// the level never really changes and the system volume HUD stays away (an `MPVolumeView` in the
/// window suppresses it). The session is `.playback` + `.mixWithOthers` (Readest's, proven on
/// devices): nothing is played, and other apps' audio keeps going. On stop the user's volume is
/// restored and the session deactivated. The approach is credited in the README; Readest is
/// AGPL, so its code must not be copied into this MIT tree.
final class VolumeButtonPager {
    enum Press: Equatable { case up, down }

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var slider: UISlider?
    private var originalVolume: Float = 0.5
    private var reference: Float = 0.5
    private var onPress: ((Press) -> Void)?
    private(set) var isRunning = false

    /// Starts listening; `host` must be in a window (the hidden volume view goes there).
    func start(host: UIView, onPress: @escaping (Press) -> Void) {
        guard !isRunning else { return }
        self.onPress = onPress
        isRunning = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[volume] audio session failed: \(error)")
            isRunning = false
            return
        }
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        (host.window ?? host).addSubview(view)
        volumeView = view
        slider = view.subviews.compactMap { $0 as? UISlider }.first
        // outputVolume is only current a moment after the session activates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, isRunning else { return }
            originalVolume = session.outputVolume
            reference = Self.reference(for: originalVolume)
            print("[volume] start: volume=\(originalVolume) reference=\(reference) slider=\(slider != nil)")
            setVolume(reference)
            observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let volume = change.newValue else { return }
                DispatchQueue.main.async { self?.volumeChanged(volume) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observation?.invalidate()
        observation = nil
        print("[volume] stop: restoring volume=\(originalVolume)")
        setVolume(originalVolume)
        let view = volumeView
        volumeView = nil
        slider = nil
        onPress = nil
        // Let the slider's restore reach the system before the view (and the session) go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            view?.removeFromSuperview()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func volumeChanged(_ volume: Float) {
        guard isRunning else { return }
        let press = Self.press(volume: volume, reference: reference)
        print("[volume] outputVolume=\(volume) reference=\(reference) press=\(press.map { "\($0)" } ?? "none")")
        guard let press else { return }  // our own reset back to the reference
        setVolume(reference)
        onPress?(press)
    }

    private func setVolume(_ volume: Float) {
        slider?.value = volume
    }

    /// The level presses are measured from: the user's volume, kept a step away from both ends
    /// so a press in either direction moves it (iOS steps the volume by 1/16).
    nonisolated static func reference(for volume: Float) -> Float {
        min(max(volume, 0.125), 0.875)
    }

    /// A volume reading as a press: above the reference is up, below is down, and the reference
    /// itself (the slider putting the volume back) is nothing.
    nonisolated static func press(volume: Float, reference: Float) -> Press? {
        let tolerance: Float = 0.01
        if volume > reference + tolerance { return .up }
        if volume < reference - tolerance { return .down }
        return nil
    }
}
