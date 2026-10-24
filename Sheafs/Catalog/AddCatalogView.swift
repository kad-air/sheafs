import SwiftUI
import SwiftData
import SheafsKit

/// Adds an OPDS catalog, or edits `catalog` when one is passed. Presented as a sheet.
struct AddCatalogView: View {
    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    let catalog: Catalog?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlText: String
    @State private var username: String
    @State private var password: String
    @State private var test = TestState.idle
    @State private var testTask: Task<Void, Never>?

    init(catalog: Catalog? = nil) {
        self.catalog = catalog
        self.name = catalog?.name ?? ""
        self.urlText = catalog?.urlString ?? ""
        self.username = catalog?.username ?? ""
        self.password = catalog.flatMap { Keychain.get(Keychain.catalogPasswordAccount($0.id)) } ?? ""
    }

    private var url: URL? { Self.normalizedURL(urlText) }

    private var credentials: OPDSCredentials? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? nil : OPDSCredentials(username: user, password: password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("URL", text: $urlText, prompt: Text("https://books.example.com/opds"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The address of the catalog’s OPDS feed. If you leave out http:// or https://, https:// is used.")
                }
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: {
                    Text("Sign In (Optional)")
                } footer: {
                    Text("Only needed if the catalog asks for a username and password. The password is kept in the keychain.")
                }
                Section {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Text("Test")
                            Spacer()
                            if test == .testing { ProgressView() }
                        }
                    }
                    .disabled(url == nil || test == .testing)
                    testResult
                } footer: {
                    Text("Fetches the catalog and shows its title.")
                }
            }
            .navigationTitle(catalog == nil ? "Add Catalog" : "Edit Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(url == nil)
                }
            }
            .onChange(of: urlText) { resetTest() }
            .onChange(of: username) { resetTest() }
            .onChange(of: password) { resetTest() }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle, .testing:
            EmptyView()
        case .success(let title):
            Label(title.isEmpty ? "Connected" : "Connected: \(title)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: Actions

    private func resetTest() {
        testTask?.cancel()
        testTask = nil
        test = .idle
    }

    private func runTest() {
        guard let url else { return }
        let client = OPDSClient(credentials: credentials)
        test = .testing
        testTask = Task {
            do {
                let feed = try await client.feed(at: url)
                guard !Task.isCancelled else { return }
                test = .success(feed.title)
                if name.trimmingCharacters(in: .whitespaces).isEmpty { name = feed.title }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                var message = error.catalogMessage
                if !urlText.contains("://") {
                    message += " No scheme was given, so https:// was tried; for a server without HTTPS, start the address with http://."
                }
                test = .failure(message)
            }
        }
    }

    private func save() {
        guard let url else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? (url.host() ?? url.absoluteString) : trimmedName
        let user = credentials?.username
        let target: Catalog
        if let catalog {
            catalog.name = resolvedName
            catalog.urlString = url.absoluteString
            catalog.username = user
            target = catalog
        } else {
            let count = (try? modelContext.fetchCount(FetchDescriptor<Catalog>())) ?? 0
            target = Catalog(name: resolvedName, urlString: url.absoluteString, username: user, sortOrder: count)
            modelContext.insert(target)
        }
        Keychain.set(user == nil ? nil : password, account: Keychain.catalogPasswordAccount(target.id))
        try? modelContext.save()
        dismiss()
    }

    /// The URL typed, with https:// assumed when no scheme is given. Only http(s) URLs with a
    /// host are accepted.
    nonisolated static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}
