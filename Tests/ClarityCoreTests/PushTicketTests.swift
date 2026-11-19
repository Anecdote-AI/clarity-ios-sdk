import Foundation
import XCTest
@testable import ClaritySDK

/// The ticket a Clarity push names (`ticket_id`), read from a remote push or
/// from the SDK's own local notification. Android twin: `PushTicketTest.kt`.
final class PushTicketTests: XCTestCase {

    func testReadsThePositiveIdTheBackendSendsAsAString() {
        XCTAssertEqual(PushTicket.parse("123"), 123)
        XCTAssertEqual(PushTicket.parse(" 42 "), 42)
    }

    func testReadsANumber() {
        XCTAssertEqual(PushTicket.parse(123), 123)
        XCTAssertEqual(PushTicket.parse(NSNumber(value: 77)), 77)
    }

    /// An id the tap cannot use must not stop the tap: it opens the chat
    /// without a ticket, as before.
    func testAnythingElseIsNoTicket() {
        XCTAssertNil(PushTicket.parse(nil))
        XCTAssertNil(PushTicket.parse(""))
        XCTAssertNil(PushTicket.parse("   "))
        XCTAssertNil(PushTicket.parse("0"))
        XCTAssertNil(PushTicket.parse("-5"))
        XCTAssertNil(PushTicket.parse("+5"))
        XCTAssertNil(PushTicket.parse("12a"))
        XCTAssertNil(PushTicket.parse("1.5"))
        XCTAssertNil(PushTicket.parse("99999999999999999999"))
        XCTAssertNil(PushTicket.parse(0))
        XCTAssertNil(PushTicket.parse(-3))
        XCTAssertNil(PushTicket.parse(NSNumber(value: 1.5)))
        XCTAssertNil(PushTicket.parse(["123"]))
    }
}
