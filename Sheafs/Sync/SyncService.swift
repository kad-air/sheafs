import Foundation
import SwiftUI
import SheafsKit
import UIKit
import os

/// KOReader-protocol position sync: settings plus push/pull for one book at a time.
@Observable
final class SyncService {
    var serverURLString: String { didSet { save() } }
    var username: String { didSet { save() } }
    var deviceName: String { didSet { save() } }
    var isEnabled: Bool { didSet { save() } }
    /// The last error shown in Settings, if any.
    var lastError: String?
    var lastSuccess: Date?

    private static let defaultsKey = "sync.settings.v1"
    private let log = Logger(subsystem: "io.sheafs.reader", category: "sync")

    struct Stored: Codable {
        var serverURLString = ""
        var username = ""
        var deviceName = ""
        var isEnabled = false
        var deviceID = UUID().uuidString.lowercased()
    }

    private(set) var deviceID: String

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        serverURLString = stored.serverURLString
        username = stored.username
        deviceName = stored.deviceName.isEmpty ? SyncService.defaultDeviceName : stored.deviceName
        isEnabled = stored.isEnabled
        deviceID = stored.deviceID
        if UserDefaults.standard.data(forKey: Self.defaultsKey) == nil { save() }
    }

    static var defaultDeviceName: String { "Sheafs on \(UIDevice.current.name)" }

    private func save() {
        let stored = Stored(serverURLString: serverURLString, username: username, deviceName: deviceName,
                            isEnabled: isEnabled, deviceID: deviceID)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    var password: String {
        get { Keychain.get(Keychain.syncPasswordAccount) ?? "" }
        set { Keychain.set(newValue, account: Keychain.syncPasswordAccount) }
    }

    var isConfigured: Bool {
        isEnabled && client != nil
    }

    var client: KOSyncClient? {
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil, !username.isEmpty, !password.isEmpty else { return nil }
        return KOSyncClient(credentials: KOSyncCredentials(serverURL: url, username: username, password: password),
                            device: deviceName, deviceID: deviceID)
    }

    // MARK: Account

    /// Registers the account (harmless if it already exists) and checks the credentials.
    func registerAndAuthorize() async throws {
        guard let client else { throw KOSyncError.invalidServerURL }
        do {
            try await client.register()
        } catch KOSyncError.usernameTaken {
            // Fine: the account exists; authorize below decides whether the password matches.
        }
        try await client.authorize()
        lastSuccess = .now
        lastError = nil
    }

    func testConnection() async -> Bool {
        guard let client else { lastError = "Enter a server address, user name and password."; return false }
        do {
            try await client.authorize()
            lastError = nil
            lastSuccess = .now
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    // MARK: Positions

    /// The server's position for a book, or nil when nothing is stored or sync is off.
    func pull(for book: Book) async -> KOSyncProgress? {
        guard isConfigured, let client, let key = book.partialMD5 else { return nil }
        do {
            let remote = try await client.progress(for: key)
            lastError = nil
            if let remote { log.info("pulled \(remote.percentage) from \(remote.device ?? "?", privacy: .public) for \(book.title, privacy: .public)") }
            return remote
        } catch {
            log.error("pull failed: \(error)")
            lastError = "\(error)"
            return nil
        }
    }

    /// Sends the book's current position. Quiet on failure (logged, surfaced in Settings).
    func push(for book: Book) async {
        guard isConfigured, let client, let key = book.partialMD5, let pointer = book.xpointer else { return }
        let progress = KOSyncProgress(document: key, progress: pointer, percentage: book.progress,
                                      device: deviceName, deviceID: deviceID, timestamp: nil)
        do {
            let stamp = try await client.update(progress)
            book.lastSyncedAt = stamp
            book.lastSyncedPointer = pointer
            lastError = nil
            lastSuccess = .now
            log.info("pushed \(book.progress) for \(book.title, privacy: .public)")
        } catch {
            log.error("push failed: \(error)")
            lastError = "\(error)"
        }
    }
}
