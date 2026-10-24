import Foundation

/// Fetches OPDS feeds, runs searches and downloads books from one catalog.
///
/// If credentials are set they are sent as a pre-emptive HTTP Basic `Authorization` header on
/// every request made through this client, whatever the host, so use one client per catalog.
public final class OPDSClient: Sendable {
    /// The `Accept` header used for feed requests.
    public static let defaultAccept =
        "application/atom+xml;profile=opds-catalog, application/atom+xml, application/xml;q=0.9, */*;q=0.8"

    private let credentials: OPDSCredentials?
    private let session: URLSession

    public init(credentials: OPDSCredentials? = nil, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// A GET request for `url` with the client's `Accept`, `User-Agent` and, when credentials
    /// are set, Basic `Authorization` headers.
    public func request(for url: URL, accept: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept ?? Self.defaultAccept, forHTTPHeaderField: "Accept")
        request.setValue("Sheafs/1.0", forHTTPHeaderField: "User-Agent")
        if let credentials {
            let token = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Fetches and parses the feed at `url`. Relative links resolve against the final URL, so
    /// redirects are handled.
    public func feed(at url: URL) async throws -> OPDSFeed {
        let (data, response) = try await fetch(url, accept: nil)
        do {
            return try OPDSParser.parseFeed(data, baseURL: response.url ?? url)
        } catch OPDSError.malformed(let detail) {
            // A login page or error page served with a 200 is not XML; say so plainly.
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            if contentType?.lowercased().contains("html") == true { throw OPDSError.notAFeed }
            throw OPDSError.malformed(detail)
        }
    }

    /// Runs `query` against the feed's search link and returns the result feed. An OpenSearch
    /// description is fetched first to find the URL template.
    public func search(_ feed: OPDSFeed, query: String) async throws -> OPDSFeed {
        guard let link = feed.searchLink else {
            throw OPDSError.malformed("the feed does not advertise a search link")
        }
        let template: String
        if link.isOpenSearchDescription {
            let accept = "application/opensearchdescription+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5"
            let (data, response) = try await fetch(link.href, accept: accept)
            template = try OPDSParser.parseOpenSearchTemplate(data, baseURL: response.url ?? link.href)
        } else {
            template = link.href.absoluteString
        }
        guard let url = OPDSParser.searchURL(template: template, query: query) else {
            throw OPDSError.malformed("could not build a search URL from \(template)")
        }
        return try await self.feed(at: url)
    }

    /// Streams `url` to `destination`. The bytes go to a temporary file beside the destination,
    /// which is moved into place only when the download completes, so a failure leaves any
    /// existing destination untouched and no partial file behind.
    ///
    /// The content type is deliberately not checked (servers lie); it is returned so the caller
    /// can decide. `progress` receives 0...1, never decreasing and ending at 1, but only when the
    /// server states a Content-Length.
    ///
    /// - Returns: The response's `Content-Type` header, if any.
    /// - Throws: ``OPDSError/unauthorized(url:)`` for 401, ``OPDSError/httpStatus(_:url:)`` for
    ///   other non-2xx, ``OPDSError/network(underlying:)`` for transport failures. File system
    ///   errors are thrown as they are.
    @discardableResult
    public func download(
        _ url: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String? {
        let request = request(for: url, accept: "application/epub+zip, application/octet-stream;q=0.9, */*;q=0.5")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.wrap(error)
        }
        try Self.validate(response, url: url)

        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        try Data().write(to: temporary)
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: temporary) } }

        let expected = response.expectedContentLength  // -1 when unknown
        var lastReported = -1.0
        func report(_ fraction: Double) {
            guard let progress, expected > 0 else { return }
            let clamped = min(max(fraction, 0), 1)
            if clamped > lastReported {
                lastReported = clamped
                progress(clamped)
            }
        }

        let handle = try FileHandle(forWritingTo: temporary)
        var closed = false
        defer { if !closed { try? handle.close() } }

        let chunkSize = 64 * 1024
        var buffer: [UInt8] = []
        buffer.reserveCapacity(chunkSize)
        var received: Int64 = 0
        report(0)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= chunkSize {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    report(Double(received) / Double(expected))
                }
            }
        } catch let error as URLError {
            throw Self.wrap(error)
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.close()
        closed = true

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        finished = true
        report(1)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
    }

    // MARK: - Helpers

    private func fetch(_ url: URL, accept: String?) async throws -> (Data, URLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request(for: url, accept: accept))
        } catch {
            throw Self.wrap(error)
        }
        try Self.validate(result.1, url: url)
        return result
    }

    private static func validate(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw OPDSError.unauthorized(url: url) }
        guard (200..<300).contains(http.statusCode) else { throw OPDSError.httpStatus(http.statusCode, url: url) }
    }

    /// Wraps a transport error, but lets cancellation through untouched.
    private static func wrap(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return OPDSError.network(underlying: error)
    }
}
