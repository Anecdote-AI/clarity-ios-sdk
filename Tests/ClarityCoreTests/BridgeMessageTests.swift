import XCTest
@testable import ClaritySDK

final class BridgeMessageTests: XCTestCase {

    /// One assertion shape for every parse case; `nil` = expected parse failure.
    private func assertParse(
        _ json: String,
        _ expected: BridgeMessage?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(BridgeMessage.parse(json), expected, file: file, line: line)
    }

    func testPageLoaded() {
        assertParse(#"{"action":"pageLoaded"}"#, .pageLoaded)
    }

    func testPageLoadedErrorWithFullPayload() {
        assertParse(
            #"{"action":"pageLoadedError","error":{"code":503,"message":"boot failed"}}"#,
            .pageLoadedError(code: 503, message: "boot failed")
        )
    }

    func testPageLoadedErrorDefaultsWhenErrorMissing() {
        assertParse(#"{"action":"pageLoadedError"}"#, .pageLoadedError(code: 0, message: "unknown"))
    }

    /// The REAL payload the live-chat page sends when its `session/complete`
    /// is rejected — byte-identical to the literal asserted in
    /// `nativeSdkSessionRejected.test.ts` and `MessageActionTest.kt`. This is
    /// the path a customer hit: without it the SDK could only report a generic
    /// load timeout 15s later.
    func testRejectedSessionPayloadFromTheLiveChatPage() {
        assertParse(
            #"{"action":"pageLoadedError","error":{"code":422,"message":"live chat session was not completed: required contact attributes are missing (company, plan) - set them before the widget loads"}}"#,
            .pageLoadedError(
                code: 422,
                message: "live chat session was not completed: required contact attributes "
                    + "are missing (company, plan) - set them before the widget loads"
            )
        )
    }

    func testContentHeightRequiresHeight() {
        assertParse(
            #"{"action":"contentHeightDidChange","height":420.5}"#,
            .contentHeightDidChange(height: 420.5)
        )
        // Android's getDouble throws on absence — parse failure, not zero.
        assertParse(#"{"action":"contentHeightDidChange"}"#, nil)
    }

    func testClose() {
        assertParse(#"{"action":"close"}"#, .close)
    }

    func testNewMessageDefaultsToEmptyText() {
        assertParse(#"{"action":"newMessage","text":"hi"}"#, .newMessage(text: "hi"))
        assertParse(#"{"action":"newMessage"}"#, .newMessage(text: ""))
    }

    func testUnreadCountDefaultsToZero() {
        assertParse(#"{"action":"unreadCountDidChange","count":3}"#, .unreadCountDidChange(count: 3))
        assertParse(#"{"action":"unreadCountDidChange"}"#, .unreadCountDidChange(count: 0))
    }

    func testOpenImageAndLink() {
        assertParse(#"{"action":"openImage","url":"https://x/img.png"}"#, .openImage(url: "https://x/img.png"))
        assertParse(#"{"action":"openLink","url":"https://x/page"}"#, .openLink(url: "https://x/page"))
    }

    /// An html screen asking for the room around the chat window. A bottom
    /// sheet bounds the page at its own height, so `fullScreen` is the only
    /// way a screen can cover the device; `default` gives the host app's own
    /// presentation back. Anything else means the host's presentation too — a
    /// word we do not know is no reason to throw a sheet open over the app.
    /// Same cases as Android's `MessageActionTest`.
    func testPresentationRequestDecodesTheOneWordThatMeansFullScreen() {
        assertParse(
            #"{"action":"requestPresentation","presentation":"fullScreen"}"#,
            .requestPresentation(fullScreen: true)
        )
        assertParse(
            #"{"action":"requestPresentation","presentation":"default"}"#,
            .requestPresentation(fullScreen: false)
        )
        assertParse(
            #"{"action":"requestPresentation"}"#,
            .requestPresentation(fullScreen: false)
        )
        assertParse(
            #"{"action":"requestPresentation","presentation":"sheet"}"#,
            .requestPresentation(fullScreen: false)
        )
    }

    func testUnknownActionPreserved() {
        assertParse(#"{"action":"somethingNew"}"#, .unknown(action: "somethingNew"))
    }

    func testUnparseableInputsReturnNil() {
        assertParse("not json", nil)
        assertParse("{}", nil)
        assertParse(#"{"action":42}"#, nil)
        assertParse(#"[1,2,3]"#, nil)
        assertParse("", nil)
    }

    /// Extra fields must never break parsing (the page may evolve first).
    func testExtraFieldsTolerated() {
        assertParse(#"{"action":"pageLoaded","future":"field"}"#, .pageLoaded)
    }
}
