import SwiftData
import SwiftUI

/// Informational: how many books are in the library and how much disk they and their covers use.
struct LibrarySettingsSection: View {
    @Environment(LibraryStore.self) private var library
    @Query private var books: [Book]
    @State private var bytesUsed: Int64?

    var body: some View {
        Section {
            LabeledContent("Books", value: books.count.formatted())
            LabeledContent("Space Used") {
                if let bytesUsed {
                    Text(bytesUsed, format: .byteCount(style: .file))
                } else {
                    ProgressView()
                }
            }
        } header: {
            Text("Library")
        } footer: {
            Text("EPUB files and cover images stored on this device.")
        }
        .task(id: books.count) {
            bytesUsed = await LibraryDiskUsage.measure([library.booksDirectory, library.coversDirectory])
        }
    }
}

enum LibraryDiskUsage {
    /// Total size on disk of everything under `directories`, computed off the main actor.
    static func measure(_ directories: [URL]) async -> Int64 {
        await Task.detached(priority: .utility) { LibraryDiskUsage.bytes(in: directories) }.value
    }

    nonisolated static func bytes(in directories: [URL]) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        for directory in directories {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { continue }
            while let url = walker.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }
}
