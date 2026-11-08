import AVFoundation
import GameController
import MediaPlayer
import Observation
import UIKit

/// The Input Debug screen's sources that are not the screen's own view (that one,
/// `InputCaptureController`, logs presses, key commands, touches and gestures): GameController
/// keyboards, mice and controllers, the volume (`outputVolume`), and the media remote commands.
/// Started when the screen's capture view enters a window, stopped when it leaves; `stop()` puts
/// back everything `start` changed (audio session, volume, command targets, Now Playing info), so
/// nothing reaches the reader.
@Observable
final class InputDebugSession {
    let log = InputDebugLog()
    private(set) var isRunning = false
    /// GameController's view of what is connected, for the header.
    private(set) var keyboards: [String] = []
    private(set) var mice: [String] = []
    private(set) var controllers: [String] = []
    /// The capture view holds first responder (presses only reach it then).
    var isFirstResponder = false
    /// Become the Now Playing app (non-mixing session + silent audio) so media keys arrive as
    /// remote commands; off = a mixable session, other apps' audio keeps playing, volume only.
    private(set) var nowPlaying = true
    /// `UIKeyCommand`s for arrows, space, return… with `wantsPriorityOverSystemBehavior`.
    var priorityKeys = true

    @ObservationIgnored private let gameControllers = GameControllerWatch()
    @ObservationIgnored private let audio = AudioWatch()
    @ObservationIgnored private let commands = RemoteCommandWatch()

    func start(host: UIView) {
        guard !isRunning else { return }
        isRunning = true
        log.add(.note, "start: nowPlaying=\(nowPlaying) priorityKeys=\(priorityKeys)")
        gameControllers.start(log: log) { [weak self] keyboards, mice, controllers in
            self?.keyboards = keyboards
            self?.mice = mice
            self?.controllers = controllers
        }
        audio.start(host: host, nowPlaying: nowPlaying, log: log)
        commands.start(nowPlaying: nowPlaying, log: log)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        log.add(.note, "stop")
        gameControllers.stop()
        commands.stop()
        audio.stop()
    }

    func setNowPlaying(_ on: Bool) {
        guard on != nowPlaying else { return }
        nowPlaying = on
        guard isRunning else { return }
        log.add(.note, "nowPlaying=\(on)")
        audio.setNowPlaying(on)
        commands.setNowPlaying(on)
    }

    /// What GameController says is connected, a line per kind (the screen shows one line each, so
    /// a device connecting never moves the controls).
    var deviceLines: [String] {
        func list(_ names: [String]) -> String { names.isEmpty ? "none" : names.joined(separator: ", ") }
        return ["keyboards: \(list(keyboards))", "mice: \(list(mice))", "controllers: \(list(controllers))"]
    }

    /// Header lines for a copied log.
    func exportHeader() -> [String] {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return [
            "Sheafs Input Debug, \(Date().formatted(date: .abbreviated, time: .standard)), Sheafs \(version), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            deviceLines.joined(separator: " · "),
            "nowPlaying=\(nowPlaying) priorityKeys=\(priorityKeys) rows=\(log.rows.count)",
        ]
    }
}

// MARK: - GameController

/// `GCKeyboard`/`GCMouse`/`GCController` connects and disconnects (with vendor name and product
/// category: what the remote presents itself as), every keyboard key, mouse moves (coalesced),
/// buttons and scrolls, and every controller element change.
final class GameControllerWatch {
    private var observers: [NSObjectProtocol] = []
    private var log: InputDebugLog?
    private var onChange: (([String], [String], [String]) -> Void)?
    private var keyboard: GCKeyboard?
    private var mice: [ObjectIdentifier: GCMouse] = [:]
    private var controllers: [ObjectIdentifier: GCController] = [:]
    /// Mouse moves and scrolls, summed and written at most every `flushInterval`.
    private var pendingMove = (dx: 0.0, dy: 0.0, count: 0)
    private var pendingScroll = (dx: 0.0, dy: 0.0, count: 0)
    private var flushScheduled = false
    private static let flushInterval = 0.25

