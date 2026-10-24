import SwiftUI
import SwiftData

@main
struct SheafsApp: App {
    @State private var library = LibraryStore()
    @State private var settings = ReaderSettings()
    @State private var navigation = AppNavigation()
    @State private var sync = SyncService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(settings)
                .environment(navigation)
                .environment(sync)
                .onOpenURL { url in
                    if let id = SheafsLink.bookID(in: url) { navigation.open(bookWithID: id, in: library) }
                    else { Task { await library.importFromOutside(url) } }
                }
                .task {
                    await library.importFromDocuments()
                    library.publishRecentBook(force: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await library.importFromDocuments()
                        library.publishRecentBook(force: true)
                    }
                }
        }
        .modelContainer(library.container)
    }
}

/// App-wide navigation state: which book is open in the reader, pending alerts.
@Observable
final class AppNavigation {
    var openBook: Book?
    var importError: String?
    var selectedTab: AppTab = .library

    func open(_ book: Book) { openBook = book }

    /// The widget's tap: open that book in the reader, from any tab (a deleted book does nothing).
    func open(bookWithID id: UUID, in library: LibraryStore) {
        let fetch = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        guard let book = try? library.context.fetch(fetch).first else { return }
        selectedTab = .library
        openBook = book
    }
}

enum AppTab: Hashable { case library, catalogs, settings }
