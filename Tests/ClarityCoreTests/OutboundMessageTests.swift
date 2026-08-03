import XCTest
@testable import ClaritySDK

final class OutboundMessageTests: XCTestCase {

    private func parse(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONEncoding.object(from: json), "not a JSON object: \(json)")
    }

    func testSetDeviceTokenAlwaysCarriesIosPlatform() throws {
        let object = try parse(OutboundMessage.setDeviceToken("abc123"))
        XCTAssertEqual(object["action"] as? String, "setDeviceToken")
        XCTAssertEqual(object["token"] as? String, "abc123")
        // The page defaults a missing platform to "android" — ios must be explicit.
        XCTAssertEqual(object["platform"] as? String, "ios")
    }

    func testSetUserAttributes() throws {
        let object = try parse(OutboundMessage.setAttributes(["plan": "gold"], scope: .user))
        XCTAssertEqual(object["action"] as? String, "setUserAttributes")
        XCTAssertEqual(object["attributes"] as? [String: String], ["plan": "gold"])
    }

    func testSetTicketAttributes() throws {
        let object = try parse(OutboundMessage.setAttributes(["topic": "billing"], scope: .ticket))
        XCTAssertEqual(object["action"] as? String, "setTicketAttributes")
        XCTAssertEqual(object["attributes"] as? [String: String], ["topic": "billing"])
    }

    /// Typed values keep their JSON types through the bridge payload; `.null`
    /// serializes as a JSON null (backend: "remove this key").
    func testSetAttributesTypedValues() throws {
        let object = try parse(OutboundMessage.setAttributes(
            ["seats": 7, "rate": 0.5, "vip": true, "region": ["emea"], "legacy": nil],
            scope: .user
        ))
        let attributes = try XCTUnwrap(object["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["seats"] as? Int, 7)
        XCTAssertEqual(attributes["rate"] as? Double, 0.5)
        XCTAssertEqual(attributes["vip"] as? Bool, true)
        XCTAssertEqual(attributes["region"] as? [String], ["emea"])
        XCTAssertTrue(attributes["legacy"] is NSNull)
    }

    func testLogEvent() throws {
        let object = try parse(OutboundMessage.logEvent(name: "opened_cart", params: ["items": "3"]))
        XCTAssertEqual(object["action"] as? String, "logEvent")
        XCTAssertEqual(object["name"] as? String, "opened_cart")
        XCTAssertEqual(object["params"] as? [String: String], ["items": "3"])
    }

    func testRefreshConversation() throws {
        let object = try parse(OutboundMessage.refreshConversation())
        XCTAssertEqual(object["action"] as? String, "refreshConversation")
        XCTAssertEqual(object.count, 1, "action-only payload — no extra fields")
    }

    func testWidgetVisibilityChanged() throws {
        let visible = try parse(OutboundMessage.widgetVisibilityChanged(visible: true))
        XCTAssertEqual(visible["action"] as? String, "widgetVisibilityChanged")
        XCTAssertEqual(visible["visible"] as? Bool, true)

        let hidden = try parse(OutboundMessage.widgetVisibilityChanged(visible: false))
        XCTAssertEqual(hidden["visible"] as? Bool, false)
    }

    func testDeterministicOutput() {
        XCTAssertEqual(
            OutboundMessage.setAttributes(["b": "2", "a": "1"], scope: .user),
            OutboundMessage.setAttributes(["a": "1", "b": "2"], scope: .user)
        )
    }

    /// The log line built from this must never be able to carry the payload —
    /// device tokens, attribute values and event params live in there.
    func testLoggableSummaryDropsEverySensitiveField() {
        let token = OutboundMessage.setDeviceToken("apns-secret-token")
        XCTAssertEqual(OutboundMessage.loggableSummary(ofPayload: token), "setDeviceToken")

        let attributes = OutboundMessage.setAttributes(["email": "a@b.c"], scope: .user)
        XCTAssertEqual(
            OutboundMessage.loggableSummary(ofPayload: attributes), AttributeScope.user.action
        )
        XCTAssertFalse(OutboundMessage.loggableSummary(ofPayload: attributes).contains("a@b.c"))

        let event = OutboundMessage.logEvent(name: "checkout", params: ["cart": "42"])
        XCTAssertEqual(OutboundMessage.loggableSummary(ofPayload: event), "logEvent")
        XCTAssertFalse(OutboundMessage.loggableSummary(ofPayload: event).contains("checkout"))

        XCTAssertEqual(OutboundMessage.loggableSummary(ofPayload: "not json"), "unknown")
        XCTAssertEqual(OutboundMessage.loggableSummary(ofPayload: #"{"no":"action"}"#), "unknown")
    }

    /// The visibility flag stays in the log: badge/notification timing is
    /// diagnosed from the order of these flips against message delivery, and it
    /// is SDK-generated, never host data.
    func testLoggableSummaryKeepsTheVisibilityFlag() {
        XCTAssertEqual(
            OutboundMessage.loggableSummary(
                ofPayload: OutboundMessage.widgetVisibilityChanged(visible: true)
            ),
            "widgetVisibilityChanged visible=true"
        )
        XCTAssertEqual(
            OutboundMessage.loggableSummary(
                ofPayload: OutboundMessage.widgetVisibilityChanged(visible: false)
            ),
            "widgetVisibilityChanged visible=false"
        )
    }
}
