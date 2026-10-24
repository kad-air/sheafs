import SwiftUI

/// App name, version, and the open standards Sheafs speaks.
struct AboutSettingsSection: View {
    private var appName: String {
        info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Sheafs"
    }

    private var versionString: String {
        let version = info("CFBundleShortVersionString") ?? "?"
        let build = info("CFBundleVersion") ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        Section("About") {
            LabeledContent("App", value: appName)
            LabeledContent("Version", value: versionString)
            Label("Sheafs is open source", systemImage: "chevron.left.forwardslash.chevron.right")
            VStack(alignment: .leading, spacing: 2) {
                Text("Open Standards")
                Text("EPUB, OPDS 1.2, KOReader sync")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
