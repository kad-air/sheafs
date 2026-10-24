import CryptoKit
import Foundation

/// Where a kosync server lives and who is talking to it.
public struct KOSyncCredentials: Hashable, Sendable, CustomStringConvertible {
    /// The server's base URL. It may carry a path (`https://example.com/kosync/`), with or
    /// without a trailing slash.
    public var serverURL: URL
    public var username: String
    /// The plain password. Only its MD5 ever leaves the device, as the protocol requires.
    public var password: String

    public init(serverURL: URL, username: String, password: String) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }

    /// Never includes the password, so credentials are safe to log.
    public var description: String {
        "KOSyncCredentials(serverURL: \(serverURL.absoluteString), username: \(username), password: <redacted>)"
    }
}

/// A reading position as stored on a kosync server. Its `Codable` form is the protocol's JSON
/// (`device_id`, integer-second `timestamp`).
public struct KOSyncProgress: Hashable, Sendable, Codable {
    /// The document key, normally ``PartialMD5``.
    public var document: String
    /// Opaque to the server and to this client: an EPUB xpointer for most clients. Store and
    /// send it untouched.
    public var progress: String
    /// 0...1 through the book.
    public var percentage: Double
    /// The name of the device that wrote this position.
    public var device: String?
    /// The identifier of the device that wrote this position (JSON key `device_id`).
    public var deviceID: String?
    /// When the server stored it.
    public var timestamp: Date?

