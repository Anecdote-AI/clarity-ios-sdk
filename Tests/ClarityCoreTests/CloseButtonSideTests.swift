import XCTest
@testable import ClaritySDK

/// The native ✕ follows the chat, not the app: before this, an English app
/// with `language: "ar"` pinned it right while the page's own ✕ sat left.
final class CloseButtonSideTests: XCTestCase {

    func testAnArabicPageInAnEnglishAppPutsItLeft() {
        XCTAssertEqual(CloseButtonSide.forPage(htmlDir: "rtl", hostIsRightToLeft: false), .left)
    }

    func testAnEnglishPageInAnArabicAppPutsItRight() {
        XCTAssertEqual(CloseButtonSide.forPage(htmlDir: "ltr", hostIsRightToLeft: true), .right)
    }

    func testTheDirectionIsReadLeniently() {
        XCTAssertEqual(CloseButtonSide.forPage(htmlDir: " RTL\n", hostIsRightToLeft: false), .left)
    }

    func testAnUnknownDirectionKeepsTheHostsSide() {
        XCTAssertEqual(CloseButtonSide.forPage(htmlDir: nil, hostIsRightToLeft: false), .right)
        XCTAssertEqual(CloseButtonSide.forPage(htmlDir: "", hostIsRightToLeft: true), .left)
        XCTAssertEqual(CloseButtonSide.forPage(htmlDir: "auto", hostIsRightToLeft: true), .left)
    }
}
