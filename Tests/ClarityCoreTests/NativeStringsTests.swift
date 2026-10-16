import XCTest
@testable import ClaritySDK

/// The SDK's own strings follow the chat's language. Before, they were English
/// whatever the chat spoke — an Arabic chat sent "New message from support".
final class NativeStringsTests: XCTestCase {

    func testAnArabicChatGetsArabicStrings() {
        XCTAssertEqual(
            NativeStrings.text(.notificationTitle, language: "ar", preferredLanguages: ["en-US"]),
            "رسالة جديدة من الدعم"
        )
        XCTAssertEqual(NativeStrings.text(.close, language: "ar-SA", preferredLanguages: []), "إغلاق")
        XCTAssertEqual(
            NativeStrings.text(.imageRetry, language: " ar_EG ", preferredLanguages: []), "حاول مرة أخرى"
        )
    }

    func testTheConfiguredLanguageWinsOverTheDevice() {
        XCTAssertEqual(
            NativeStrings.text(.close, language: "en", preferredLanguages: ["ar-SA"]), "Close"
        )
    }

    func testWithoutAConfiguredLanguageTheDeviceDecides() {
        XCTAssertEqual(NativeStrings.text(.close, language: nil, preferredLanguages: ["ar-AE"]), "إغلاق")
        XCTAssertEqual(NativeStrings.text(.close, language: "  ", preferredLanguages: ["ar"]), "إغلاق")
        XCTAssertEqual(NativeStrings.text(.close, language: nil, preferredLanguages: ["en-GB"]), "Close")
    }

    func testALanguageWithoutTranslationsGetsEnglish() {
        XCTAssertEqual(
            NativeStrings.text(.imageLoadFailed, language: "de", preferredLanguages: []),
            "Couldn't load image"
        )
        XCTAssertEqual(NativeStrings.text(.close, language: nil, preferredLanguages: []), "Close")
    }

    func testEveryStringHasBothLanguages() {
        for key in NativeStrings.Key.allCases {
            XCTAssertNotNil(NativeStrings.english[key], "\(key) has no English text")
            XCTAssertNotNil(NativeStrings.arabic[key], "\(key) has no Arabic text")
        }
    }
}
