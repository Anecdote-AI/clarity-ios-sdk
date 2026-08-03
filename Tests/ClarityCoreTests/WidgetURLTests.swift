import XCTest
@testable import ClaritySDK

final class WidgetURLTests: XCTestCase {

    /// Five of the six tests pass the identical empty user/attribute set —
    /// only the varying inputs appear at the call sites.
    private func build(
        _ config: ClarityConfig,
        user: ClarityUser = ClarityUser(),
        userAttributes: [String: ClarityAttributeValue] = [:],
        ticketAttributes: [String: ClarityAttributeValue] = [:],
        token: String = "t"
    ) -> String {
        WidgetURL.build(
            config: config,
            user: user,
            userAttributes: userAttributes,
            ticketAttributes: ticketAttributes,
            oneTimeToken: token
        )
    }

    func testMinimalUrlExactShape() {
        let url = build(makeTestConfig(baseUrl: "https://chat.example.com/"), token: "tok123")
        XCTAssertEqual(
            url,
            "https://chat.example.com/?oneTimeToken=tok123"
                + "&nativeMode=ios"
                + "&layout=mobile"
                + "&placement=right"
                + "&identity=unverified"
                + "&mode=live_chat"
                + "&widgetType=live_chat"
                + "&organizationId=42"
                + "&integrationKey=test-key"
                + "&sdkVersion=\(ClarityVersion.current)"
        )
    }

    func testTrailingSlashesTrimmed() {
        let url = build(makeTestConfig(baseUrl: "https://chat.example.com///"))
        XCTAssertTrue(url.hasPrefix("https://chat.example.com/?oneTimeToken=t&"))
    }

    func testOptionalParamsAppendInAndroidOrder() {
        var config = makeTestConfig()
        config.language = "de"
        let user = ClarityUser(
            externalId: "u-1",
            firstName: "Ada",
            lastName: "L",
            email: "ada@example.com",
            phone: "+49 1",
            avatar: "https://a.example.com/p.png",
            userHash: "deadbeef"
        )
        let url = build(config, user: user)

        let expectedOrder = [
            "language=de",
            "externalId=u-1",
            "firstName=Ada",
            "lastName=L",
            "email=ada%40example.com",
            "phone=%2B49+1",
            "avatar=https%3A%2F%2Fa.example.com%2Fp.png",
            "userHash=deadbeef",
        ]
        var searchStart = url.startIndex
        for fragment in expectedOrder {
            guard let range = url.range(of: fragment, range: searchStart..<url.endIndex) else {
                return XCTFail("missing or out-of-order fragment: \(fragment) in \(url)")
            }
            searchStart = range.upperBound
        }
    }

    func testAttributesAppendAsJsonObjects() {
        let url = build(
            makeTestConfig(),
            userAttributes: ["b": 2, "a": "1", "c": true],
            ticketAttributes: ["topic": "billing"]
        )
        // {"a":"1","b":2,"c":true} percent-encoded (keys sorted for
        // determinism); numbers/booleans stay real JSON types. The user
        // scope rides the web-inject param name `customAttributes`.
        XCTAssertTrue(
            url.contains("customAttributes=%7B%22a%22%3A%221%22%2C%22b%22%3A2%2C%22c%22%3Atrue%7D"),
            "customAttributes JSON missing/wrong in \(url)"
        )
        XCTAssertTrue(
            url.contains("ticketAttributes=%7B%22topic%22%3A%22billing%22%7D"),
            "ticketAttributes JSON missing/wrong in \(url)"
        )
        // customAttributes must precede ticketAttributes (Android order)
        let userIdx = url.range(of: "customAttributes=")!.lowerBound
        let ticketIdx = url.range(of: "ticketAttributes=")!.lowerBound
        XCTAssertLessThan(userIdx, ticketIdx)
    }

    /// The page's customAttributes parser rejects the whole object when ANY
    /// value is non-primitive, so lists and removals never ride the URL —
    /// they flow through the bridge flush after page load instead.
    func testNonPrimitiveAttributeValuesFilteredFromUrl() {
        let url = build(
            makeTestConfig(),
            userAttributes: ["plan": "gold", "region": ["emea"], "legacy": nil],
            ticketAttributes: ["abcd": ["a"]]
        )
        XCTAssertTrue(
            url.contains("customAttributes=%7B%22plan%22%3A%22gold%22%7D"),
            "primitives should survive the URL filter in \(url)"
        )
        // ticketAttributes had ONLY non-primitives → param omitted entirely.
        XCTAssertFalse(url.contains("ticketAttributes="))
    }

    func testNonFiniteAttributeValuesDroppedNotPoisoning() {
        // One NaN must not void the whole param (JSONSerialization rejects
        // any container holding a non-finite double).
        let url = build(
            makeTestConfig(),
            userAttributes: [
                "plan": "gold",
                "bad": .double(Double.nan),
                "worse": .double(.infinity),
            ]
        )
        XCTAssertTrue(
            url.contains("customAttributes=%7B%22plan%22%3A%22gold%22%7D"),
            "finite attributes must survive a sibling NaN in \(url)"
        )
    }

    func testEmptyAttributesOmitted() {
        let url = build(makeTestConfig())
        XCTAssertFalse(url.contains("customAttributes="))
        XCTAssertFalse(url.contains("ticketAttributes="))
    }

    func testPreviewApiUsesSameBuilder() {
        let config = makeTestConfig()
        let preview = Clarity.previewWidgetUrl(config: config)
        let direct = build(config, token: "ONE_TIME_TOKEN")
        XCTAssertEqual(preview, direct)
    }
}