    func start(log: InputDebugLog, onChange: @escaping ([String], [String], [String]) -> Void) {
        self.log = log
        self.onChange = onChange
        let names: [Notification.Name] = [
            .GCKeyboardDidConnect, .GCKeyboardDidDisconnect, .GCMouseDidConnect, .GCMouseDidDisconnect,
            .GCControllerDidConnect, .GCControllerDidDisconnect,
        ]
        for name in names {
            // GameController posts these on the main queue; the block only carries the name over.
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] note in
                let reason = note.name.rawValue
                DispatchQueue.main.async { self?.refresh(reason: reason) }
            })
        }
        refresh(reason: "start")
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        keyboard?.keyboardInput?.keyChangedHandler = nil
        keyboard = nil
        for mouse in mice.values { detach(mouse) }
        mice.removeAll()
        for controller in controllers.values { controller.physicalInputProfile.valueDidChangeHandler = nil }
        controllers.removeAll()
        log = nil
        onChange = nil
    }

    /// Diffs what GameController reports against what is attached: logs each connect and
    /// disconnect, attaches handlers to the new ones.
    private func refresh(reason: String) {
        guard let log else { return }
        let nowKeyboard = GCKeyboard.coalesced
        if nowKeyboard !== keyboard {
            if keyboard != nil { log.add(.device, "keyboard disconnected (\(reason))") }
            keyboard = nowKeyboard
            if let nowKeyboard {
                log.add(.device, "keyboard connected: \(Self.describeDevice(nowKeyboard)) (\(reason))")
                attach(nowKeyboard)
            }
        }
        let nowMice = Dictionary(GCMouse.mice().map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (id, mouse) in mice where nowMice[id] == nil {
            log.add(.device, "mouse disconnected: \(Self.describeDevice(mouse)) (\(reason))")
            detach(mouse)
        }
        for (id, mouse) in nowMice where mice[id] == nil {
            log.add(.device, "mouse connected: \(Self.describeDevice(mouse)) (\(reason))")
            attach(mouse)
        }
        mice = nowMice
        let nowControllers = Dictionary(GCController.controllers().map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (id, controller) in controllers where nowControllers[id] == nil {
            log.add(.device, "controller disconnected: \(Self.describeController(controller)) (\(reason))")
            controller.physicalInputProfile.valueDidChangeHandler = nil
        }
        for (id, controller) in nowControllers where controllers[id] == nil {
            log.add(.device, "controller connected: \(Self.describeController(controller)) (\(reason))")
            attach(controller)
        }
        controllers = nowControllers
        onChange?(keyboard.map { [Self.describeDevice($0)] } ?? [], mice.values.map { Self.describeDevice($0) },
                  controllers.values.map { Self.describeController($0) })
    }

    private static func describeDevice(_ device: any GCDevice) -> String {
        "\"\(device.vendorName ?? "no name")\" (\(device.productCategory))"
    }

    private static func describeController(_ controller: GCController) -> String {
        var kinds: [String] = []
        if controller.extendedGamepad != nil { kinds.append("extended") }
        if controller.microGamepad != nil { kinds.append("micro") }
        if controller.isAttachedToDevice { kinds.append("attached") }
        return "\"\(controller.vendorName ?? "no name")\" (\(controller.productCategory)\(kinds.isEmpty ? "" : "; " + kinds.joined(separator: ", ")))"
    }

    // Handlers run on the device's handler queue (main by default). They are @Sendable, carry only
    // plain values and hop to the main actor, so a handler inferred @MainActor can't trap if
    // GameController ever calls from elsewhere (see WatchLink).

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { @Sendable [weak self] _, _, keyCode, pressed in
            let code = keyCode.rawValue, now = Date()
            DispatchQueue.main.async {
                self?.log?.add(.gcKeyboard, "key \(InputNames.keyLabel(code)) \(pressed ? "down" : "up")", at: now)
            }
        }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { @Sendable [weak self] _, dx, dy in
            DispatchQueue.main.async { self?.accumulate(move: (Double(dx), Double(dy))) }
        }
        let buttons = [("left", input.leftButton as GCControllerButtonInput?), ("right", input.rightButton),
                       ("middle", input.middleButton)]
            + (input.auxiliaryButtons ?? []).enumerated().map { ("aux\($0.offset + 1)", $0.element as GCControllerButtonInput?) }
        for (name, button) in buttons {
            button?.pressedChangedHandler = { @Sendable [weak self] _, _, pressed in
                let now = Date()
                DispatchQueue.main.async {
                    self?.flushPending()
                    self?.log?.add(.gcMouse, "button \(name) \(pressed ? "down" : "up")", at: now)
                }
            }
        }
        input.scroll.valueChangedHandler = { @Sendable [weak self] _, x, y in
            DispatchQueue.main.async { self?.accumulate(scroll: (Double(x), Double(y))) }
        }
    }

    private func detach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        input.auxiliaryButtons?.forEach { $0.pressedChangedHandler = nil }
        input.scroll.valueChangedHandler = nil
    }

    private func attach(_ controller: GCController) {
        controller.physicalInputProfile.valueDidChangeHandler = { @Sendable [weak self] _, element in
            let name = element.localizedName ?? element.unmappedLocalizedName ?? "element"
            let value: String
            if let button = element as? GCControllerButtonInput {
                value = "\(button.isPressed ? "pressed" : "released") value=\(String(format: "%.2f", button.value))"
            } else if let pad = element as? GCControllerDirectionPad {
                value = String(format: "x=%.2f y=%.2f", pad.xAxis.value, pad.yAxis.value)
            } else if let axis = element as? GCControllerAxisInput {
                value = String(format: "value=%.2f", axis.value)
            } else {
                value = String(describing: type(of: element))
            }
            let now = Date()
            DispatchQueue.main.async { self?.log?.add(.gcController, "\(name) \(value)", at: now) }
        }
    }

    private func accumulate(move: (Double, Double)) {
        pendingMove.dx += move.0
        pendingMove.dy += move.1
        pendingMove.count += 1
        scheduleFlush()
    }

    private func accumulate(scroll: (Double, Double)) {
        pendingScroll.dx += scroll.0
        pendingScroll.dy += scroll.1
        pendingScroll.count += 1
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.flushPending() }
    }

    private func flushPending() {
        flushScheduled = false
        if pendingMove.count > 0 {
            log?.add(.gcMouse, "moved Σ\(InputNames.delta(dx: pendingMove.dx, dy: pendingMove.dy)) in \(pendingMove.count) events")
            pendingMove = (0, 0, 0)
        }
        if pendingScroll.count > 0 {
            log?.add(.gcMouse, "scroll Σ\(InputNames.delta(dx: pendingScroll.dx, dy: pendingScroll.dy)) in \(pendingScroll.count) events")
            pendingScroll = (0, 0, 0)
        }
    }
}

