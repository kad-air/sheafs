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
                    Task { await library.importFromOutside(url) }
                }
                .task { await library.importFromDocuments() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await library.importFromDocuments() } }
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
}

enum AppTab: Hashable { case library, catalogs, settings }
