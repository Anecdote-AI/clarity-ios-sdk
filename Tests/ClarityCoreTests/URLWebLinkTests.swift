import XCTest
@testable import ClaritySDK

/// The navigation policy decides "stay in the widget WebView" vs "hand to the
/// browser" from `isSameOrigin`, so a wrong answer either leaks the customer
/// out of the chat or replaces the live conversation with a foreign page.
final class URLWebLinkTests: XCTestCase {

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    func testSameOriginIgnoresPathAndQuery() throws {
        XCTAssertTrue(
            try url("https://chat.example.com/live-chat?token=abc")
                .isSameOrigin(as: url("https://chat.example.com"))
        )
    }

    func testDefaultPortEqualsExplicitPort() throws {
        XCTAssertTrue(
            try url("https://chat.example.com:443/x")
                .isSameOrigin(as: url("https://chat.example.com"))
        )
        XCTAssertTrue(
            try url("http://chat.example.com")
                .isSameOrigin(as: url("http://chat.example.com:80"))
        )
    }

    func testDifferentPortIsForeign() throws {
        XCTAssertFalse(
            try url("https://chat.example.com")
                .isSameOrigin(as: url("https://chat.example.com:8443"))
        )
    }

    func testSchemeChangeIsForeign() throws {
        XCTAssertFalse(
            try url("http://chat.example.com")
                .isSameOrigin(as: url("https://chat.example.com"))
        )
    }

    func testDifferentHostIsForeign() throws {
        XCTAssertFalse(
            try url("https://evil.example.com")
                .isSameOrigin(as: url("https://chat.example.com"))
        )
        // Suffix tricks must not pass as the same host.
        XCTAssertFalse(
            try url("https://chat.example.com.evil.test")
                .isSameOrigin(as: url("https://chat.example.com"))
        )
    }

    func testCaseInsensitiveSchemeAndHost() throws {
        XCTAssertTrue(
            try url("HTTPS://Chat.Example.COM/x")
                .isSameOrigin(as: url("https://chat.example.com"))
        )
    }

    func testHostlessURLIsNeverSameOrigin() throws {
        XCTAssertFalse(
            try url("about:blank").isSameOrigin(as: url("https://chat.example.com"))
        )
    }

    func testIsWebLink() throws {
        XCTAssertTrue(try url("https://example.com").isWebLink)
        XCTAssertTrue(try url("http://example.com").isWebLink)
        XCTAssertFalse(try url("mailto:support@example.com").isWebLink)
        XCTAssertFalse(try url("tel:+123456789").isWebLink)
    }
}
