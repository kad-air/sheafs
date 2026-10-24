import Foundation
import SwiftData

/// A book in the library. The EPUB file itself lives at `LibraryStore.fileURL(for:)`.
@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    var language: String?
    var fileSize: Int
    /// KOReader-protocol document key: partial MD5 of the file bytes. Nil until computed.
    var partialMD5: String?
    var hasCover: Bool
    var addedAt: Date
    var lastOpenedAt: Date?
    var finishedAt: Date?

    // Reading position
    /// 0...1 over the whole book's text.
    var progress: Double
    var spineIndex: Int
    /// UTF-16 offset of the first character on the current page within its chapter.
    var textOffset: Int
    /// The CREngine xpointer for the current position, as sent to the sync server.
    var xpointer: String?
    /// Last time a position was pushed to or pulled from the sync server.
    var lastSyncedAt: Date?
    /// The xpointer that was last pushed or pulled, to tell "no local change" from "moved".
    var lastSyncedPointer: String?

    /// Where it came from, when downloaded from a catalog.
    var sourceURL: String?
    var catalogName: String?

    init(id: UUID = UUID(), title: String, author: String?, language: String?, fileSize: Int,
         partialMD5: String?, hasCover: Bool, sourceURL: String? = nil, catalogName: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.language = language
        self.fileSize = fileSize
        self.partialMD5 = partialMD5
        self.hasCover = hasCover
        self.addedAt = .now
        self.progress = 0
        self.spineIndex = 0
        self.textOffset = 0
        self.sourceURL = sourceURL
        self.catalogName = catalogName
    }

    var isFinished: Bool { finishedAt != nil }
    var percentLabel: String { progress.formatted(.percent.precision(.fractionLength(0))) }
}

/// A saved OPDS catalog. The password, if any, is in the keychain under `Keychain.catalogPassword(id)`.
@Model
final class Catalog {
    @Attribute(.unique) var id: UUID
    var name: String
    var urlString: String
    var username: String?
    var addedAt: Date
    var sortOrder: Int

    init(id: UUID = UUID(), name: String, urlString: String, username: String?, sortOrder: Int) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.username = username
        self.addedAt = .now
        self.sortOrder = sortOrder
    }

    var url: URL? { URL(string: urlString) }
}
