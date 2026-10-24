import Foundation
import Synchronization
import Testing

import SheafsKit

private let smallFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"><id>small</id><title>Small</title>
    <link rel="search" type="application/opensearchdescription+xml" href="/opds/opensearch.xml"/>
    <entry><id>b1</id><title>Book One</title>
      <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/files/b1.epub"/></entry>
    </feed>
    """

private let openSearchDocument = """
    <?xml version="1.0" encoding="UTF-8"?>
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <Url type="application/atom+xml;profile=opds-catalog" template="/opds/search?q={searchTerms}&amp;page={startPage?}"/>
    </OpenSearchDescription>
    """

private let defaultAccept = "application/atom+xml;profile=opds-catalog, application/atom+xml, application/xml;q=0.9, */*;q=0.8"

/// Collects the values a progress callback receives.
private final class ProgressLog: Sendable {
    private let values = Mutex<[Double]>([])
    func record(_ value: Double) { values.withLock { $0.append(value) } }
    var all: [Double] { values.withLock { $0 } }
}

private func error(from body: () async throws -> Void) async -> OPDSError? {
    do {
        try await body()
        return nil
    } catch let error as OPDSError {
        return error
    } catch {
        Issue.record("expected an OPDSError but got \(error)")
        return nil
    }
}

private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opds-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// File names in `directory` (hidden ones included), or nil if it cannot be listed.
private func names(in directory: URL) -> [String]? {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted()
}

private func contents(of file: URL) -> Data? {
    try? Data(contentsOf: file)
}

private func text(of file: URL) -> String? {
    contents(of: file).flatMap { String(data: $0, encoding: .utf8) }
}

@Suite("OPDSClient")
struct OPDSClientTests {
    private let credentials = OPDSCredentials(username: "user", password: "pass")
    private let basicHeader = "Basic dXNlcjpwYXNz"  // base64("user:pass")

    private func makeClient(_ stub: NetworkStub, credentials: OPDSCredentials? = nil) -> OPDSClient {
        OPDSClient(credentials: credentials, session: stub.session)
    }

    // MARK: - Requests

    @Test("request(for:) sets Accept, User-Agent and pre-emptive Basic auth")
    func requestHeaders() throws {
        let target = try #require(URL(string: "https://example.com/opds"))

        let plain = OPDSClient().request(for: target)
        #expect(plain.httpMethod == "GET")
        #expect(plain.url == target)
        #expect(plain.value(forHTTPHeaderField: "Accept") == defaultAccept)
        #expect(plain.value(forHTTPHeaderField: "User-Agent") == "Sheafs/1.0")
        #expect(plain.value(forHTTPHeaderField: "Authorization") == nil)

        let authed = OPDSClient(credentials: credentials).request(for: target, accept: "application/epub+zip")
        #expect(authed.value(forHTTPHeaderField: "Authorization") == basicHeader)
        #expect(authed.value(forHTTPHeaderField: "Accept") == "application/epub+zip")
    }

    @Test("a password containing a colon is encoded whole")
    func colonInPassword() throws {
        let target = try #require(URL(string: "https://example.com/"))
        let client = OPDSClient(credentials: OPDSCredentials(username: "reader", password: "p:w d"))
        // base64("reader:p:w d")
        #expect(client.request(for: target).value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnA6dyBk")
    }

    @Test("credentials print without the password")
    func credentialsRedacted() {
        #expect(!String(describing: OPDSCredentials(username: "u", password: "hunter2")).contains("hunter2"))
    }

    // MARK: - feed(at:)

    @Test("feed(at:) sends Basic auth and Accept, and resolves links against the fetched URL")
    func feedRequestAndParse() async throws {
        let stub = NetworkStub()
        stub.respond(with: .text(smallFeed, contentType: "application/atom+xml;profile=opds-catalog"))
        let feed = try await makeClient(stub, credentials: credentials).feed(at: stub.url("/opds/root"))

        let request = try #require(stub.onlyRequest)
        #expect(request.method == "GET")
        #expect(request.url == stub.url("/opds/root"))
        #expect(request.header("Authorization") == basicHeader)
        #expect(request.header("Accept") == defaultAccept)
        #expect(request.header("User-Agent") == "Sheafs/1.0")

        #expect(feed.title == "Small")
        #expect(feed.entries.first?.epubLink?.href == stub.url("/files/b1.epub"))
        #expect(feed.searchLink?.href == stub.url("/opds/opensearch.xml"))
    }

    @Test("without credentials no Authorization header is sent")
    func noCredentials() async throws {
        let stub = NetworkStub()
        stub.respond(with: .text(smallFeed, contentType: "application/atom+xml"))
        _ = try await makeClient(stub).feed(at: stub.url("/opds"))
        #expect(stub.onlyRequest?.header("Authorization") == nil)
    }

    @Test("401 is unauthorized and names the URL")
    func unauthorized() async throws {
        let stub = NetworkStub()
        stub.respond(with: .status(401))
        let failure = await error { _ = try await makeClient(stub, credentials: credentials).feed(at: stub.url("/opds")) }
        #expect(failure?.kind == "unauthorized")
        if case .unauthorized(let url)? = failure { #expect(url == stub.url("/opds")) }
    }

    @Test("other non-2xx statuses are httpStatus", arguments: [403, 404, 500, 503])
    func httpStatus(code: Int) async {
        let stub = NetworkStub()
        stub.respond(with: .status(code))
        let failure = await error { _ = try await makeClient(stub).feed(at: stub.url("/opds")) }
        #expect(failure?.kind == "httpStatus(\(code))")
    }

    @Test("an HTML page served with 200 is notAFeed, not a parse error")
    func htmlLoginPage() async {
        let stub = NetworkStub()
        stub.respond(with: .text("<html><body><form>login<br></form></body></html>", contentType: "text/html; charset=utf-8"))
        let failure = await error { _ = try await makeClient(stub).feed(at: stub.url("/opds")) }
        #expect(failure?.kind == "notAFeed")
    }

    @Test("broken XML served as XML is malformed")
    func brokenXML() async {
        let stub = NetworkStub()
        stub.respond(with: .text("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>cut", contentType: "application/atom+xml"))
        let failure = await error { _ = try await makeClient(stub).feed(at: stub.url("/opds")) }
        #expect(failure?.kind == "malformed")
    }

    @Test("a transport failure is a network error")
    func networkFailure() async {
        let stub = NetworkStub()
        stub.respond(with: StubResponse(failure: URLError(.timedOut)))
        let failure = await error { _ = try await makeClient(stub).feed(at: stub.url("/opds")) }
        #expect(failure?.kind == "network")
    }

    // MARK: - search

    @Test("search fetches the OpenSearch description, then the result feed")
    func searchViaDescription() async throws {
        let stub = NetworkStub()
        stub.respond { request in
            switch request.url.path {
            case "/opds":
                .text(smallFeed, contentType: "application/atom+xml")
            case "/opds/opensearch.xml":
                .text(openSearchDocument, contentType: "application/opensearchdescription+xml")
            case "/opds/search":
                .text(smallFeed.replacingOccurrences(of: "Small", with: "Results"), contentType: "application/atom+xml")
            default:
                .status(404)
            }
        }
        let client = makeClient(stub, credentials: credentials)
        let root = try await client.feed(at: stub.url("/opds"))
        let results = try await client.search(root, query: "dune & sand")
        #expect(results.title == "Results")

        let requests = stub.requests
        #expect(requests.count == 3, "root, description, results")
        #expect(requests[1].url == stub.url("/opds/opensearch.xml"))
        #expect(requests[1].header("Accept")?.hasPrefix("application/opensearchdescription+xml") == true)
        #expect(requests[2].url.absoluteString == "https://\(stub.host)/opds/search?q=dune%20%26%20sand")
        #expect(requests[2].header("Accept") == defaultAccept)
        #expect(requests.allSatisfy { $0.header("Authorization") == basicHeader })
    }

    @Test("search expands a direct template without fetching a description")
    func searchViaTemplate() async throws {
        let stub = NetworkStub()
        let root = OPDSFeed(
            title: "Root",
            links: [OPDSLink(rel: "search", type: "application/atom+xml", href: stub.url("/find?query={searchTerms}"))]
        )
        stub.respond(with: .text(smallFeed, contentType: "application/atom+xml"))
        let results = try await makeClient(stub).search(root, query: "a b")
        #expect(results.title == "Small")
        #expect(stub.onlyRequest?.url.absoluteString == "https://\(stub.host)/find?query=a%20b")
    }

    @Test("search on a feed without a search link says so")
    func searchUnavailable() async {
        let stub = NetworkStub()
        let failure = await error { _ = try await makeClient(stub).search(OPDSFeed(title: "No search"), query: "x") }
        #expect(failure?.kind == "malformed")
        #expect(stub.requests.isEmpty)
    }

    // MARK: - download

    @Test("download writes the exact bytes and reports increasing progress ending at 1")
    func downloadBytesAndProgress() async throws {
        let bytes = SyncFixture.syntheticBytes(count: 300_000)
        let stub = NetworkStub()
        stub.respond(with: StubResponse(
            status: 200, headers: ["Content-Type": "application/epub+zip"], body: bytes, chunkSize: 50_000
        ))
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("book.epub")
            let log = ProgressLog()
            let contentType = try await makeClient(stub, credentials: credentials).download(
                stub.url("/files/book.epub"), to: destination, progress: { log.record($0) }
            )

            #expect(contentType == "application/epub+zip")
            #expect(contents(of: destination) == bytes)
            #expect(names(in: directory) == ["book.epub"], "no temporary file left behind")

            let values = log.all
            #expect(values.first == 0)
            #expect(values.last == 1)
            #expect(values.count >= 4, "progress arrives while downloading, not just at the end: \(values)")
            #expect(values.allSatisfy { (0...1).contains($0) })
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "strictly increasing: \(values)")

            let request = try #require(stub.onlyRequest)
            #expect(request.header("Authorization") == basicHeader)
            #expect(request.header("Accept")?.contains("application/epub+zip") == true)
        }
    }

    @Test("download reports no progress when the length is unknown, but still delivers the file")
    func downloadUnknownLength() async throws {
        let bytes = SyncFixture.syntheticBytes(count: 200_000)
        let stub = NetworkStub()
        stub.respond(with: StubResponse(
            status: 200, headers: ["Content-Type": "application/octet-stream"], body: bytes,
            chunkSize: 40_000, omitContentLength: true
        ))
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("book.epub")
            let log = ProgressLog()
            let contentType = try await makeClient(stub).download(
                stub.url("/files/book.epub"), to: destination, progress: { log.record($0) }
            )
            #expect(contentType == "application/octet-stream", "the content type is returned, not enforced")
            #expect(contents(of: destination) == bytes)
            #expect(log.all.isEmpty)
        }
    }

    @Test("download works without a progress callback and creates missing folders")
    func downloadIntoNewFolder() async throws {
        let stub = NetworkStub()
        stub.respond(with: StubResponse(status: 200, body: Data("tiny".utf8)))
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("a/b/tiny.epub")
            let contentType = try await makeClient(stub).download(stub.url("/t"), to: destination)
            #expect(contentType == nil)
            #expect(text(of: destination) == "tiny")
        }
    }

    @Test("download replaces an existing file in one step")
    func downloadReplacesExisting() async throws {
        let stub = NetworkStub()
        stub.respond(with: StubResponse(status: 200, body: Data("new contents".utf8)))
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("book.epub")
            try Data("old contents".utf8).write(to: destination)
            try await makeClient(stub).download(stub.url("/b"), to: destination)
            #expect(text(of: destination) == "new contents")
            #expect(names(in: directory) == ["book.epub"])
        }
    }

    @Test("a download that dies half way leaves the old file and no partial file")
    func downloadFailsMidStream() async throws {
        let stub = NetworkStub()
        stub.respond(with: StubResponse(
            status: 200, body: SyncFixture.syntheticBytes(count: 150_000), chunkSize: 30_000,
            failure: URLError(.networkConnectionLost)
        ))
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("book.epub")
            try Data("old contents".utf8).write(to: destination)
            let failure = await error { try await makeClient(stub).download(stub.url("/b"), to: destination) }
            #expect(failure?.kind == "network")
            #expect(text(of: destination) == "old contents")
            #expect(names(in: directory) == ["book.epub"])
        }
    }

    @Test("a failed first download leaves nothing at all")
    func downloadFailsLeavesNothing() async throws {
        let stub = NetworkStub()
        stub.respond(with: StubResponse(
            status: 200, body: SyncFixture.syntheticBytes(count: 100_000), chunkSize: 20_000,
            failure: URLError(.networkConnectionLost)
        ))
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("book.epub")
            _ = await error { try await makeClient(stub).download(stub.url("/b"), to: destination) }
            #expect(names(in: directory) == [])
        }
    }

    @Test("download maps 401 to unauthorized and other failures to httpStatus, writing nothing")
    func downloadStatuses() async throws {
        try await withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("book.epub")
            let stub = NetworkStub()
            let client = makeClient(stub, credentials: credentials)

            stub.respond(with: .status(401))
            let unauthorized = await error { try await client.download(stub.url("/b"), to: destination) }
            #expect(unauthorized?.kind == "unauthorized")

            stub.respond(with: StubResponse(status: 404, body: Data("<html>not found</html>".utf8)))
            let missing = await error { try await client.download(stub.url("/b"), to: destination) }
            #expect(missing?.kind == "httpStatus(404)")

            #expect(names(in: directory) == [])
        }
    }
}
