import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selectedTab) {
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryView()
            }
            Tab("Catalogs", systemImage: "square.grid.2x2", value: AppTab.catalogs) {
                CatalogsView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .fullScreenCover(item: $navigation.openBook) { book in
            ReaderView(book: book)
        }
        .alert("Couldn't Add Book", isPresented: Binding(
            get: { navigation.importError != nil },
            set: { if !$0 { navigation.importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(navigation.importError ?? "")
        }
        .onChange(of: library.lastImportError) { _, error in
            if let error { navigation.importError = error }
        }
        .task { await openFromLaunchArguments() }
    }

    /// Launch arguments for screenshots and testing: `-SheafsCatalogURL <url>` (with an optional
    /// `-SheafsCatalogName <name>`) adds a catalog once, and `-SheafsOpen <title fragment>` opens
    /// the first matching book.
    private func openFromLaunchArguments() async {
        let defaults = UserDefaults.standard
        if let urlString = defaults.string(forKey: "SheafsCatalogURL"), URL(string: urlString) != nil {
            let existing = (try? library.context.fetch(FetchDescriptor<Catalog>())) ?? []
            if !existing.contains(where: { $0.urlString == urlString }) {
                let name = defaults.string(forKey: "SheafsCatalogName") ?? (URL(string: urlString)?.host() ?? "Catalog")
                library.context.insert(Catalog(name: name, urlString: urlString, username: nil, sortOrder: existing.count))
                library.save()
            }
        }
        guard let wanted = defaults.string(forKey: "SheafsOpen"), !wanted.isEmpty else { return }
        // Give a Documents import a moment to land first.
        try? await Task.sleep(for: .milliseconds(800))
        let books = (try? library.context.fetch(FetchDescriptor<Book>())) ?? []
        if let book = books.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) {
            print("[open] \"\(wanted)\" → \"\(book.title)\"")
            navigation.open(book)
        } else {
            // Scripts wait on this line rather than on a library that never opens a book.
            print("[open] no book in the library matches \"\(wanted)\"; titles: \(books.map { "\"\($0.title)\"" }.joined(separator: ", "))")
        }
    }
}
