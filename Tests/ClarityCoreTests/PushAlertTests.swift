import XCTest
@testable import ClaritySDK

/// `handlePush` posts nothing for a push the system shows by itself, so a
/// Clarity alert push is never shown twice.
final class PushAlertTests: XCTestCase {

    func testAnAlertPushIsShownBySystem() {
        let push: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Anna", "body": "Your order has shipped."]],
            "clarity_push": "true",
            "ticket_id": "123",
        ]
        XCTAssertTrue(PushAlert.isShownBySystem(push))
        XCTAssertTrue(PushAlert.isShownBySystem(["aps": ["alert": "Hi"]]))
    }

    func testADataPayloadIsLeftToTheSdk() {
        XCTAssertFalse(PushAlert.isShownBySystem(["clarity_push": "true", "body": "Hi"]))
        XCTAssertFalse(PushAlert.isShownBySystem(["aps": ["content-available": 1]]))
        XCTAssertFalse(PushAlert.isShownBySystem(["aps": ["alert": ""]]))
    }
}
