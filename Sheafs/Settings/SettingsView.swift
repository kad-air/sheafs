import SwiftData
import SwiftUI

/// The Settings tab: a short grouped list, most-used first, each row pushing a screen with the
/// detail. Reading → the reader's appearance; Library → storage; Sync → the kosync account; About.
struct SettingsView: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(SyncService.self) private var sync
    @Query private var books: [Book]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AppearanceView(embedded: true)
                    } label: {
                        row("Appearance", systemImage: "textformat.size", value: settings.theme.title)
                    }
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Theme, font, text size, spacing and page-turn options for the reader.")
                }

                Section {
                    NavigationLink {
                        AskSettingsView()
                    } label: {
                        row("Ask About the Book", systemImage: "bubble.left.and.text.bubble.right",
                            value: settings.askEnabled ? "On" : "Off")
                    }
                } footer: {
                    Text("Spoiler-free answers about plot and characters from Apple’s on-device model.")
                }

                Section("Library") {
                    NavigationLink {
                        LibrarySettingsView()
                    } label: {
                        row("Storage", systemImage: "books.vertical", value: books.count.formatted())
                    }
                }

                Section("Sync & Accounts") {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        row("Reading Position Sync", systemImage: "arrow.triangle.2.circlepath",
                            value: sync.isEnabled ? "On" : "Off")
                    }
                }

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        Label("About Sheafs", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
