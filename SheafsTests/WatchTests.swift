import Testing
import Foundation
@testable import Sheafs

private final class BundleMarker {}

/// The Apple Watch remote: what the watch and the phone send each other, what a command does to
/// the reader, and that the app carries the watch app the way watchOS installs it.
struct WatchTests {
    /// WCSession accepts property-list dictionaries only; anything else fails the send at run time.
    private func isPropertyList(_ message: [String: Any]) -> Bool {
        PropertyListSerialization.propertyList(message, isValidFor: .binary)
    }

    @Test func commandsRoundTripAndMapToTurns() {
        for command in WatchCommand.allCases {
            #expect(WatchCommand(message: command.message()) == command)
            #expect(isPropertyList(command.message()))
        }
        // Stamped with the time it was sent, so a late delivery can be told apart.
        let sent = Date(timeIntervalSince1970: 1_000_000)
        #expect(WatchCommand.age(of: WatchCommand.next.message(sentAt: sent), now: sent.addingTimeInterval(7)) == 7)
        #expect(WatchCommand.age(of: ["command": "next"]) == nil)
        #expect(WatchCommand.next.turnsForward == true)
        #expect(WatchCommand.previous.turnsForward == false)
        #expect(WatchCommand.status.turnsForward == nil)
        #expect(WatchCommand(message: [:]) == nil)
        #expect(WatchCommand(message: ["command": "flip"]) == nil)
        #expect(WatchCommand(message: ["command": 1]) == nil)
    }

    @Test func statusAndReplyRoundTrip() {
        let reading = WatchStatus(state: .reading, title: "Pride and Prejudice", page: 136, pageCount: 594, progress: 0.23)
        #expect(WatchStatus(message: reading.message) == reading)
        #expect(isPropertyList(reading.message))
        #expect(reading.pageLabel == "136 of 594")
        #expect(WatchStatus(message: WatchStatus.noBook.message) == .noBook)
        #expect(WatchStatus.noBook.pageLabel == nil)
        // Not laid out yet: the percentage, as the reader's strip shows it then.
        #expect(WatchStatus(state: .reading, title: "Emma", progress: 0.42).pageLabel == 0.42.formatted(.percent.precision(.fractionLength(0))))
        #expect(WatchStatus(message: ["state": "dancing"]) == nil)
        #expect(WatchStatus(message: [:]) == nil)

        for reply in [WatchReply(turned: true, status: reading), WatchReply(turned: false, status: .noBook)] {
            #expect(WatchReply(message: reply.message) == reply)
            #expect(isPropertyList(reply.message))
        }
        // A bare status is not a reply (an old phone app, or a push mistaken for one).
        #expect(WatchReply(message: reading.message) == nil)
    }

    /// A stand-in reader that records the turns it is asked for.
    @MainActor final class FakeReader {
        var status: WatchStatus
        var turns: [Bool] = []
        var hasPager = true
        init(_ status: WatchStatus) { self.status = status }
        var handle: WatchReaderHandle {
            WatchReaderHandle(status: { self.status }, turn: { forward in
                guard self.hasPager else { return false }
                self.turns.append(forward)
                return true
            })
        }
    }

    @Test func commandsTurnTheReaderOnlyWhileReading() {
        let page = WatchStatus(state: .reading, title: "Emma", page: 10, pageCount: 400)
        let reader = FakeReader(page)
        #expect(WatchLink.answer(.next, reader: reader.handle) == WatchReply(turned: true, status: page))
        #expect(WatchLink.answer(.previous, reader: reader.handle) == WatchReply(turned: true, status: page))
        #expect(WatchLink.answer(.status, reader: reader.handle) == WatchReply(turned: false, status: page))
        #expect(reader.turns == [true, false])

        // No reader on screen: nothing to turn, and the watch hears there's no book.
        #expect(WatchLink.answer(.next, reader: nil) == WatchReply(turned: false, status: .noBook))

        // The reader is up but Sheafs is in the background: never turn behind the user's back.
        reader.status = WatchStatus(state: .inBackground, title: "Emma", page: 10, pageCount: 400)
        #expect(WatchLink.answer(.next, reader: reader.handle).turned == false)
        #expect(reader.turns == [true, false])

        // A command delivered long after it was sent (WatchConnectivity launches the phone app for
        // it) never turns a page by itself; one just inside the limit, or of unknown age, does.
        reader.status = page
        #expect(WatchLink.answer(.next, reader: reader.handle, age: WatchCommand.staleAfter + 1).turned == false)
        #expect(WatchLink.answer(.next, reader: reader.handle, age: WatchCommand.staleAfter - 1).turned == true)
        #expect(reader.turns == [true, false, true])

        // No pager yet (the book still opening): not turned.
        reader.hasPager = false
        #expect(WatchLink.answer(.next, reader: reader.handle) == WatchReply(turned: false, status: page))
    }

