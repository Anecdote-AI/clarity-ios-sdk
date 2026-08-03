import XCTest
@testable import ClaritySDK

/// Byte-parity with `java.net.URLEncoder.encode(value, "UTF-8")` — the widget
/// URL must be identical to the one the Android SDK builds.
final class FormURLEncoderTests: XCTestCase {

    func testUnreservedCharactersPassThrough() {
        XCTAssertEqual(
            FormURLEncoder.encode("AZaz09.-*_"),
            "AZaz09.-*_"
        )
    }

    func testSpaceBecomesPlus() {
        XCTAssertEqual(FormURLEncoder.encode("a b  c"), "a+b++c")
    }

    func testReservedAsciiIsPercentEncodedUppercase() {
        XCTAssertEqual(FormURLEncoder.encode("+"), "%2B")
        XCTAssertEqual(FormURLEncoder.encode("/"), "%2F")
        XCTAssertEqual(FormURLEncoder.encode("="), "%3D")
        XCTAssertEqual(FormURLEncoder.encode("&"), "%26")
        XCTAssertEqual(FormURLEncoder.encode("?"), "%3F")
        XCTAssertEqual(FormURLEncoder.encode("@"), "%40")
        XCTAssertEqual(FormURLEncoder.encode(":"), "%3A")
        XCTAssertEqual(FormURLEncoder.encode("~"), "%7E")
    }

    func testUnicodeEncodesUtf8Bytes() {
        XCTAssertEqual(FormURLEncoder.encode("😀"), "%F0%9F%98%80")
        XCTAssertEqual(FormURLEncoder.encode("é"), "%C3%A9")
    }

    func testControlCharacters() {
        XCTAssertEqual(FormURLEncoder.encode("\n"), "%0A")
        XCTAssertEqual(FormURLEncoder.encode("\u{0000}"), "%00")
    }

    /// The hostile-content string FailureModesTest K5 sends through identity
    /// fields on Android — must encode without loss.
    func testHostileContentRoundTripShape() {
        let hostile = "';</script>😀\nline2"
        let encoded = FormURLEncoder.encode(hostile)
        XCTAssertEqual(
            encoded,
            "%27%3B%3C%2Fscript%3E%F0%9F%98%80%0Aline2"
        )
    }
}
