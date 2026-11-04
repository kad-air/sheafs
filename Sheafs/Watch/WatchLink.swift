import SwiftUI
import WatchConnectivity
import os

/// The reader on screen, as the watch remote reaches it. `WatchRemote` attaches one while a
/// reader is up and detaches it when the reader goes.
struct WatchReaderHandle {
    /// The book, its page and whether Sheafs is in the foreground, as of now.
    var status: () -> WatchStatus
    /// Turns a page the way a tap on the page's edge does (`PagerController.turnPage`: the flip,
    /// or the slide); false when there is no pager to turn.
    var turn: (_ forward: Bool) -> Bool
}

/// The phone's end of the Apple Watch remote (`SheafsWatch`): the app's one `WCSession` delegate.
/// The watch sends a `WatchCommand`; while a book is open and Sheafs is in the foreground, next and
/// previous turn the page through the reader's own turn, and every reply and every move of the
/// reader tells the watch the book and page (`WatchStatus`).
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    private var reader: WatchReaderHandle?
    /// The last status pushed, so an unchanged one isn't sent again.
    private var pushed: WatchStatus?
    private let log = Logger(subsystem: "io.sheafs.reader", category: "watch")

    /// Called at launch (`SheafsApp.init`): a message from the watch can launch the app in the
    /// background, and it is delivered only to a session that is already activated.
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Replies to turns in flight: sent when the turn lands (the next `attach`), with the new page,
    /// or `landingTimeout` after the command at the latest (no next page, a turn that never lands).
    private var landingReplies: [(WatchReply) -> Void] = []
    static let landingTimeout: Duration = .seconds(1.5)

    func attach(_ reader: WatchReaderHandle) {
        self.reader = reader
        push(reader.status())
        sendLandingReplies()
    }

    func detach() {
        reader = nil
        push(.noBook)
        sendLandingReplies()
    }

    /// Pushes the status even if unchanged: the session (re)activated or the paired watch changed,
    /// and whatever was pushed before may have gone nowhere.
    func resend() {
        pushed = nil
        push(reader?.status() ?? .noBook)
    }

    /// What a command does: next and previous turn the page only while a book is open in the
    /// foreground (a page turned behind another app, or on a locked phone, would just lose the
    /// reader's place) and only when the command is fresh (`WatchCommand.staleAfter`; `age` nil =
    /// unknown, taken as fresh). The reply carries the status as it was when the command came in.
    static func answer(_ command: WatchCommand, reader: WatchReaderHandle?, age: TimeInterval? = nil) -> WatchReply {
        guard let reader else { return WatchReply(turned: false, status: .noBook) }
        let status = reader.status()
        guard let forward = command.turnsForward, status.state == .reading,
              (age ?? 0) <= WatchCommand.staleAfter else {
            return WatchReply(turned: false, status: status)
        }
        return WatchReply(turned: reader.turn(forward), status: status)
    }

    /// A command from the watch (or `-SheafsWatchCommands`), on the main actor. `reply` gets the
    /// answer: at once when nothing turned, else once the turn has landed, with the new page.
    func receive(_ command: WatchCommand, age: TimeInterval? = nil, reply: @escaping (WatchReply) -> Void = { _ in }) {
        print("[watch] command \(command.rawValue)\(age.map { String(format: " (sent %.1f s ago)", $0) } ?? "")")
        let answer = Self.answer(command, reader: reader, age: age)
        log.notice("command \(command.rawValue, privacy: .public) turned=\(answer.turned)")
        guard answer.turned else {
            print("[watch] reply turned=false \(Self.describe(answer.status))")
            reply(answer)
            return
        }
        landingReplies.append(reply)
        Task {
            try? await Task.sleep(for: Self.landingTimeout)
            sendLandingReplies()
        }
    }

    private func sendLandingReplies() {
        guard !landingReplies.isEmpty else { return }
        let replies = landingReplies, status = reader?.status() ?? .noBook
        landingReplies = []
        print("[watch] reply turned=true \(Self.describe(status))\(replies.count > 1 ? " (×\(replies.count))" : "")")
        for reply in replies { reply(WatchReply(turned: true, status: status)) }
    }

    private func push(_ status: WatchStatus) {
        guard status != pushed else { return }
        pushed = status
        print("[watch] status \(Self.describe(status))")
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isPaired, session.isWatchAppInstalled {
            do {
                // Read by the watch app the next time it comes up.
                try session.updateApplicationContext(status.message)
            } catch {
                log.error("application context: \(error.localizedDescription, privacy: .public)")
            }
        }
        // The watch app is reachable only while it is on screen: then it hears at once (whatever
        // `isWatchAppInstalled` says; the simulator reports it wrongly at times).
        if session.isReachable {
            // @Sendable: WatchConnectivity calls it on its own queue, not the main actor.
            session.sendMessage(status.message, replyHandler: nil) { @Sendable error in
                print("[watch] status not delivered: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func describe(_ status: WatchStatus) -> String {
        "\(status.state.rawValue) \"\(status.title ?? "")\" page \(status.page.map(String.init) ?? "?") of \(status.pageCount.map(String.init) ?? "?")"
    }

    // MARK: WCSessionDelegate (called on WatchConnectivity's queue)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let state = activationState.rawValue, message = error?.localizedDescription
        print("[watch] session activated: state=\(state) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) error=\(message ?? "none")")
        Task { @MainActor in WatchLink.shared.resend() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in WatchLink.shared.resend() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = ReplyHandler(handler: replyHandler)
        guard let command = WatchCommand(message: message) else {
            print("[watch] unknown message \(message.keys.sorted())")
            reply.send(WatchReply(turned: false, status: .noBook))
            return
        }
        let age = WatchCommand.age(of: message)
        Task { @MainActor in
            WatchLink.shared.receive(command, age: age) { reply.send($0) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = WatchCommand(message: message) else { return }
        let age = WatchCommand.age(of: message)
        Task { @MainActor in
            WatchLink.shared.receive(command, age: age)
        }
    }

    /// WatchConnectivity's reply handler, carried to the main actor and back: it may be called
    /// from any thread, once.
    private nonisolated struct ReplyHandler: @unchecked Sendable {
        let handler: ([String: Any]) -> Void
        func send(_ reply: WatchReply) { handler(reply.message) }
    }
}

/// Puts the reader on the watch remote while it is up (`ReaderView`'s one hook): the watch's next
/// and previous turn its pages, and the watch hears the book and page after every move.
struct WatchRemote: ViewModifier {
    let session: BookSession?
    let proxy: PagerProxy
    let title: String
    @Environment(\.scenePhase) private var scenePhase

    /// What the watch's status depends on; a change pushes a new one.
    private struct Inputs: Equatable {
        var location: ReadingLocation?
        var ready: Bool
        var active: Bool
    }

    func body(content: Content) -> some View {
        content
            // A fresh handle on every change: the session arrives after the reader appears, and
            // the handle holds the scene phase as a value.
            .onChange(of: Inputs(location: session?.location, ready: session?.isReady == true, active: scenePhase == .active),
                      initial: true) { _, inputs in
                WatchLink.shared.attach(handle(active: inputs.active))
            }
            .task(id: session?.isReady == true) {
                guard session?.isReady == true else { return }
                await runLaunchArgumentCommands()
            }
            .onDisappear { WatchLink.shared.detach() }
    }

    private func handle(active: Bool) -> WatchReaderHandle {
        // Holds the session and proxy objects, not this view: it reads them when asked.
        let session = session, proxy = proxy, title = title
        return WatchReaderHandle(
            status: { WatchRemote.status(session: session, title: title, active: active) },
            turn: { forward in
                guard proxy.controller != nil else { return false }
                proxy.turn(forward: forward)
                return true
            })
    }

    /// The status for the reader as it is: the folio of the page holding the position, from the
    /// layout on screen (never lays one out: `BookSession.laidOutChapter`), else the percentage.
    /// While the book is still opening, the title alone; a book that failed to open is no book.
    static func status(session: BookSession?, title: String, active: Bool) -> WatchStatus {
        if case .failed = session?.state { return active ? .noBook : WatchStatus(state: .inBackground) }
        let state: WatchStatus.State = active ? .reading : .inBackground
        guard let session, session.isReady else { return WatchStatus(state: state, title: title) }
        let location = session.location
        var status = WatchStatus(state: state, title: title, progress: session.progress(for: location))
        if let chapter = session.laidOutChapter(location.spineIndex) {
            let pages = session.bookPages(spineIndex: location.spineIndex, page: chapter.pageIndex(containing: location.textOffset))
            status.page = pages.page
            status.pageCount = pages.total
        }
        return status
    }

    /// `-SheafsWatchCommands next,next,previous` (with `-SheafsOpen`): once the book is up, sends
    /// each command through `WatchLink.receive`, the path a message from the watch takes,
    /// `-SheafsWatchCommandGap` s apart (default 2.5), so a script can check turns without a watch.
    private func runLaunchArgumentCommands() async {
        guard !Self.launchCommandsConsumed,
              let list = UserDefaults.standard.string(forKey: "SheafsWatchCommands"), !list.isEmpty else { return }
        Self.launchCommandsConsumed = true
        let gap = UserDefaults.standard.object(forKey: "SheafsWatchCommandGap") as? Double ?? 2.5
        try? await Task.sleep(for: .seconds(2))
        for raw in list.split(separator: ",") {
            guard let command = WatchCommand(rawValue: raw.trimmingCharacters(in: .whitespaces)) else {
                print("[watch] unknown launch command \(raw)")
                continue
            }
            WatchLink.shared.receive(command)
            try? await Task.sleep(for: .seconds(gap))
        }
        print("[watch] launch commands done")
    }

    private static var launchCommandsConsumed = false
}

extension View {
    /// See `WatchRemote`.
    func watchRemote(session: BookSession?, proxy: PagerProxy, title: String) -> some View {
        modifier(WatchRemote(session: session, proxy: proxy, title: title))
    }
}
