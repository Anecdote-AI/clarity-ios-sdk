import XCTest
@testable import ClaritySDK

/// Who may talk to the SDK over `webkit.messageHandlers.clarityBridge`: the
/// live chat page, which is the main frame at the widget's own origin — not
/// an html-widget iframe inside it, and not a page at another origin.
final class BridgeFrameFilterTests: XCTestCase {

    private let base = "https://live-chat.example.com"

    private func accepts(
        mainFrame: Bool = true,
        _ scheme: String = "https",
        _ host: String = "live-chat.example.com",
        port: Int = 0,
        baseUrl: String? = "https://live-chat.example.com"
    ) -> Bool {
        BridgeFrameFilter.accepts(
            isMainFrame: mainFrame,
            originProtocol: scheme,
            originHost: host,
            originPort: port,
            baseUrl: baseUrl
        )
    }

    func testTheMainFrameAtTheWidgetOriginIsAccepted() {
        XCTAssertTrue(accepts())
        XCTAssertTrue(accepts(baseUrl: "https://live-chat.example.com/some/path/"), "only the origin of the base URL counts")
        XCTAssertTrue(accepts("HTTPS", "Live-Chat.Example.com"), "scheme and host compare case-insensitively")
    }

    /// The finding: an html-widget iframe reached the handler and ran host
    /// tools. A subframe is dropped whatever its origin — a sandboxed widget
    /// has an opaque one, but a same-origin subframe is no better.
    func testASubframeIsDropped() {
        XCTAssertFalse(accepts(mainFrame: false))
        XCTAssertFalse(accepts(mainFrame: false, "", ""), "a sandboxed iframe's opaque origin")
        XCTAssertFalse(accepts(mainFrame: false, "https", "storage.googleapis.com"))
    }

    func testAnotherOriginIsDropped() {
        XCTAssertFalse(accepts("https", "evil.example.com"))
        XCTAssertFalse(accepts("https", "live-chat.example.com.evil.com"))
        XCTAssertFalse(accepts("http", "live-chat.example.com"), "another scheme is another origin")
        XCTAssertFalse(accepts("https", "live-chat.example.com", port: 8443), "another port is another origin")
        XCTAssertFalse(accepts("", ""), "an opaque origin")
        XCTAssertFalse(accepts("about", ""), "about:blank")
    }

    /// WebKit reports a default port as 0; a base URL may spell it out.
    func testADefaultPortMatchesWrittenEitherWay() {
        XCTAssertTrue(accepts(port: 0, baseUrl: "https://live-chat.example.com:443"))
        XCTAssertTrue(accepts(port: 443, baseUrl: base))
        XCTAssertTrue(accepts("http", "localhost", port: 0, baseUrl: "http://localhost:80"))
        XCTAssertTrue(accepts("http", "localhost", port: 80, baseUrl: "http://localhost"), "explicit 80 against an implied one")
        XCTAssertFalse(accepts("http", "localhost", port: 443, baseUrl: "http://localhost"), "443 is not http's default")
        XCTAssertFalse(accepts("https", "live-chat.example.com", port: 80, baseUrl: base), "80 is not https's default")
        XCTAssertTrue(accepts("http", "localhost", port: 6174, baseUrl: "http://localhost:6174"))
        XCTAssertFalse(accepts("http", "localhost", port: 0, baseUrl: "http://localhost:6174"))
        XCTAssertFalse(accepts("http", "localhost", port: 6174, baseUrl: "http://localhost"))
    }

    func testAnIPv6HostMatchesWithOrWithoutBrackets() {
        XCTAssertTrue(accepts("http", "[::1]", port: 8080, baseUrl: "http://[::1]:8080"))
        XCTAssertTrue(accepts("http", "::1", port: 8080, baseUrl: "http://[::1]:8080"))
    }

    /// No usable base URL accepts nothing rather than everything.
    func testWithoutAUsableBaseUrlNothingIsAccepted() {
        XCTAssertFalse(accepts(baseUrl: nil))
        XCTAssertFalse(accepts(mainFrame: true, "https", "live-chat.example.com", port: 443, baseUrl: nil), "not even the right origin")
        XCTAssertFalse(accepts(baseUrl: ""))
        XCTAssertFalse(accepts(baseUrl: "not a url"))
        XCTAssertFalse(accepts("file", "", baseUrl: "file:///tmp/chat.html"))
    }
}
