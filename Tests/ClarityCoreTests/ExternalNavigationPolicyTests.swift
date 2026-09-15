import XCTest
@testable import ClaritySDK

/// The rule that decides "stay in the widget WebView" vs "hand to the browser".
///
/// Getting it wrong is expensive in both directions: too eager and the widget's
/// own iframe is cancelled and its document opens in the browser (html widgets
/// rendered as an empty box in 1.1.0 for exactly this reason); too lax and a
/// link in a message replaces the live conversation.
final class ExternalNavigationPolicyTests: XCTestCase {

    private let base = "https://live-chat.example.com"

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    private func shouldOpen(_ string: String, isSubframe: Bool) throws -> Bool {
        ExternalNavigationPolicy.shouldOpenExternally(
            url: try url(string),
            baseUrl: base,
            isSubframe: isSubframe
        )
    }

    // MARK: - The regression this file exists for

    /// The html widget's document: presigned object storage, cross-origin by
    /// design, reached by a 302 from a same-origin `/api/...` iframe src.
    func testSubframeNavigationToStorageStaysInTheWebView() throws {
        XCTAssertFalse(
            try shouldOpen(
                "https://storage.googleapis.com/bucket/widget-html/146/abc-v3.html?Signature=x",
                isSubframe: true
            )
        )
    }

    /// The same URL in the MAIN frame is a real navigation away from the chat.
    func testSameUrlInMainFrameStillGoesToTheBrowser() throws {
        XCTAssertTrue(
            try shouldOpen(
                "https://storage.googleapis.com/bucket/widget-html/146/abc-v3.html?Signature=x",
                isSubframe: false
            )
        )
    }

    // MARK: - Links still leave

    func testForeignMainFrameLinkOpensExternally() throws {
        XCTAssertTrue(try shouldOpen("https://example.com/article", isSubframe: false))
    }

    /// A scheme or port change is a different origin even on the same host —
    /// otherwise a downgraded link could replace the conversation in place.
    func testSchemeAndPortChangesAreForeign() throws {
        XCTAssertTrue(try shouldOpen("http://live-chat.example.com/x", isSubframe: false))
        XCTAssertTrue(try shouldOpen("https://live-chat.example.com:8443/x", isSubframe: false))
    }

    // MARK: - Stays inside

    func testOwnOriginStaysInTheWebView() throws {
        XCTAssertFalse(
            try shouldOpen("https://live-chat.example.com/api/conversation", isSubframe: false)
        )
    }

    /// The page's own plumbing has no host and must never be handed away.
    func testHostlessUrlsStayInTheWebView() throws {
        XCTAssertFalse(try shouldOpen("about:blank", isSubframe: false))
        XCTAssertFalse(try shouldOpen("data:text/html,<p>hi</p>", isSubframe: false))
    }

    /// A missing or unusable baseUrl disables the hand-off rather than sending
    /// every navigation to the browser.
    func testUnusableBaseUrlNeverOpensExternally() throws {
        for baseUrl in [nil, "", "not a url", "ftp://files.example.com"] {
            XCTAssertFalse(
                ExternalNavigationPolicy.shouldOpenExternally(
                    url: try url("https://example.com/article"),
                    baseUrl: baseUrl,
                    isSubframe: false
                ),
                "baseUrl \(baseUrl ?? "nil") should disable the hand-off"
            )
        }
    }
}
