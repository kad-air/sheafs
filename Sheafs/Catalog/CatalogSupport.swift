import SwiftUI
import SheafsKit

/// What the catalog screens need to talk to one catalog: a name for the library's "from"
/// field and a client that carries the catalog's credentials.
struct CatalogConnection {
    let name: String
    let client: OPDSClient

    init(name: String, credentials: OPDSCredentials?) {
        self.name = name
        self.client = OPDSClient(credentials: credentials)
    }

    /// Reads the password from the keychain.
    init(_ catalog: Catalog) {
        let username = catalog.username ?? ""
        let password = Keychain.get(Keychain.catalogPasswordAccount(catalog.id)) ?? ""
        self.init(name: catalog.name,
                  credentials: username.isEmpty ? nil : OPDSCredentials(username: username, password: password))
    }

    /// A cover request that carries the catalog's Basic auth. Covers rarely change, so a cached
    /// copy wins over the network.
    func imageRequest(for url: URL) -> URLRequest {
        var request = client.request(for: url, accept: "image/*,*/*;q=0.5")
        request.cachePolicy = .returnCacheDataElseLoad
        return request
    }
}

extension Error {
    /// `OPDSError` is only `CustomStringConvertible`, so `localizedDescription` would be useless.
    var catalogMessage: String {
        (self as? OPDSError)?.description ?? localizedDescription
    }
}

/// A 2:3 cover loaded through the catalog's authenticated client, with a typeset placeholder
/// (title and author) while loading, when it fails, and when the entry has no image.
struct CatalogCoverView: View {
    let title: String
    let author: String?
    let url: URL?
    let connection: CatalogConnection

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(request: connection.imageRequest(for: url)) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let hue = Self.hue(for: title)
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.55),
                                    Color(hue: hue, saturation: 0.45, brightness: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(4)
                if let author, !author.isEmpty {
                    Text(author)
                        .font(.system(.caption, design: .serif))
                        .opacity(0.85)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Stable across launches (unlike `hashValue`), so a book keeps its colour.
    nonisolated static func hue(for title: String) -> Double {
        let sum = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Double(sum) / 360
    }
}

/// "In Library" marker laid over a cover.
struct InLibraryBadge: View {
    /// The catalog's file is newer than the library's copy (`OPDSEntry.isNewer(than:)`).
    var updateAvailable = false

    var body: some View {
        Label(updateAvailable ? "Update" : "In Library",
              systemImage: updateAvailable ? "arrow.triangle.2.circlepath" : "checkmark")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }
}
