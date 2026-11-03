import Foundation

// Compiled into the app and the watch app (see project.yml), not the widget: what the two say to
// each other over WatchConnectivity. The watch sends a `WatchCommand`, the phone answers with a
// `WatchReply` and pushes a `WatchStatus` whenever the reader moves, opens or closes. WCSession
// takes property-list dictionaries only, so every value here is a String, Int, Double or Bool.

/// What the watch asks of the phone.
nonisolated enum WatchCommand: String, Sendable, CaseIterable {
    /// Turn to the next page (the big button; the watch's double tap).
    case next
    /// Turn back a page.
    case previous
    /// Only the status: the watch app came up and wants the book and page.
    case status

    /// The turn this command asks for: forward, back, or none.
    var turnsForward: Bool? {
        switch self {
        case .next: true
        case .previous: false
        case .status: nil
        }
    }

    static let key = "command"
    static let sentKey = "sentAt"
    /// A turn older than this is not made: WatchConnectivity can deliver a message long after the
    /// watch gave up on it (it launches the phone app for it), and a page turning by itself then
    /// would lose the reader's place.
    static let staleAfter: TimeInterval = 5

    /// The message, stamped with when it was sent.
    func message(sentAt date: Date = .now) -> [String: Any] {
        [Self.key: rawValue, Self.sentKey: date.timeIntervalSince1970]
    }

    init?(message: [String: Any]) {
        guard let raw = message[Self.key] as? String, let command = WatchCommand(rawValue: raw) else { return nil }
        self = command
    }

    /// How long ago `message` was sent, or nil when it carries no time.
    static func age(of message: [String: Any], now: Date = .now) -> TimeInterval? {
        (message[sentKey] as? Double).map { now.timeIntervalSince1970 - $0 }
    }
}

/// What the phone's reader is showing, as the watch shows it.
nonisolated struct WatchStatus: Equatable, Sendable {
    enum State: String, Sendable {
        /// A book is open in the reader and Sheafs is in the foreground: commands turn pages.
        case reading
        /// No book is open (the library, catalogs or settings are up).
        case noBook
        /// The reader is open but Sheafs is not in the foreground (another app, the phone locked).
        case inBackground
    }

    var state: State
    var title: String?
    /// The book-wide page number the folio shows (the right-hand page of a spread), and the total.
    var page: Int?
    var pageCount: Int?
    /// 0…1 through the book, for when the page isn't laid out yet.
    var progress: Double?

    static let noBook = WatchStatus(state: .noBook)

    /// "136 of 594" like the reader's strip, else a percentage, else nothing.
    var pageLabel: String? {
        if let page, let pageCount { return "\(page) of \(pageCount)" }
        if let progress { return progress.formatted(.percent.precision(.fractionLength(0))) }
        return nil
    }

    var message: [String: Any] {
        var message: [String: Any] = ["state": state.rawValue]
        if let title { message["title"] = title }
        if let page { message["page"] = page }
        if let pageCount { message["pageCount"] = pageCount }
        if let progress { message["progress"] = progress }
        return message
    }

    init(state: State, title: String? = nil, page: Int? = nil, pageCount: Int? = nil, progress: Double? = nil) {
        self.state = state
        self.title = title
        self.page = page
        self.pageCount = pageCount
        self.progress = progress
    }

    init?(message: [String: Any]) {
        guard let raw = message["state"] as? String, let state = State(rawValue: raw) else { return nil }
        self.init(state: state, title: message["title"] as? String, page: message["page"] as? Int,
                  pageCount: message["pageCount"] as? Int, progress: message["progress"] as? Double)
    }
}

/// The phone's answer to a command: whether the reader took the turn, and the status after it.
/// A turn's reply waits for the turn to land (1.5 s at most), so it carries the new page.
nonisolated struct WatchReply: Equatable, Sendable {
    var turned: Bool
    var status: WatchStatus

    var message: [String: Any] { status.message.merging(["turned": turned]) { $1 } }

    init(turned: Bool, status: WatchStatus) {
        self.turned = turned
        self.status = status
    }

    init?(message: [String: Any]) {
        guard let turned = message["turned"] as? Bool, let status = WatchStatus(message: message) else { return nil }
        self.init(turned: turned, status: status)
    }
}
