import Foundation
import Observation
import SheafsKit

/// Chapter summaries the on-device model made, one JSON file per book in Application Support/Recaps
/// (`RecapPlan.key` → summary). Not in SwiftData: they are a cache that can always be made again,
/// and a file per book keeps them out of the library's schema. Deleted with the book.
@MainActor
final class RecapStore {
    let url: URL
    private(set) var summaries: [String: String]

    init(bookID: UUID) {
        url = Self.directory.appending(path: "\(bookID.uuidString).json")
        summaries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func summary(forKey key: String) -> String? { summaries[key] }

    func set(_ summary: String, forKey key: String) {
        summaries[key] = summary
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(summaries) { try? data.write(to: url, options: .atomic) }
    }

    nonisolated static var directory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Recaps", directoryHint: .isDirectory)
    }

    nonisolated static func delete(bookID: UUID) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(bookID.uuidString).json"))
    }

    nonisolated static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated static var storedBookCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }
}

/// Summarises the chapters the reader has finished, one at a time in the background while the
/// book is open and Ask is on: the latest finished chapter first (most questions are about what
/// just happened), then back toward the start. Only chapters wholly before the reader's chapter,
/// so a summary never covers unread text. Pauses while a question is being answered (one model
/// at a time on the device).
@Observable
@MainActor
final class RecapBuilder {
    private let session: BookSession
    let store: RecapStore
    /// Chapters before this one are summarised.
    private var upTo = 0
    private var task: Task<Void, Never>?
    private var pauses = 0
    /// The chapter being summarised now, if any.
    private(set) var working: Int?

    init(session: BookSession, store: RecapStore) {
        self.session = session
        self.store = store
    }

    /// Chapters worth a summary (front matter and pictures-only pages aren't).
    private func worthSummary(_ spine: Int) -> Bool {
        spine < session.chapters.count && session.chapters[spine].textLength >= 400
    }

    /// How many finished chapters have a summary, of how many could.
    var progress: (done: Int, total: Int) {
        var done = 0, total = 0
        for spine in 0 ..< min(upTo, session.chapters.count) where worthSummary(spine) {
            total += 1
            if store.summary(forKey: RecapPlan.key(of: session.chapters[spine], spineIndex: spine)) != nil { done += 1 }
        }
        return (done, total)
    }

    /// The stored summaries of chapters before `spine`.
    func recaps(before spine: Int) -> [ChapterRecap] {
        (0 ..< min(spine, session.chapters.count)).compactMap { index in
            store.summary(forKey: RecapPlan.key(of: session.chapters[index], spineIndex: index))
                .map { ChapterRecap(spineIndex: index, summary: $0) }
        }
    }

    /// Summarise chapters before `spine` (call again as the reader moves on; a no-op while running).
    func start(before spine: Int) {
        upTo = max(upTo, spine)
        guard task == nil, session.isReady, AskEngine.availability.isAvailable else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
            self?.working = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        working = nil
    }

    func pause() { pauses += 1 }
    func resume() { pauses = max(0, pauses - 1) }

    private func run() async {
        while !Task.isCancelled {
            guard let spine = (0 ..< min(upTo, session.chapters.count)).reversed().first(where: { spine in
                worthSummary(spine) && store.summary(forKey: RecapPlan.key(of: session.chapters[spine], spineIndex: spine)) == nil
            }) else { return }
            working = spine
            let chapter = session.chapters[spine]
            let key = RecapPlan.key(of: chapter, spineIndex: spine)
            let parts = RecapPlan.parts(of: chapter, spineIndex: spine, maxLength: AskEngine.recapPartLength)
            var summary: String?
            for part in parts {
                while pauses > 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)) }
                if Task.isCancelled { return }
                do {
                    summary = try await AskEngine.recap(part: part, carrying: summary)
                } catch {
                    switch AskEngine.classify(error) {
                    case .declined, .contextTooLong:
                        // Leave this part out and carry on with the rest of the chapter.
                        AskEngine.log.notice("recap of chapter \(spine) skipped a part: \(error)")
                    case .other:
                        AskEngine.log.error("recap of chapter \(spine) failed: \(error)")
                        return
                    }
                }
            }
            // A chapter whose every part was declined still gets an entry, so it isn't tried forever.
            store.set(summary ?? "", forKey: key)
            AskEngine.log.info("recap of chapter \(spine): \(parts.count) parts, \(summary?.count ?? 0) characters")
        }
    }
}
