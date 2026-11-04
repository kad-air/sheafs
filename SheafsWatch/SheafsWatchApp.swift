import SwiftUI
import WatchConnectivity
import WatchKit

/// A page-turn remote for the reader on the phone: one big Next Page button that the watch's
/// double tap presses (`handGestureShortcut(.primaryAction)`), a small Previous Page button, and
/// the book and page the phone reports. Double tap works only while this app is on screen.
@main
struct SheafsWatchApp: App {
    @State private var remote = PageRemote()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteView(remote: remote)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { remote.refresh() }
                }
        }
    }
}

struct RemoteView: View {
    let remote: PageRemote

    var body: some View {
        VStack(spacing: 6) {
            header
                .frame(maxWidth: .infinity)
            Button { remote.send(.next) } label: {
                Image(systemName: "chevron.forward")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .handGestureShortcut(.primaryAction)
            .accessibilityLabel("Next Page")
            // Slim: a bordered button's minimum height would take half the room from Next.
            Button { remote.send(.previous) } label: {
                Label("Previous", systemImage: "chevron.backward")
                    .font(.footnote)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous Page")
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var header: some View {
        if let problem = remote.problem {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if let status = remote.status {
            switch status.state {
            case .reading:
                VStack(spacing: 0) {
                    Text(status.title ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(status.pageLabel ?? " ")
                        .font(.headline.monospacedDigit())
                }
            case .noBook:
                message("No book open in Sheafs on your iPhone.")
            case .inBackground:
                message("Sheafs isn’t open on your iPhone.")
            }
        } else {
            message("Waiting for your iPhone…")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

/// The watch's end of the link (the phone's is `WatchLink`): sends commands, shows what the phone
/// replies and pushes.
@Observable
final class PageRemote: NSObject, WCSessionDelegate {
    /// What the phone last said about its reader; nil until it has said anything.
    private(set) var status: WatchStatus?
    /// Why the last message didn't get through (no phone in reach, no answer); cleared by the next
    /// answer.
    private(set) var problem: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the phone for its status (the app came on screen, or the phone came back in reach).
    func refresh() {
        guard WCSession.default.activationState == .activated else { return }
        send(.status)
        sendLaunchArgumentCommands()
    }

    func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            problem = "Connecting to your iPhone…"
            return
        }
        // @Sendable: WatchConnectivity calls these on its own queue; only Sendable values cross.
        session.sendMessage(command.message(), replyHandler: { @Sendable message in
            let reply = WatchReply(message: message)
            Task { @MainActor in self.answered(command, with: reply) }
        }, errorHandler: { @Sendable error in
            let code = (error as? WCError)?.code, text = error.localizedDescription
            Task { @MainActor in self.failed(command, code: code, text: text) }
        })
    }

    /// `-SheafsWatchSend next,next,previous`: once the phone is reachable, sends each command as
    /// the buttons do, 3 s apart, so a paired pair of simulators can be checked without taps
    /// (`[watch-app] …` lines on stdout).
    private func sendLaunchArgumentCommands() {
        guard !launchCommandsSent, WCSession.default.isReachable,
              let list = UserDefaults.standard.string(forKey: "SheafsWatchSend"), !list.isEmpty else { return }
        launchCommandsSent = true
        let commands = list.split(separator: ",").compactMap { WatchCommand(rawValue: String($0)) }
        Task {
            for command in commands {
                try? await Task.sleep(for: .seconds(3))
                print("[watch-app] send \(command.rawValue)")
                send(command)
            }
            try? await Task.sleep(for: .seconds(3))
            print("[watch-app] launch commands done")
        }
    }

    private var launchCommandsSent = false

    private func answered(_ command: WatchCommand, with reply: WatchReply?) {
        print("[watch-app] reply to \(command.rawValue): \(reply.map { "turned=\($0.turned) \(Self.describe($0.status))" } ?? "unreadable")")
        guard let reply else {
            problem = "Update Sheafs on your iPhone."
            return
        }
        problem = nil
        // A turn's reply comes once the turn has landed: it holds the new page.
        status = reply.status
        guard command.turnsForward != nil else { return }
        WKInterfaceDevice.current().play(reply.turned ? .click : .failure)
    }

    private func failed(_ command: WatchCommand, code: WCError.Code?, text: String) {
        print("[watch-app] \(command.rawValue) failed: \(code.map { "\($0.rawValue)" } ?? "-") \(text)")
        switch code {
        case .notReachable?: problem = "Can’t reach your iPhone."
        case .messageReplyTimedOut?: problem = "Your iPhone didn’t answer."
        default: problem = text
        }
        if command.turnsForward != nil { WKInterfaceDevice.current().play(.failure) }
    }

    private func received(_ status: WatchStatus?) {
        guard let status else { return }
        print("[watch-app] status \(Self.describe(status))")
        self.status = status
        problem = nil
    }

    static func describe(_ status: WatchStatus) -> String {
        "\(status.state.rawValue) \"\(status.title ?? "")\" \(status.pageLabel ?? "-")"
    }

    // MARK: WCSessionDelegate (called on WatchConnectivity's queue)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        print("[watch-app] session activated: state=\(activationState.rawValue) reachable=\(session.isReachable) error=\(error?.localizedDescription ?? "none")")
        // The status the phone pushed last, while this app wasn't running.
        let last = WatchStatus(message: session.receivedApplicationContext)
        Task { @MainActor in
            self.received(last)
            self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        print("[watch-app] reachable=\(session.isReachable)")
        guard session.isReachable else { return }
        Task { @MainActor in self.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let status = WatchStatus(message: message)
        Task { @MainActor in self.received(status) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let status = WatchStatus(message: applicationContext)
        Task { @MainActor in self.received(status) }
    }
}
