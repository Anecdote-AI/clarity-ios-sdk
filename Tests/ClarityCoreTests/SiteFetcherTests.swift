import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ClaritySDK

/// `SiteFetcher` against a stub `URLProtocol`: the 2 MB limit stops a large
/// body while it streams, instead of after the whole of it is in memory.
final class SiteFetcherTests: XCTestCase {

    /// Answers every request with `Stub.response`, sending the body in
    /// chunks and counting how many bytes the client took.
    final class Stub: URLProtocol {
        struct Response {
            var status = 200
            var headers: [String: String] = ["Content-Type": "text/html"]
            var chunk = Data("<p>hi</p>".utf8)
            var chunks = 1
        }

        nonisolated(unsafe) static var response = Response()
        nonisolated(unsafe) static var sentBytes = 0
        private var stopped = false
        private let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let stub = Self.response
            let http = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            send(stub, left: stub.chunks)
        }

        /// One chunk at a time, off the loading thread, so a cancel can stop it.
        private func send(_ stub: Response, left: Int) {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }
            guard left > 0 else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            Self.sentBytes += stub.chunk.count
            client?.urlProtocol(self, didLoad: stub.chunk)
            Self.queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in send(stub, left: left - 1) }
        }

        static let queue = DispatchQueue(label: "SiteFetcherTests.Stub")

        override func stopLoading() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private let site = URL(string: "https://help.example.com")!

    override func setUp() {
        super.setUp()
        Stub.response = .init()
        Stub.sentBytes = 0
    }

    private func fetch(_ path: String = "/help") -> Result<SiteResponse, SiteFetchError>? {
        let fetcher = SiteFetcher(siteURL: site, protocolClasses: [Stub.self])
        defer { fetcher.invalidate() }
        let done = expectation(description: "answered")
        var outcome: Result<SiteResponse, SiteFetchError>?
        fetcher.fetch(URL(string: path, relativeTo: site)!.absoluteURL) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return outcome
    }

    func testAPageIsRead() throws {
        let response = try XCTUnwrap(fetch()).get()
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "<p>hi</p>")
        XCTAssertEqual(response.contentType, "text/html")
    }

    func testADeclaredLengthOverTheLimitIsRefusedBeforeTheBody() {
        Stub.response.headers["Content-Length"] = "\(SiteFetcher.maxBytes + 1)"
        Stub.response.chunk = Data(count: 64 * 1024)
        Stub.response.chunks = 40

        guard case .failure(let error)? = fetch() else { return XCTFail("not refused") }
        XCTAssertEqual(error.message, "/help is too large to read")
    }

    func testABodyOverTheLimitIsStoppedWhileItStreams() {
        // No Content-Length: 64 MB would be sent if nobody stopped it.
        Stub.response.chunk = Data(count: 256 * 1024)
        Stub.response.chunks = 256

        guard case .failure(let error)? = fetch() else { return XCTFail("not refused") }
        XCTAssertEqual(error.message, "/help is too large to read")
        // A body read whole before the check (the old completion-handler
        // task) would have taken all 64 MB before refusing.
        XCTAssertLessThan(Stub.sentBytes, 16 * 1024 * 1024, "the download stopped near the limit")
    }

    func testAnotherSitesRedirectIsRefused() {
        Stub.response.status = 302
        Stub.response.headers["Location"] = "https://evil.example.org/"

        guard case .failure(let error)? = fetch() else { return XCTFail("not refused") }
        XCTAssertEqual(error.message, "/help redirects off the website")
    }

    func testANonPageIsRefused() {
        Stub.response.headers["Content-Type"] = "application/zip"

        guard case .failure(let error)? = fetch() else { return XCTFail("not refused") }
        XCTAssertEqual(error.message, "/help is not a web page")
    }
}