// MARK: - Volume

/// Logs every `outputVolume` change, old → new, and what `PressReader` (the reader's volume-button
/// logic) makes of it. Like `VolumeButtonPager`: an active `.playback` session makes the volume
/// observable, a 1 pt `MPVolumeView` ON screen keeps the system volume HUD away, and after each
/// press the volume is put back to a reference so it never pins at 0 or 1 (where a press would
/// change nothing and show nothing). With Now Playing on, the session is NOT mixable and a silent
/// buffer loops, which is what makes iOS route media keys here as remote commands (it pauses other
/// apps' audio while the screen is up). `stop()` restores the user's volume and deactivates.
final class AudioWatch {
    private var log: InputDebugLog?
    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var madeSlider: UISlider?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var activeObserver: NSObjectProtocol?
    private var originalVolume: Float = 0.5
    private var reader = PressReader(previous: 0.5, reference: 0.5)
    private var isRunning = false

    private var slider: UISlider? { volumeView.flatMap(VolumeButtonPager.firstSlider(in:)) ?? madeSlider }

    func start(host: UIView, nowPlaying: Bool, log: InputDebugLog) {
        guard !isRunning else { return }
        self.log = log
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: nowPlaying ? [] : [.mixWithOthers])
            try session.setActive(true)
        } catch {
            log.add(.volume, "audio session failed: \(error.localizedDescription)")
            return
        }
        isRunning = true
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        (host.window ?? host).addSubview(view)
        volumeView = view
        madeSlider = VolumeButtonPager.firstSlider(in: view)
        if nowPlaying { startSilence() }
        // Coming back from the background: the session and the silent player may have stopped.
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            DispatchQueue.main.async { self?.reactivate() }
        }
        // outputVolume is only current a moment after the session activates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, isRunning else { return }
            originalVolume = session.outputVolume
            let reference = PressReader.reference(for: originalVolume)
            reader = PressReader(previous: originalVolume, reference: reference)
            log.add(.volume, "watching: volume=\(Self.level(originalVolume)) reference=\(Self.level(reference)) category=\(session.category.rawValue) mixable=\(session.categoryOptions.contains(.mixWithOthers)) otherAudio=\(session.isOtherAudioPlaying) slider=\(slider != nil)")
            observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let volume = change.newValue else { return }
                let now = Date()
                DispatchQueue.main.async { self?.volumeChanged(volume, at: now) }
            }
            putBack()
        }
    }

    func setNowPlaying(_ on: Bool) {
        guard isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: on ? [] : [.mixWithOthers])
        } catch {
            log?.add(.volume, "category change failed: \(error.localizedDescription)")
        }
        if on { startSilence() } else { stopSilence() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observation?.invalidate()
        observation = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        stopSilence()
        log?.add(.volume, "stop: restoring volume=\(Self.level(originalVolume))")
        slider?.value = originalVolume
        let view = volumeView
        volumeView = nil
        madeSlider = nil
        log = nil
        // Let the slider's restore reach the system before the view (and the session) go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            view?.removeFromSuperview()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func volumeChanged(_ volume: Float, at date: Date) {
        guard isRunning, let log else { return }
        let old = reader.previous
        let press = reader.read(volume, at: ProcessInfo.processInfo.systemUptime)
        let meaning = switch press {
        case .up: "UP"
        case .down: "DOWN"
        case nil: abs(volume - old) <= PressReader.tolerance ? "(no step)" : "(put-back landing, reference now \(Self.level(reader.reference)))"
        }
        log.add(.volume, "outputVolume \(Self.level(old)) → \(Self.level(volume)) \(meaning)", at: date)
        if press != nil { putBack() }
    }

    private func putBack() {
        guard let slider, reader.needsPutBack else { return }
        log?.add(.volume, "put back \(Self.level(reader.previous)) → \(Self.level(reader.reference))")
        reader.didPutBack(at: ProcessInfo.processInfo.systemUptime)
        // The slider follows the system volume lazily; move it to the real volume first, else
        // setting the target it still holds is a no-op.
        slider.value = reader.previous
        slider.value = reader.reference
    }

    private func reactivate() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if let engine, let player, !engine.isRunning {
            do {
                try engine.start()
                try player.playAudio()
                log?.add(.volume, "silent audio restarted")
            } catch {
                log?.add(.volume, "silent audio restart failed: \(error.localizedDescription)")
            }
        }
    }

    /// A second of zeros, looping: the audio that makes Sheafs the Now Playing app.
    private func startSilence() {
        guard engine == nil else { return }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        engine.attach(player)
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            try player.playAudio()
        } catch {
            engine.stop()
            log?.add(.media, "silent audio failed: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.player = player
        log?.add(.media, "silent audio playing (Now Playing)")
    }

    private func stopSilence() {
        guard let engine else { return }
        player?.stop()
        engine.stop()
        self.engine = nil
        player = nil
        log?.add(.media, "silent audio stopped")
    }

    private static func level(_ volume: Float) -> String { String(format: "%.4f", volume) }
}

