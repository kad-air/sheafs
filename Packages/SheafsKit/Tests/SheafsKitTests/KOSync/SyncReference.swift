import Foundation

/// Access to the fixtures and to `Fixtures/sync-reference.json`, the independent second source
/// produced by `scripts/gen_sync_reference.py` (plain Python, none of this package's code).
enum SyncFixture {
    static func url(_ name: String) throws -> URL {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let url = Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures")
        else { throw FixtureError.missing(name) }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// The synthetic test bytes of the reference script: `(i * 7 + 3) % 251`.
    static func syntheticBytes(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 * 7 + 3) % 251) })
    }

    enum FixtureError: Error { case missing(String) }
}

struct SyncReference: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        var id: String
        var title: String
        var updatedEpoch: Double
        var epubHref: String?
        var thumbnailHref: String?
    }

    struct OPDSFacts: Decodable, Sendable {
        var entryCount: Int
        var feedTitle: String
        var feedUpdatedEpoch: Double
        var entries: [Entry]
        var hasNext: Bool
        var nextHref: String?
        var hasPrevious: Bool
        var previousHref: String?
        var searchHref: String?
        var searchType: String?
        var startHref: String?
    }

    struct PartialMD5Facts: Decodable, Sendable {
        var fixtures: [String: String]
        var synthetic: [String: String]
    }

    var md5: [String: String]
    var opds: OPDSFacts
    var partialMd5: PartialMD5Facts

    static func load() throws -> SyncReference {
        try JSONDecoder().decode(SyncReference.self, from: SyncFixture.data("sync-reference.json"))
    }
}
