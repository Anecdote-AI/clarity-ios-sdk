import XCTest
@testable import ClaritySDK

final class SessionAPITests: XCTestCase {

    private final class FakeTransport: HTTPTransport {
        struct Call {
            let url: URL
            let headers: [String: String]
        }

        var calls: [Call] = []
        /// One entry consumed per request; empty script throws (transport error).
        var script: [Result<(Int, Data), Error>] = []

        func get(
            url: URL,
            headers: [String: String],
            timeout: TimeInterval
        ) throws -> (statusCode: Int, body: Data) {
            calls.append(Call(url: url, headers: headers))
            guard !script.isEmpty else { throw URLError(.cannotConnectToHost) }
            let (status, body) = try script.removeFirst().get()
            return (status, body)
        }
    }

    /// Overrides every fixture default deliberately: the exotic values are
    /// load-bearing in the URL-shape assertions below.
    private func makeConfig(channelHost: String? = nil) -> ClarityConfig {
        makeTestConfig(
            organizationId: "7",
            integrationKey: "k&y +1",
            baseUrl: "https://chat.example.com/",
            channelHost: channelHost
        )
    }

    private func ok(_ token: String = "tok-1") -> Result<(Int, Data), Error> {
        .success((200, Data(#"{"one_time_token":"\#(token)"}"#.utf8)))
    }

    private func makeApi(_ transport: FakeTransport) -> SessionAPI {
        SessionAPI(transport: transport, retryDelay: 0)
    }

    func testSuccessSingleAttempt() {
        let transport = FakeTransport()
        transport.script = [ok("abc")]
        let api = makeApi(transport)

        let token = api.fetchOneTimeToken(config: makeConfig(), appId: "com.example.app")

        XCTAssertEqual(token, "abc")
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertNil(api.lastError)
        XCTAssertNil(api.lastHttpCode)
    }

    func testRequestShape() throws {
        let transport = FakeTransport()
        transport.script = [ok()]
        let api = makeApi(transport)

        _ = api.fetchOneTimeToken(config: makeConfig(), appId: "com.example.app")

        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(
            call.url.absoluteString,
            "https://chat.example.com/api/live-chat/session/unverified"
                + "?organization_id=7&integration_key=k%26y+%2B1"
        )
        XCTAssertEqual(call.headers["x-os"], "ios")
        XCTAssertEqual(call.headers["x-app-id"], "com.example.app")
        XCTAssertNil(call.headers["Origin"])
    }

    func testOriginHeaderFromChannelHost() throws {
        let transport = FakeTransport()
        transport.script = [ok(), ok()]
        let api = makeApi(transport)

        _ = api.fetchOneTimeToken(
            config: makeConfig(channelHost: "demo.example.com"),
            appId: "a"
        )
        _ = api.fetchOneTimeToken(
            config: makeConfig(channelHost: "http://other.example.com/"),
            appId: "a"
        )

        XCTAssertEqual(transport.calls[0].headers["Origin"], "https://demo.example.com")
        XCTAssertEqual(transport.calls[1].headers["Origin"], "http://other.example.com")
    }

    func testFourXxShortCircuitsWithoutRetry() {
        let transport = FakeTransport()
        transport.script = [.success((404, Data(#"{"status":"error","code":"channel_not_found"}"#.utf8)))]
        let api = makeApi(transport)

        let token = api.fetchOneTimeToken(config: makeConfig(), appId: "a")

        XCTAssertNil(token)
        XCTAssertEqual(transport.calls.count, 1, "4xx must not retry")
        XCTAssertEqual(api.lastHttpCode, 404)
        XCTAssertEqual(api.lastError, "session/unverified returned HTTP 404")
    }

    func testServerErrorRetriesThenSucceeds() {
        let transport = FakeTransport()
        transport.script = [
            .success((500, Data())),
            .failure(URLError(.timedOut)),
            ok("late"),
        ]
        let api = makeApi(transport)

        let token = api.fetchOneTimeToken(config: makeConfig(), appId: "a")

        XCTAssertEqual(token, "late")
        XCTAssertEqual(transport.calls.count, 3)
        XCTAssertNil(api.lastError)
    }

    /// A server that answered 500 on every attempt must be classified from its
    /// status, not as "the request never got an HTTP response" (code -2).
    func testExhaustedServerErrorsKeepTheFinalStatus() {
        let transport = FakeTransport()
        transport.script = [
            .success((500, Data())),
            .success((502, Data())),
            .success((503, Data())),
        ]
        let api = makeApi(transport)

        let token = api.fetchOneTimeToken(config: makeConfig(), appId: "a")

        XCTAssertNil(token)
        XCTAssertEqual(transport.calls.count, 3, "5xx retries to the attempt cap")
        XCTAssertEqual(api.lastHttpCode, 503, "the FINAL attempt's status is reported")
    }

    /// …but a run whose last attempt never reached the server is a network
    /// failure again, so the two fields cannot contradict each other.
    func testServerErrorFollowedByTransportFailureReportsNoHttpCode() {
        let transport = FakeTransport()
        transport.script = [.success((500, Data()))]  // then the script runs dry
        let api = makeApi(transport)

        let token = api.fetchOneTimeToken(config: makeConfig(), appId: "a")

        XCTAssertNil(token)
        XCTAssertNil(api.lastHttpCode)
    }

    func testAllTransportFailuresReturnNilWithNoHttpCode() {
        let transport = FakeTransport()
        transport.script = []  // every call throws
        let api = makeApi(transport)

        let token = api.fetchOneTimeToken(config: makeConfig(), appId: "a")

        XCTAssertNil(token)
        XCTAssertEqual(transport.calls.count, 3, "transport errors retry to the attempt cap")
        XCTAssertNil(api.lastHttpCode, "no HTTP response ⇒ NETWORK classification")
        XCTAssertNotNil(api.lastError)
    }

    func testMalformedBodyRetries() {
        let transport = FakeTransport()
        transport.script = [
            .success((200, Data("not json".utf8))),
            .success((200, Data(#"{"unexpected":"shape"}"#.utf8))),
            ok("third"),
        ]
        let api = makeApi(transport)

        let token = api.fetchOneTimeToken(config: makeConfig(), appId: "a")

        XCTAssertEqual(token, "third")
        XCTAssertEqual(transport.calls.count, 3)
    }

    func testHttpCodeResetBetweenCalls() {
        let transport = FakeTransport()
        transport.script = [.success((403, Data())), ok()]
        let api = makeApi(transport)

        _ = api.fetchOneTimeToken(config: makeConfig(), appId: "a")
        XCTAssertEqual(api.lastHttpCode, 403)

        _ = api.fetchOneTimeToken(config: makeConfig(), appId: "a")
        XCTAssertNil(api.lastHttpCode, "lastHttpCode must reset on a new call")
    }
}