// MARK: - Media remote commands

/// A target on every `MPRemoteCommandCenter` command, logging each event with its details, and a
/// Now Playing entry so iOS routes media keys here. `stop()` removes every target, puts back each
/// command's enabled state and settings, and clears the Now Playing info.
final class RemoteCommandWatch {
    private struct Target {
        let name: String
        let command: MPRemoteCommand
        let token: Any
        let wasEnabled: Bool
    }

    private var targets: [Target] = []
    private var savedIntervals: (forward: [NSNumber], backward: [NSNumber])?
    private var savedRates: [NSNumber]?

    func start(nowPlaying: Bool, log: InputDebugLog) {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        savedIntervals = (center.skipForwardCommand.preferredIntervals, center.skipBackwardCommand.preferredIntervals)
        savedRates = center.changePlaybackRateCommand.supportedPlaybackRates
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand), ("pause", center.pauseCommand),
            ("togglePlayPause", center.togglePlayPauseCommand), ("stop", center.stopCommand),
            ("nextTrack", center.nextTrackCommand), ("previousTrack", center.previousTrackCommand),
            ("seekForward", center.seekForwardCommand), ("seekBackward", center.seekBackwardCommand),
            ("skipForward", center.skipForwardCommand), ("skipBackward", center.skipBackwardCommand),
            ("changePlaybackPosition", center.changePlaybackPositionCommand),
            ("changePlaybackRate", center.changePlaybackRateCommand),
            ("like", center.likeCommand), ("dislike", center.dislikeCommand), ("bookmark", center.bookmarkCommand),
            ("changeRepeatMode", center.changeRepeatModeCommand), ("changeShuffleMode", center.changeShuffleModeCommand),
        ]
        for (name, command) in commands {
            let wasEnabled = command.isEnabled
            command.isEnabled = true
            let token = command.addTarget(handler: Self.handler(name: name, log: log))
            targets.append(Target(name: name, command: command, token: token, wasEnabled: wasEnabled))
        }
        log.add(.media, "targets on \(targets.count) remote commands")
        setNowPlaying(nowPlaying)
    }

    func setNowPlaying(_ on: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = on ? [
            MPMediaItemPropertyTitle: "Sheafs Input Debug",
            MPMediaItemPropertyArtist: "Press the remote's buttons",
            MPMediaItemPropertyPlaybackDuration: 3600.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ] : nil
    }

    func stop() {
        for target in targets {
            target.command.removeTarget(target.token)
            target.command.isEnabled = target.wasEnabled
        }
        targets.removeAll()
        let center = MPRemoteCommandCenter.shared()
        if let savedIntervals {
            center.skipForwardCommand.preferredIntervals = savedIntervals.forward
            center.skipBackwardCommand.preferredIntervals = savedIntervals.backward
        }
        if let savedRates { center.changePlaybackRateCommand.supportedPlaybackRates = savedRates }
        savedIntervals = nil
        savedRates = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// The command's handler: nonisolated and @Sendable (MediaPlayer's queue is not promised to be
    /// main), reads the event's details there and hops to the main actor with plain values.
    private nonisolated static func handler(name: String, log: InputDebugLog) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { @Sendable event in
            let now = Date()
            let detail = details(of: event)
            DispatchQueue.main.async { log.add(.media, name + detail, at: now) }
            return .success
        }
    }

    private nonisolated static func details(of event: MPRemoteCommandEvent) -> String {
        if let skip = event as? MPSkipIntervalCommandEvent { return " interval=\(skip.interval)" }
        if let seek = event as? MPSeekCommandEvent { return seek.type == .beginSeeking ? " begin" : " end" }
        if let position = event as? MPChangePlaybackPositionCommandEvent { return " position=\(position.positionTime)" }
        if let rate = event as? MPChangePlaybackRateCommandEvent { return " rate=\(rate.playbackRate)" }
        if let feedback = event as? MPFeedbackCommandEvent { return " negative=\(feedback.isNegative)" }
        if let repeatMode = event as? MPChangeRepeatModeCommandEvent { return " repeat=\(repeatMode.repeatType.rawValue)" }
        if let shuffle = event as? MPChangeShuffleModeCommandEvent { return " shuffle=\(shuffle.shuffleType.rawValue)" }
        return ""
    }
}
