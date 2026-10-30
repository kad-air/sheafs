import SwiftUI
import SwiftData

/// The saved OPDS catalogs. Tapping one browses it; swipe to edit or delete, press and drag to
/// reorder.
struct CatalogsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Catalog.sortOrder) private var catalogs: [Catalog]
    @State private var showAdd = false
    @State private var editing: Catalog?

    var body: some View {
        NavigationStack {
            Group {
                if catalogs.isEmpty {
                    ContentUnavailableView {
                        Label("No Catalogs", systemImage: "square.grid.2x2")
                    } description: {
                        Text("An OPDS catalog is an online library your reader can browse and download EPUBs from. Add the address of a self-hosted server, or put back the free Standard Ebooks and Project Gutenberg catalogs.")
                    } actions: {
                        Button("Add Catalog", systemImage: "plus") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Catalogs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Catalog", systemImage: "plus") { showAdd = true }
                }
                .visibilityPriority(.high)
            }
            .sheet(isPresented: $showAdd) { AddCatalogView() }
            .sheet(item: $editing) { AddCatalogView(catalog: $0) }
#if DEBUG
            .navigationDestination(item: $launchBrowse) { catalog in
                if let url = catalog.url {
                    CatalogBrowserView(url: url, title: catalog.name, connection: CatalogConnection(catalog))
                }
            }
            .task {
                // `-SheafsBrowse <name fragment>` (screenshots): opens the first matching catalog once.
                guard !Self.browseArgumentConsumed, let wanted = UserDefaults.standard.string(forKey: "SheafsBrowse") else { return }
                Self.browseArgumentConsumed = true
                launchBrowse = catalogs.first { $0.name.localizedCaseInsensitiveContains(wanted) }
                print("[catalog] browse \"\(wanted)\" → \(launchBrowse?.name ?? "nothing"); catalogs: \(catalogs.map(\.name))")
            }
#endif
        }
    }

#if DEBUG
    @State private var launchBrowse: Catalog?
    private static var browseArgumentConsumed = false
#endif

    private var list: some View {
        List {
            ForEach(catalogs) { catalog in
                row(for: catalog)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(catalog) }
                        Button("Edit", systemImage: "pencil") { editing = catalog }
                            .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = catalog }
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(catalog) }
                    }
            }
            .reorderable()
        }
        .reorderContainer(for: Catalog.self) { difference in
            var ordered = catalogs
            difference.apply(to: &ordered)
            renumber(ordered)
        }
    }

    @ViewBuilder
    private func row(for catalog: Catalog) -> some View {
        if let url = catalog.url {
            NavigationLink {
                CatalogBrowserView(url: url, title: catalog.name, connection: CatalogConnection(catalog))
            } label: {
                CatalogRowView(catalog: catalog)
            }
        } else {
            CatalogRowView(catalog: catalog)
                .foregroundStyle(.secondary)
        }
    }

    private func delete(_ catalog: Catalog) {
        Keychain.set(nil, account: Keychain.catalogPasswordAccount(catalog.id))
        modelContext.delete(catalog)
        renumber(catalogs.filter { $0 !== catalog })
        try? modelContext.save()
    }

    /// Keeps `sortOrder` contiguous so a new catalog (sortOrder = count) always lands last.
    private func renumber(_ ordered: [Catalog]) {
        for (index, catalog) in ordered.enumerated() where catalog.sortOrder != index {
            catalog.sortOrder = index
        }
        try? modelContext.save()
    }
}

private struct CatalogRowView: View {
    let catalog: Catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(catalog.name)
                .font(.headline)
            Text(catalog.url?.host() ?? catalog.urlString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
    /// Moves `sources` to `destination` within `collection`.
    func apply<C>(to collection: inout C) where C: RangeReplaceableCollection, C.Element: Identifiable, C.Element.ID == ItemID {
        let moving = Set(sources)
        guard !moving.isEmpty else { return }
        var moved: [C.Element] = []
        collection.removeAll { element in
            guard moving.contains(element.id) else { return false }
            moved.append(element)
            return true
        }
        switch destination.position {
        case .before(let id):
            let index = collection.firstIndex { $0.id == id } ?? collection.endIndex
            collection.insert(contentsOf: moved, at: index)
        case .end:
            collection.append(contentsOf: moved)
        }
    }
}