    /// A turn's reply waits for the turn to land and carries the page landed on; a command that
    /// turns nothing is answered at once.
    @Test func turnRepliesCarryThePageLandedOn() async throws {
        let link = WatchLink()
        let reader = FakeReader(WatchStatus(state: .reading, title: "Emma", page: 10, pageCount: 400))
        link.attach(reader.handle)
        var replies: [WatchReply] = []
        link.receive(.status) { replies.append($0) }
        #expect(replies.map(\.status.page) == [10])
        link.receive(.next) { replies.append($0) }
        #expect(replies.count == 1, "answered before the turn landed")
        reader.status.page = 11
        link.attach(reader.handle)          // the reader moved: what `WatchRemote` does on landing
        #expect(replies.last == WatchReply(turned: true, status: reader.status))
        // A turn that never lands (the last page) is answered after the timeout, unchanged.
        link.receive(.next) { replies.append($0) }
        try await Task.sleep(for: WatchLink.landingTimeout + .milliseconds(500))
        #expect(replies.count == 3 && replies.last?.status.page == 11)
    }

    /// The status of a real reader: the book's first page is page 1 once laid out, a percentage
    /// before, the title alone while it opens; a reader behind another app is in the background.
    @Test func statusOfARealReader() async throws {
        #expect(WatchRemote.status(session: nil, title: "Alice", active: true) == WatchStatus(state: .reading, title: "Alice"))
        #expect(WatchRemote.status(session: nil, title: "Alice", active: false).state == .inBackground)

        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "alice-epub3", withExtension: "epub"))
        let book = Book(title: "Alice", author: nil, language: "en", fileSize: 1, partialMD5: nil, hasCover: false)
        let session = BookSession(book: book, fileURL: url)
        await session.load()
        #expect(session.isReady)
        let before = WatchRemote.status(session: session, title: "Alice", active: true)
        #expect(before.state == .reading && before.title == "Alice")
        #expect(before.page == nil && before.progress == 0)

        session.configure(style: ReaderEngineTests.style, textSize: CGSize(width: 300, height: 480))
        _ = try #require(session.paginatedChapter(session.location.spineIndex))
        let laidOut = WatchRemote.status(session: session, title: "Alice", active: true)
        #expect(laidOut.page == 1)
        #expect((laidOut.pageCount ?? 0) > 10, "Alice is longer than ten pages")
        #expect(WatchRemote.status(session: session, title: "Alice", active: false).state == .inBackground)
    }

    /// watchOS installs the watch app from the phone app's Watch/ folder; it must be a watch app
    /// (WKApplication), name this app as its companion, and carry this app's version and build:
    /// App Store Connect refuses an upload whose watch app's versions differ from the app's.
    @Test func appEmbedsTheWatchApp() throws {
        let watchURL = Bundle.main.bundleURL.appending(path: "Watch/SheafsWatch.app")
        let watch = try #require(Bundle(url: watchURL), "no Watch/SheafsWatch.app in the app")
        func value(_ key: String) -> Any? { watch.object(forInfoDictionaryKey: key) }
        #expect(watch.bundleIdentifier == "io.sheafs.reader.watchkitapp")
        #expect(value("WKApplication") as? Bool == true)
        #expect(value("WKCompanionAppBundleIdentifier") as? String == Bundle.main.bundleIdentifier)
        #expect((value("DTPlatformName") as? String)?.hasPrefix("watch") == true, "the embedded app is not built for watchOS")
        #expect(value("UIDeviceFamily") as? [Int] == [4])
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            #expect(value(key) as? String == Bundle.main.object(forInfoDictionaryKey: key) as? String, "\(key) differs from the app's")
        }
        // The asset catalog compiler names the icon only when it found the watchOS entry.
        let icons = value("CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        #expect(primary?["CFBundleIconName"] as? String == "AppIcon", "the watch app has no icon")
        #expect(FileManager.default.fileExists(atPath: watchURL.appending(path: "Assets.car").path()))
    }
}
