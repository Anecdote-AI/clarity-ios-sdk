import XCTest
@testable import ClaritySDK

final class JSONEncodingTests: XCTestCase {

    func testJavaScriptStringLiteralEscapes() {
        let literal = JSONEncoding.javaScriptStringLiteral(#"{"a":"quote\" and \n"}"#)
        XCTAssertTrue(literal.hasPrefix("\""))
        XCTAssertTrue(literal.hasSuffix("\""))
        XCTAssertFalse(literal.dropFirst().dropLast().contains("\n"))

        let newline = JSONEncoding.javaScriptStringLiteral("line1\nline2")
        XCTAssertEqual(newline, "\"line1\\nline2\"")
    }
}
