import Foundation
import Testing

import SheafsKit

extension KOSyncError {
    /// A short name for the case, so failures read clearly in test output.
    var kind: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .usernameTaken: "usernameTaken"
        case .invalidServerURL: "invalidServerURL"
        case .server(let status, let message): "server(\(status), \(message ?? "nil"))"
        case .invalidResponse: "invalidResponse"
        case .network: "network"
        }
    }
}

@Suite("KOSyncClient")
struct KOSyncClientTests {
    static let username = "reader"
    static let password = "correct horse battery staple"
    static let device = "Test Phone"
    static let deviceID = "device-0001"
    static let acceptHeader = "application/vnd.koreader.v1+json"

    /// A stub server and a client pointed at `basePath` on it.
    private func makeClient(
        basePath: String = "",
        password: String = KOSyncClientTests.password
    ) -> (stub: NetworkStub, client: KOSyncClient) {
        let stub = NetworkStub()
        let credentials = KOSyncCredentials(
            serverURL: stub.url(basePath), username: Self.username, password: password
        )
        let client = KOSyncClient(
            credentials: credentials, device: Self.device, deviceID: Self.deviceID, session: stub.session
        )
        return (stub, client)
    }

    private func error(from body: () async throws -> Void) async -> KOSyncError? {
        do {
            try await body()
            return nil
        } catch let error as KOSyncError {
            return error
        } catch {
            Issue.record("expected a KOSyncError but got \(error)")
            return nil
        }
    }

    // MARK: - Auth key

    @Test("the auth key is the lowercase hex MD5 of the password, as the reference computed it")
    func authKeyMatchesReference() throws {
        let reference = try SyncReference.load()
        #expect(reference.md5.count == 3)
        for (password, expected) in reference.md5 {
            #expect(KOSyncClient.authKey(for: password) == expected, "password: \(password)")
        }
    }

    @Test("the auth key of a well-known password is the well-known MD5")
    func authKeyKnownValue() {
        #expect(KOSyncClient.authKey(for: "password") == "5f4dcc3b5aa765d61d8327deb882cf99")
        #expect(KOSyncClient.authKey(for: "").count == 32)
    }

    // MARK: - URL joining

