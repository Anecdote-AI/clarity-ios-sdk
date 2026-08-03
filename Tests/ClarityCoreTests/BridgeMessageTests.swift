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
