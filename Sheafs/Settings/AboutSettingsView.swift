import SwiftUI

/// App name, version, and the open standards Sheafs speaks.
struct AboutSettingsView: View {
    private var appName: String {
        info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Sheafs"
    }

    private var versionString: String {
        let version = info("CFBundleShortVersionString") ?? "?"
        let build = info("CFBundleVersion") ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("App", value: appName)
                LabeledContent("Version", value: versionString)
            }
            Section {
                Label("Sheafs is open source", systemImage: "chevron.left.forwardslash.chevron.right")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Standards")
                    Text("EPUB, OPDS 1.2, KOReader sync")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                NavigationLink("Volume Button Log") { VolumeLogView() }
            } footer: {
                Text("What the volume-button page turner saw since the app started.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}

/// `VolumeLog`'s lines, newest last, with Copy and Clear, so a device run can be read without a Mac.
struct VolumeLogView: View {
    private let log = VolumeLog.shared

    var body: some View {
        ScrollView {
            Text(log.lines.isEmpty ? "Nothing yet. Turn on Volume buttons turn pages, open a book, press the buttons, then come back here." : log.lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Volume Button Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = log.lines.joined(separator: "\n")
                }
                .disabled(log.lines.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Clear", systemImage: "trash", role: .destructive) { log.clear() }
            }
        }
    }
}