    @Test(
        "endpoints are joined to the base URL cleanly, with or without a trailing slash or a path prefix",
        arguments: ["", "/", "/kosync/abc", "/kosync/abc/", "/kosync//"]
    )
    func urlJoining(basePath: String) async throws {
        let (stub, client) = makeClient(basePath: basePath)
        stub.respond(with: .json(#"{"authorized":"OK"}"#))
        try await client.authorize()
        let prefix = basePath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let request = try #require(stub.onlyRequest)
        #expect(request.url.absoluteString == "https://\(stub.host)\(prefix)/users/auth")
    }

    @Test("a base URL with a query or fragment does not leak them into the endpoint")
    func queryAndFragmentDropped() async throws {
        let stub = NetworkStub()
        stub.respond(with: .json(#"{"authorized":"OK"}"#))
        let base = try #require(URL(string: "https://\(stub.host)/sync/?token=1#frag"))
        let client = KOSyncClient(
            credentials: KOSyncCredentials(serverURL: base, username: "u", password: "p"),
            device: "d", deviceID: "i", session: stub.session
        )
        try await client.authorize()
        #expect(stub.onlyRequest?.url.absoluteString == "https://\(stub.host)/sync/users/auth")
    }

    @Test("a server URL without a scheme and host is rejected before any request", arguments: ["example.com", "ftp://example.com/x", "file:///tmp/x"])
    func invalidServerURL(text: String) async throws {
        let stub = NetworkStub()
        let url = try #require(URL(string: text))
        let client = KOSyncClient(
            credentials: KOSyncCredentials(serverURL: url, username: "u", password: "p"),
            device: "d", deviceID: "i", session: stub.session
        )
        let failure = await error { try await client.authorize() }
        #expect(failure?.kind == "invalidServerURL")
        #expect(stub.requests.isEmpty)
    }

    // MARK: - healthcheck

    @Test("healthcheck GETs /healthcheck and reads the state")
    func healthcheck() async throws {
        let (stub, client) = makeClient(basePath: "/kosync/abc/")
        stub.respond(with: .json(#"{"state":"OK"}"#))
        #expect(try await client.healthcheck() == true)

        let request = try #require(stub.onlyRequest)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://\(stub.host)/kosync/abc/healthcheck")
        #expect(request.header("Accept") == Self.acceptHeader)
        #expect(request.header("x-auth-key") == nil, "the healthcheck is unauthenticated")

        stub.respond(with: .json(#"{"state":"DEGRADED"}"#))
        #expect(try await client.healthcheck() == false)
        stub.respond(with: .json("not json"))
        #expect(try await client.healthcheck() == false)
    }

    @Test("healthcheck reports a non-2xx answer as a server error")
    func healthcheckServerError() async {
        let (stub, client) = makeClient()
        stub.respond(with: .status(502))
        let failure = await error { _ = try await client.healthcheck() }
        #expect(failure?.kind == "server(502, nil)")
    }

    // MARK: - register

    @Test("register POSTs the username and the MD5 of the password as JSON")
    func register() async throws {
        let reference = try SyncReference.load()
        let (stub, client) = makeClient(basePath: "/kosync/abc/")
        stub.respond(with: .json(#"{"username":"reader"}"#, status: 201))
        try await client.register()

        let request = try #require(stub.onlyRequest)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://\(stub.host)/kosync/abc/users/create")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Accept") == Self.acceptHeader)
        let body = try request.jsonObject()
        #expect(Set(body.keys) == ["username", "password"])
        #expect(body["username"] as? String == Self.username)
        #expect(body["password"] as? String == reference.md5[Self.password], "the plain password never leaves the device")
    }

    @Test("register maps 402 to usernameTaken")
    func registerUsernameTaken() async {
        let (stub, client) = makeClient()
        stub.respond(with: .json(#"{"message":"Username is already registered."}"#, status: 402))
        let failure = await error { try await client.register() }
        #expect(failure?.kind == "usernameTaken")
    }

    @Test("register surfaces the server's message for other failures")
    func registerDisabled() async {
        let (stub, client) = makeClient()
        stub.respond(with: .json(#"{"message":"User registration is disabled."}"#, status: 403))
        let failure = await error { try await client.register() }
        #expect(failure?.kind == "server(403, User registration is disabled.)")
    }

    // MARK: - authorize

    @Test("authorize GETs /users/auth with the auth headers")
    func authorize() async throws {
        let reference = try SyncReference.load()
        let (stub, client) = makeClient(basePath: "/kosync/abc")
        stub.respond(with: .json(#"{"authorized":"OK"}"#))
        try await client.authorize()

        let request = try #require(stub.onlyRequest)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://\(stub.host)/kosync/abc/users/auth")
        #expect(request.header("x-auth-user") == Self.username)
        #expect(request.header("x-auth-key") == reference.md5[Self.password])
        #expect(request.header("Accept") == Self.acceptHeader)
        #expect(request.body.isEmpty)
    }

    @Test("authorize maps 401 to unauthorized")
    func authorizeUnauthorized() async {
        let (stub, client) = makeClient()
        stub.respond(with: .json(#"{"message":"Unauthorized"}"#, status: 401))
        let failure = await error { try await client.authorize() }
        #expect(failure?.kind == "unauthorized")
    }

    @Test("a non-ASCII password produces the reference key")
    func nonASCIIPassword() async throws {
        let reference = try SyncReference.load()
        let (stub, client) = makeClient(password: "pässwörd")
        stub.respond(with: .json(#"{"authorized":"OK"}"#))
        try await client.authorize()
        #expect(stub.onlyRequest?.header("x-auth-key") == reference.md5["pässwörd"])
    }

    // MARK: - progress(for:)

    @Test("progress decodes every field, with the timestamp as seconds since 1970")
    func progressDecoding() async throws {
        let (stub, client) = makeClient(basePath: "/kosync/abc/")
        stub.respond(with: .json("""
            {"document":"abc123","progress":"/body/DocFragment[3]/body/div/p[2]/text().17",
             "percentage":0.4321,"device":"Kobo","device_id":"dev-9","timestamp":1700000000}
            """))
        let stored = try #require(try await client.progress(for: "abc123"))

        #expect(stored.document == "abc123")
        #expect(stored.progress == "/body/DocFragment[3]/body/div/p[2]/text().17")
        #expect(stored.percentage == 0.4321)
        #expect(stored.device == "Kobo")
        #expect(stored.deviceID == "dev-9")
        #expect(stored.timestamp == Date(timeIntervalSince1970: 1_700_000_000))

        let request = try #require(stub.onlyRequest)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://\(stub.host)/kosync/abc/syncs/progress/abc123")
        #expect(request.header("x-auth-user") == Self.username)
        #expect(request.header("Accept") == Self.acceptHeader)
    }

    @Test("an empty object means nothing is stored")
    func progressEmptyObject() async throws {
        let (stub, client) = makeClient()
        stub.respond(with: .json("{}"))
        #expect(try await client.progress(for: "abc123") == nil)
    }

    @Test("a 404 also means nothing is stored")
    func progressNotFound() async throws {
        let (stub, client) = makeClient()
        stub.respond(with: .json(#"{"message":"Document not found on server"}"#, status: 404))
        #expect(try await client.progress(for: "abc123") == nil)
    }

    @Test("the document is one percent-encoded path segment")
    func progressDocumentEncoding() async throws {
        let (stub, client) = makeClient(basePath: "/kosync/abc/")
        stub.respond(with: .json("{}"))
        _ = try await client.progress(for: "My Book/ch 1?x=1#top%25 é")
        let request = try #require(stub.onlyRequest)
        #expect(
            request.url.absoluteString
                == "https://\(stub.host)/kosync/abc/syncs/progress/My%20Book%2Fch%201%3Fx%3D1%23top%2525%20%C3%A9"
        )
    }

    @Test("progress maps 401 to unauthorized and a garbage 200 to invalidResponse")
    func progressErrors() async {
        let (stub, client) = makeClient()
        stub.respond(with: .json("{}", status: 401))
        let unauthorized = await error { _ = try await client.progress(for: "abc") }
        #expect(unauthorized?.kind == "unauthorized")

        stub.respond(with: .text("<html>login</html>", contentType: "text/html"))
        let garbage = await error { _ = try await client.progress(for: "abc") }
        #expect(garbage?.kind == "invalidResponse")

        stub.respond(with: .status(500))
        let broken = await error { _ = try await client.progress(for: "abc") }
        #expect(broken?.kind == "server(500, nil)")
    }

    // MARK: - update

    @Test("update PUTs the five protocol fields, filling the device from the client")
    func update() async throws {
        let reference = try SyncReference.load()
        let (stub, client) = makeClient(basePath: "/kosync/abc/")
        stub.respond(with: .json(#"{"document":"abc123","timestamp":1700000042}"#))

        let xpointer = "/body/DocFragment[12]/body/div/p[3]/text().0"
        let timestamp = try await client.update(
            KOSyncProgress(
                document: "abc123", progress: xpointer, percentage: 0.25,
                device: "Some Other Device", deviceID: "some-other-id",
                timestamp: Date(timeIntervalSince1970: 5)
            )
        )
        #expect(timestamp == Date(timeIntervalSince1970: 1_700_000_042))

        let request = try #require(stub.onlyRequest)
        #expect(request.method == "PUT")
        #expect(request.url.absoluteString == "https://\(stub.host)/kosync/abc/syncs/progress")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Accept") == Self.acceptHeader)
        #expect(request.header("x-auth-user") == Self.username)
        #expect(request.header("x-auth-key") == reference.md5[Self.password])

        let body = try request.jsonObject()
        #expect(Set(body.keys) == ["document", "progress", "percentage", "device", "device_id"])
        #expect(body["document"] as? String == "abc123")
        #expect(body["progress"] as? String == xpointer)
        #expect(body["percentage"] as? Double == 0.25)
        #expect(body["device"] as? String == Self.device)
        #expect(body["device_id"] as? String == Self.deviceID)
    }

    @Test("the opaque progress string is sent exactly as given")
    func updateKeepsProgressOpaque() async throws {
        let (stub, client) = makeClient()
        stub.respond(with: .json(#"{"document":"d","timestamp":1}"#))
        let odd = #"page "12" / 340 \ é 🙂 {not json} <tag>"#
        _ = try await client.update(KOSyncProgress(document: "d", progress: odd, percentage: 1))
        let body = try #require(stub.onlyRequest).jsonObject()
        #expect(body["progress"] as? String == odd)
        #expect(body["percentage"] as? Double == 1)
    }

    @Test("a fractional server timestamp is kept")
    func updateFractionalTimestamp() async throws {
        let (stub, client) = makeClient()
        stub.respond(with: .json(#"{"document":"d","timestamp":1700000000.5}"#))
        let date = try await client.update(KOSyncProgress(document: "d", progress: "p", percentage: 0))
        #expect(date == Date(timeIntervalSince1970: 1_700_000_000.5))
    }

    @Test("update maps 401 to unauthorized and a reply without a timestamp to invalidResponse")
    func updateErrors() async {
        let (stub, client) = makeClient()
        let position = KOSyncProgress(document: "d", progress: "p", percentage: 0.5)

        stub.respond(with: .json(#"{"message":"Unauthorized"}"#, status: 401))
        let unauthorized = await error { _ = try await client.update(position) }
        #expect(unauthorized?.kind == "unauthorized")

        stub.respond(with: .json(#"{"document":"d"}"#))
        let missing = await error { _ = try await client.update(position) }
        #expect(missing?.kind == "invalidResponse")

        stub.respond(with: .json(#"{"message":"Invalid request"}"#, status: 400))
        let rejected = await error { _ = try await client.update(position) }
        #expect(rejected?.kind == "server(400, Invalid request)")
    }

    // MARK: - Transport failures

    @Test("a transport failure becomes a network error")
    func networkFailure() async {
        let (stub, client) = makeClient()
        stub.respond(with: StubResponse(status: 200, failure: URLError(.notConnectedToInternet)))
        let failure = await error { try await client.authorize() }
        #expect(failure?.kind == "network")
        if case .network(let underlying)? = failure {
            #expect((underlying as? URLError)?.code == .notConnectedToInternet)
        }
    }

    // MARK: - Codable

    @Test("KOSyncProgress encodes to the protocol's JSON and decodes it back")
    func progressCodable() throws {
        let original = KOSyncProgress(
            document: "abc", progress: "/body/p[1]", percentage: 0.5,
            device: "Phone", deviceID: "id-1", timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["document", "progress", "percentage", "device", "device_id", "timestamp"])
        #expect(object["device_id"] as? String == "id-1")
        #expect(object["timestamp"] as? Int == 1_700_000_000)
        #expect(try JSONDecoder().decode(KOSyncProgress.self, from: data) == original)

        let minimal = KOSyncProgress(document: "abc", progress: "1", percentage: 0)
        let minimalObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(minimal)) as? [String: Any]
        )
        #expect(Set(minimalObject.keys) == ["document", "progress", "percentage"])
    }

    @Test("credentials print without the password")
    func credentialsRedacted() throws {
        let url = try #require(URL(string: "https://example.com"))
        let credentials = KOSyncCredentials(serverURL: url, username: "reader", password: "hunter2")
        #expect(!String(describing: credentials).contains("hunter2"))
    }
}
