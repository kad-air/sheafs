import SwiftUI

/// The seam for a build that adds features of its own to Sheafs: an Ask provider for a book,
/// screens in Settings and the library, and items in a book's menu. Sheafs itself has no plugin:
/// `Plugins.current` stays nil and every extension point shows nothing.
///
/// A build with one compiles its sources into the app target and sets the Swift compile condition
/// `SHEAFS_PLUGIN`; `SheafsApp.init` then calls the `makeSheafsPlugin(_:)` those sources define,
/// once, before any view appears. Every requirement has a default, so a plugin implements only
/// what it adds.
@MainActor
protocol SheafsPlugin: AnyObject {
    /// Answers Ask's questions about the book in place of the on-device model; nil leaves them to
    /// it. Asked when the reader makes its Ask model (`AskModel.init`), once per opening.
    func askProvider(for context: AskProviderContext) -> (any AskProvider)?
    /// Rows in a Settings section of their own, after Ask; each pushes its screen.
    var settingsScreens: [PluginScreen] { get }
    /// Buttons in the library's toolbar; each opens its screen as a sheet.
    var libraryScreens: [PluginScreen] { get }
    /// Items in a book's menu in the library, after Sheafs' own and before Delete.
    func bookActions(for book: Book) -> [PluginAction]
}

extension SheafsPlugin {
    func askProvider(for context: AskProviderContext) -> (any AskProvider)? { nil }
    var settingsScreens: [PluginScreen] { [] }
    var libraryScreens: [PluginScreen] { [] }
    func bookActions(for book: Book) -> [PluginAction] { [] }
}

/// What the app hands its plugin: the same library and position sync the app's screens use.
struct PluginHost {
    let library: LibraryStore
    let sync: SyncService
}

/// This build's plugin, if it has one (set once by `SheafsApp.init`).
enum Plugins {
    static var current: (any SheafsPlugin)?
}

/// A screen a plugin adds, with the row or button that opens it.
struct PluginScreen: Identifiable {
    let id: String
    var title: String
    var systemImage: String
    /// Shown at the end of its Settings row ("On", a server's name).
    var value: String?
    let content: () -> AnyView

    init<Content: View>(id: String, title: String, systemImage: String, value: String? = nil,
                        @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.content = { AnyView(content()) }
    }
}

/// An item a plugin adds to a book's menu: something to do, or a screen to open as a sheet.
struct PluginAction: Identifiable {
    enum Kind {
        case perform(() -> Void)
        case screen(PluginScreen)
    }

    let id: String
    var title: String
    var systemImage: String
    var kind: Kind
}

/// A plugin's screen in a sheet: its own navigation stack, its title, and a close button.
struct PluginSheet: View {
    let screen: PluginScreen
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            screen.content()
                .navigationTitle(screen.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                    }
                }
        }
    }
}
