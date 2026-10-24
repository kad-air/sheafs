import SwiftUI

/// The Settings → Reading Position Sync screen: the KOReader-protocol ("kosync") account, with Test
/// and Register.
struct SyncSettingsView: View {
    @Environment(SyncService.self) private var sync

    private enum Field: Hashable { case server, user, password, device }
    private enum Operation { case testing, registering }

    /// Local copy of the keychain-backed password, so the field never reads the keychain per render.
    @State private var password = ""
    @State private var operation: Operation?
    @FocusState private var focus: Field?

    var body: some View {
        @Bindable var sync = sync
        Form {
            Section {
                Toggle("Sync Reading Position", isOn: $sync.isEnabled)
            } footer: {
                Text("The same account works with KOReader and other readers that speak its sync protocol. A book's position is keyed by the bytes of its file, so the same file must be on every device.")
            }

            Section("Account") {
                LabeledContent("Server URL") {
                    TextField("Server URL", text: $sync.serverURLString, prompt: Text("https://example.com/kosync/"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .submitLabel(.next)
                        .focused($focus, equals: .server)
                }
                LabeledContent("User Name") {
                    TextField("User Name", text: $sync.username, prompt: Text("Required"))
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .submitLabel(.next)
                        .focused($focus, equals: .user)
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $password, prompt: Text("Required"))
                        .textContentType(.password)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .submitLabel(.next)
                        .focused($focus, equals: .password)
                }
            }

            Section {
                LabeledContent("Device Name") {
                    TextField("Device Name", text: $sync.deviceName, prompt: Text(SyncService.defaultDeviceName))
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .submitLabel(.done)
                        .focused($focus, equals: .device)
                }
            } footer: {
                Text("How this device appears to the sync server.")
            }

            Section {
                actionButton("Test Connection", systemImage: "checkmark.shield", operation: .testing)
                actionButton("Register Account", systemImage: "person.crop.circle.badge.plus", operation: .registering)
                statusRow
            }
        }
        .navigationTitle("Reading Position Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onSubmit(advanceFocus)
        .onAppear { password = sync.password }
        .onChange(of: password) { _, newValue in sync.password = newValue }
        .onChange(of: credentials) { _, _ in
            // Whatever the last check said no longer applies to what is typed now.
            sync.lastError = nil
            sync.lastSuccess = nil
        }
        .onChange(of: focus) { old, _ in
            if old == .device { restoreBlankDeviceName() }
        }
        .onDisappear(perform: restoreBlankDeviceName)
    }

    // MARK: Rows

    private func actionButton(_ title: LocalizedStringKey, systemImage: String, operation target: Operation) -> some View {
        Button {
            run(target)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if operation == target { ProgressView() }
            }
        }
        .disabled(operation != nil)
    }

    @ViewBuilder private var statusRow: some View {
        if let error = sync.lastError {
            Label {
                Text(error).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        } else if let checked = sync.lastSuccess {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected as \(sync.username)")
                    Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    // MARK: Behaviour

    /// Everything the status row depends on, so editing any of it clears a stale result.
    private var credentials: [String] { [sync.serverURLString, sync.username, password] }

    /// Why the form can't be submitted yet, in words for the status row. Nil when it can.
    private var inputProblem: String? {
        let address = sync.serverURLString.trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return "Enter the sync server address." }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else {
            return "The server address must start with http:// or https://."
        }
        if sync.username.isEmpty { return "Enter your user name." }
        if password.isEmpty { return "Enter your password." }
        return nil
    }

    private func run(_ target: Operation) {
        focus = nil
        sync.lastError = nil
        sync.lastSuccess = nil
        if let problem = inputProblem {
            sync.lastError = problem
            return
        }
        operation = target
        Task {
            switch target {
            case .testing:
                if await !sync.testConnection() { sync.lastSuccess = nil }
            case .registering:
                do {
                    try await sync.registerAndAuthorize()
                } catch {
                    sync.lastError = "\(error)"
                    sync.lastSuccess = nil
                }
            }
            operation = nil
        }
    }

    private func advanceFocus() {
        switch focus {
        case .server: focus = .user
        case .user: focus = .password
        case .password: focus = .device
        case .device, nil: focus = nil
        }
    }

    private func restoreBlankDeviceName() {
        if sync.deviceName.trimmingCharacters(in: .whitespaces).isEmpty {
            sync.deviceName = SyncService.defaultDeviceName
        }
    }
}
