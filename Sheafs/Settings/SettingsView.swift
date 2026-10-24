import SwiftUI

/// The Settings tab: sync account, reading appearance, library storage and an About block.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                SyncSettingsSection()
                appearanceSection
                LibrarySettingsSection()
                AboutSettingsSection()
            }
            .navigationTitle("Settings")
        }
    }

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                AppearanceView(embedded: true)
            } label: {
                Label("Appearance", systemImage: "textformat.size")
            }
        } footer: {
            Text("Theme, font, text size, spacing and page-turn options for the reader.")
        }
    }
}
