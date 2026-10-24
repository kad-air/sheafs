import Foundation
import Synchronization

// A URLProtocol-based stand-in for a server, shared by the KOSync and OPDS client tests.
//
// Swift Testing runs tests in parallel, so each `NetworkStub` owns a unique host name and a
// registry (lock-protected, host to stub) routes every request to the stub that owns its host.
// No test shares mutable state with another.

/// A request as the stub saw it.
struct CapturedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    /// Case-insensitive header lookup.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body parsed as a JSON object.
    func jsonObject() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw StubError.bodyIsNotAJSONObject
        }
        return object
    }
}

enum StubError: Error {
    case bodyIsNotAJSONObject
}

/// What the stub answers with.
struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    /// Deliver the body in pieces of this size (default: one piece).
    var chunkSize: Int?
    /// Leave out the Content-Length header, so the length is unknown to the client.
    var omitContentLength = false
    /// Fail with this error after the body has been delivered.
    var failure: URLError?

    static func json(_ text: String, status: Int = 200) -> StubResponse {
        StubResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    static func text(_ text: String, status: Int = 200, contentType: String) -> StubResponse {
        StubResponse(status: status, headers: ["Content-Type": contentType], body: Data(text.utf8))
    }

    static func status(_ status: Int) -> StubResponse {
        StubResponse(status: status)
    }
}

final class NetworkStub: Sendable {
    typealias Handler = @Sendable (CapturedRequest) -> StubResponse

    private struct State {
        var requests: [CapturedRequest] = []
        var handler: Handler?
    }

    let host: String
    let session: URLSession
    private let state = Mutex(State())

    init() {
        host = "stub-\(UUID().uuidString.lowercased()).example.com"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkStubProtocol.self]
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
        NetworkStubProtocol.register(self)
    }

    deinit {
        NetworkStubProtocol.unregister(host: host)
        session.invalidateAndCancel()
    }

    /// `https://<host><path>`.
    func url(_ path: String = "") -> URL {
        guard let url = URL(string: "https://\(host)\(path)") else { preconditionFailure("bad stub path \(path)") }
        return url
    }

    /// Answer every request with `handler`.
    func respond(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    /// Answer every request with `response`.
    func respond(with response: StubResponse) {
        respond { _ in response }
    }

    /// Every request seen so far, oldest first.
    var requests: [CapturedRequest] { state.withLock { $0.requests } }

    /// The only request seen, failing the test if there was not exactly one.
    var onlyRequest: CapturedRequest? {
        let seen = requests
        return seen.count == 1 ? seen[0] : nil
    }

    fileprivate func answer(_ request: CapturedRequest) -> StubResponse {
        state.withLock { state in
            state.requests.append(request)
            return state.handler?(request) ?? StubResponse.status(500)
        }
    }
}

final class NetworkStubProtocol: URLProtocol {
    private final class WeakStub: @unchecked Sendable {
        weak var stub: NetworkStub?
        init(_ stub: NetworkStub) { self.stub = stub }
    }

    private static let registry = Mutex<[String: WeakStub]>([:])

    static func register(_ stub: NetworkStub) {
        registry.withLock { $0[stub.host] = WeakStub(stub) }
    }

    static func unregister(host: String) {
        registry.withLock { _ = $0.removeValue(forKey: host) }
    }

    private static func stub(forHost host: String) -> NetworkStub? {
        registry.withLock { $0[host]?.stub }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let stub = Self.stub(forHost: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let captured = CapturedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request)
        )
        let canned = stub.answer(captured)

        var headers = canned.headers
        if !canned.omitContentLength { headers["Content-Length"] = String(canned.body.count) }
        guard let response = HTTPURLResponse(
            url: url, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunkSize = canned.chunkSize, chunkSize > 0 {
            var offset = 0
            while offset < canned.body.count {
                let end = min(offset + chunkSize, canned.body.count)
                client?.urlProtocol(self, didLoad: canned.body.subdata(in: offset..<end))
                offset = end
            }
        } else if !canned.body.isEmpty {
            client?.urlProtocol(self, didLoad: canned.body)
        }
        if let failure = canned.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a request body to protocols as a stream.
    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
