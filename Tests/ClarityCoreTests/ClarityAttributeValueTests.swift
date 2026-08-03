import XCTest
@testable import ClaritySDK

final class ClarityAttributeValueTests: XCTestCase {

    /// The one sanitizer both remaining boundaries (the engine's attribute
    /// store and the widget-URL builder) rely on. A NaN/inf is not JSON:
    /// `JSONSerialization` rejects the WHOLE containing dictionary, so one
    /// bad double would silently discard every attribute in the call —
    /// non-finite doubles must be dropped up front, and nothing else may be.
    func testDroppingNonFiniteValuesDropsOnlyNonFiniteDoubles() {
        let sanitized = ClarityAttributeValue.droppingNonFiniteValues([
            "plan": "gold",
            "seats": 7,
            "rate": 0.5,
            "vip": true,
            "region": ["emea"],
            "legacy": nil,
            "bad": .double(.nan),
            "worse": .double(-.infinity),
            "alsoBad": .double(.infinity),
        ])
        XCTAssertEqual(sanitized, [
            "plan": "gold",
            "seats": 7,
            "rate": 0.5,
            "vip": true,
            "region": ["emea"],
            "legacy": nil,
        ])
    }
}
