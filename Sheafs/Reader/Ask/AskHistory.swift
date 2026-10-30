import Foundation

/// The questions asked about a book and their answers and passages, one JSON file per book in
/// Application Support/Ask, so they can be read again the next time the book is open. Only
/// finished answers are kept, newest last, at most `limit` of them. Deleted with the book.
@MainActor
final class AskHistoryStore {
    /// One finished question as stored.
    nonisolated struct Entry: Codable, Equatable, Sendable {
        nonisolated struct Source: Codable, Equatable, Sendable {
            var spineIndex: Int
            var textOffset: Int
            var chapter: String
            var snippet: String
        }

        var question: String
        var answer: String
        var sources: [Source]
        var summaryCount: Int
        var askedAt: Date
        /// The chapter the reader was in when asking.
        var chapter: String
        /// The reading limit the answer was made within.
        var limitSpine: Int
        var limitOffset: Int
    }

    static let limit = 200

    let url: URL
    private(set) var entries: [Entry]

    init(bookID: UUID) {
        url = Self.directory.appending(path: "\(bookID.uuidString).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
    }

    func save(_ entries: [Entry]) {
        self.entries = Array(entries.suffix(Self.limit))
        if self.entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self.entries) { try? data.write(to: url, options: .atomic) }
    }

    nonisolated static var directory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Ask", directoryHint: .isDirectory)
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