    public init(
        document: String,
        progress: String,
        percentage: Double,
        device: String? = nil,
        deviceID: String? = nil,
        timestamp: Date? = nil
    ) {
        self.document = document
        self.progress = progress
        self.percentage = percentage
        self.device = device
        self.deviceID = deviceID
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case document, progress, percentage, device, timestamp
        case deviceID = "device_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        document = try container.decode(String.self, forKey: .document)
        progress = try container.decode(String.self, forKey: .progress)
        percentage = try container.decode(Double.self, forKey: .percentage)
        device = try container.decodeIfPresent(String.self, forKey: .device)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
            .map { Date(timeIntervalSince1970: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(document, forKey: .document)
        try container.encode(progress, forKey: .progress)
        try container.encode(percentage, forKey: .percentage)
        try container.encodeIfPresent(device, forKey: .device)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(timestamp.map { Int($0.timeIntervalSince1970) }, forKey: .timestamp)
    }
}

/// Errors thrown by ``KOSyncClient``.
public enum KOSyncError: Error, CustomStringConvertible {
    /// The server rejected the username or password (HTTP 401).
    case unauthorized
    /// Registration failed because the username exists (HTTP 402). Try ``KOSyncClient/authorize()``.
    case usernameTaken
    /// The server URL is not an http(s) URL with a host.
    case invalidServerURL
    /// The server answered with an unexpected status; `message` is its `{"message": ...}` if any.
    case server(status: Int, message: String?)
    /// The server answered 2xx but the body was not what the protocol promises.
    case invalidResponse
    /// The request failed before a response arrived.
    case network(underlying: Error)

    public var description: String {
        switch self {
        case .unauthorized:
            return "The sync server rejected the username or password."
        case .usernameTaken:
            return "That username is already registered on the sync server."
        case .invalidServerURL:
            return "The sync server address is not a valid http or https URL."
        case .server(let status, let message):
            return "The sync server answered HTTP \(status)" + (message.map { ": \($0)" } ?? ".")
        case .invalidResponse:
            return "The sync server sent a response that could not be understood."
        case .network(let underlying):
            return "The sync server could not be reached: \(underlying.localizedDescription)"
        }
    }
}

/// A client for the vanilla KOReader sync ("kosync") protocol.
///
/// Authentication is the protocol's own: every request carries `x-auth-user` and
/// `x-auth-key`, where the key is the lowercase hex MD5 of the password, computed here. That is
/// the wire format and is not something to strengthen on the client.
public struct KOSyncClient: Sendable {
    private static let acceptHeader = "application/vnd.koreader.v1+json"

    private let credentials: KOSyncCredentials
    private let device: String
    private let deviceID: String
    private let session: URLSession

    /// - Parameters:
    ///   - device: A human name for this device, stored with every position written.
    ///   - deviceID: A stable identifier for this install.
    public init(credentials: KOSyncCredentials, device: String, deviceID: String, session: URLSession = .shared) {
        self.credentials = credentials
        self.device = device
        self.deviceID = deviceID
        self.session = session
    }

    /// The `x-auth-key` for `password`: 32 lowercase hex characters of its MD5.
    public static func authKey(for password: String) -> String {
        PartialMD5.hexString(Insecure.MD5.hash(data: Data(password.utf8)))
    }

    /// `GET /healthcheck`. True when the server reports `{"state": "OK"}`.
    public func healthcheck() async throws -> Bool {
        let (status, data) = try await send("GET", "healthcheck", authorized: false)
        guard (200..<300).contains(status) else { throw serverError(status, data) }
        return (try? JSONDecoder().decode(HealthBody.self, from: data))?.state == "OK"
    }

    /// `POST /users/create`. Returns normally when the account was created.
    ///
    /// - Throws: ``KOSyncError/usernameTaken`` when the name exists; callers then try ``authorize()``.
    public func register() async throws {
        let body = try Self.makeEncoder().encode(
            RegisterBody(username: credentials.username, password: Self.authKey(for: credentials.password))
        )
        let (status, data) = try await send("POST", "users/create", body: body, authorized: false)
        if status == 402 { throw KOSyncError.usernameTaken }
        guard (200..<300).contains(status) else { throw serverError(status, data) }
    }

    /// `GET /users/auth`. Returns normally when the username and password are accepted.
    ///
    /// - Throws: ``KOSyncError/unauthorized`` on 401.
    public func authorize() async throws {
        let (status, data) = try await send("GET", "users/auth", authorized: true)
        if status == 401 { throw KOSyncError.unauthorized }
        guard (200..<300).contains(status) else { throw serverError(status, data) }
    }

    /// `GET /syncs/progress/{document}`: the stored position, or nil when the server has none.
    ///
    /// Besides the protocol's `200 {}`, a 404 is also read as "nothing stored", which is how some
    /// other kosync servers answer.
    public func progress(for document: String) async throws -> KOSyncProgress? {
        let (status, data) = try await send("GET", "syncs/progress/" + Self.encodeSegment(document), authorized: true)
        if status == 401 { throw KOSyncError.unauthorized }
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw serverError(status, data) }
        guard let wire = try? JSONDecoder().decode(ProgressWire.self, from: data) else {
            throw KOSyncError.invalidResponse
        }
        guard let stored = wire.progress else { return nil }  // `{}`: nothing stored yet
        return KOSyncProgress(
            document: wire.document ?? document,
            progress: stored,
            percentage: wire.percentage ?? 0,
            device: wire.device,
            deviceID: wire.deviceID,
            timestamp: wire.timestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// `PUT /syncs/progress`. Sends `progress` with this client's device name and id (whatever
    /// the value carries) and returns the server's timestamp for it.
    public func update(_ progress: KOSyncProgress) async throws -> Date {
        let body = try Self.makeEncoder().encode(
            UpdateBody(
                document: progress.document,
                progress: progress.progress,
                percentage: progress.percentage,
                device: device,
                deviceID: deviceID
            )
        )
        let (status, data) = try await send("PUT", "syncs/progress", body: body, authorized: true)
        if status == 401 { throw KOSyncError.unauthorized }
        guard (200..<300).contains(status) else { throw serverError(status, data) }
        guard let seconds = (try? JSONDecoder().decode(ProgressWire.self, from: data))?.timestamp else {
            throw KOSyncError.invalidResponse
        }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Wire types

    private struct HealthBody: Decodable {
        var state: String?
    }

    private struct MessageBody: Decodable {
        var message: String?
    }

    private struct RegisterBody: Encodable {
        var username: String
        var password: String
    }

    private struct UpdateBody: Encodable {
        var document: String
        var progress: String
        var percentage: Double
        var device: String
        var deviceID: String

        private enum CodingKeys: String, CodingKey {
            case document, progress, percentage, device
            case deviceID = "device_id"
        }
    }

    private struct ProgressWire: Decodable {
        var document: String?
        var progress: String?
        var percentage: Double?
        var device: String?
        var deviceID: String?
        var timestamp: Double?

        private enum CodingKeys: String, CodingKey {
            case document, progress, percentage, device, timestamp
            case deviceID = "device_id"
        }
    }

    // MARK: - Transport

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// Percent-encodes everything but unreserved characters, so a document name containing `/`,
    /// `?`, `#` or `%` stays a single path segment.
    private static func encodeSegment(_ segment: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? segment
    }

    /// `serverURL` + `/` + `path` (already percent-encoded), however the base ends.
    private func url(for path: String) throws -> URL {
        guard var components = URLComponents(url: credentials.serverURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { throw KOSyncError.invalidServerURL }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/" + path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw KOSyncError.invalidServerURL }
        return url
    }

    private func send(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        authorized: Bool
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue("Sheafs/1.0", forHTTPHeaderField: "User-Agent")
        if authorized {
            request.setValue(credentials.username, forHTTPHeaderField: "x-auth-user")
            request.setValue(Self.authKey(for: credentials.password), forHTTPHeaderField: "x-auth-key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KOSyncError.invalidResponse }
            return (http.statusCode, data)
        } catch let error as KOSyncError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw KOSyncError.network(underlying: error)
        }
    }

    private func serverError(_ status: Int, _ data: Data) -> KOSyncError {
        if status == 401 { return .unauthorized }
        let message = (try? JSONDecoder().decode(MessageBody.self, from: data))?.message
        return .server(status: status, message: message)
    }
}
