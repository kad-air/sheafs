import SwiftUI

/// Input Debug, presented full screen (no edge-swipe back, no swipe-down dismiss, which a remote's
/// synthesized swipes could trigger): hidden in Settings → About (tap the version row 5 times) or
/// opened at launch with `-SheafsInputDebug`.
struct InputDebugScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InputDebugView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Logs everything an input device sends (a Bluetooth page-turner remote, a keyboard, a mouse…)
/// so each button can be seen before it is mapped to anything: presses, key commands,
/// GameController, volume, media commands, touches and gestures, one timestamped row each.
/// The whole screen behind the controls is the touch area.
struct InputDebugView: View {
    @State private var session = InputDebugSession()
    @State private var copied = false

    private var log: InputDebugLog { session.log }

    var body: some View {
        ZStack {
            InputCaptureView(session: session)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                header
                    .allowsHitTesting(false)
                controls
                logList
                    // Recording: touches over the log reach the capture view. Paused: scroll it.
                    .allowsHitTesting(log.isPaused)
            }
            .padding(.horizontal)
        }
        .navigationTitle("Input Debug")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(log.isPaused ? "Resume" : "Pause", systemImage: log.isPaused ? "play.fill" : "pause.fill") {
                    log.setPaused(!log.isPaused)
                }
                Button("Copy All", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = log.text(header: session.exportHeader())
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(log.rows.isEmpty)
                Button("Clear", systemImage: "trash", role: .destructive) { log.clear() }
            }
        }
        .onDisappear { session.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(session.deviceLines, id: \.self) { line in
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("Press the remote's buttons; tap and swipe anywhere behind the controls.")
            Text("first responder \(session.isFirstResponder ? "yes" : "NO") · rows \(log.rows.count)/\(log.limit)\(log.isPaused ? " · PAUSED" : "")")
                .foregroundStyle(session.isFirstResponder ? Color.secondary : Color.red)
        }
        .font(.caption2.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Priority keys", systemImage: "keyboard", isOn: Binding(
                    get: { session.priorityKeys },
                    set: { session.priorityKeys = $0; log.add(.note, "priorityKeys=\($0)") }
                ))
                Toggle("Now Playing", systemImage: "music.note", isOn: Binding(
                    get: { session.nowPlaying },
                    set: { session.setNowPlaying($0) }
                ))
            }
            .toggleStyle(.button)
            .font(.caption)
            Text("Now pressing:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Now pressing", selection: Binding(get: { log.tag }, set: { log.setTag($0) })) {
                Text("none").tag(InputTag?.none)
                ForEach(InputTag.allCases) { tag in
                    Text(tag.rawValue).tag(Optional(tag))
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // Two lines a row, the message indented, so wrapped rows still scan on the
                    // narrow cover display; Copy All writes each as one line.
                    ForEach(log.rows) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.prefix())
                                .foregroundStyle(.secondary)
                            Text(row.message)
                                .foregroundStyle(row.source == .note ? Color.secondary : Color.primary)
                                .padding(.leading, 12)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(row.id)
                    }
                }
                .font(.caption2.monospaced())
                .textSelection(.enabled)
            }
            .onChange(of: log.rows.last?.id) { _, last in
                guard let last, !log.isPaused else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }
}
