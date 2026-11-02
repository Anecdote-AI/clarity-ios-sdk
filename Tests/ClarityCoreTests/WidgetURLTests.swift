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
        token: String = "t",
        microphoneAvailable: Bool = false
    ) -> String {
        WidgetURL.build(
            config: config,
            user: user,
            userAttributes: userAttributes,
            ticketAttributes: ticketAttributes,
            oneTimeToken: token,
            microphoneAvailable: microphoneAvailable
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

    /// Everything before the fragment: the request line WebKit sends, which
    /// nginx and the ingress write to their access logs.
    private func requestPart(_ url: String) -> String {
        String(url.prefix { $0 != "#" })
    }

    private func fragment(_ url: String) -> String? {
        url.firstIndex(of: "#").map { String(url[url.index(after: $0)...]) }
    }

    func testJwtRidesTheFragmentNotTheQuery() {
        let user = ClarityUser(externalId: "u_8891", jwt: "header.payload.signature")

        let url = build(makeTestConfig(), user: user)

        XCTAssertEqual(fragment(url), "jwt=header.payload.signature", url)
        XCTAssertFalse(requestPart(url).contains("header.payload.signature"), url)
        XCTAssertFalse(requestPart(url).contains("jwt="), url)
        XCTAssertTrue(url.contains("identity=verified"), url)
        XCTAssertFalse(url.contains("identity=unverified"), url)
        // Foundation agrees on where the query ends and the fragment starts.
        let components = URLComponents(string: url)
        XCTAssertEqual(components?.fragment, "jwt=header.payload.signature")
        XCTAssertNil(components?.queryItems?.first { $0.name == "jwt" })
    }

    func testJwtInTheFragmentIsEncodedLikeEveryOtherValue() {
        let url = build(makeTestConfig(), user: ClarityUser(jwt: "a+b/c=.d.e"))

        XCTAssertEqual(fragment(url), "jwt=a%2Bb%2Fc%3D.d.e", url)
        XCTAssertNotNil(URL(string: url), url)
    }

    func testJwtLeavesTheQueryExactlyAsWithoutIt() {
        let config = makeTestConfig()
        let without = build(config, user: ClarityUser(externalId: "u_8891"))
            .replacingOccurrences(of: "identity=unverified", with: "identity=verified")
        let with = build(config, user: ClarityUser(externalId: "u_8891", jwt: "h.p.s"))

        XCTAssertEqual(requestPart(with), without)
    }

    func testAKilobyteSizedJwtKeepsTheRequestLineShort() {
        let bigToken = "h." + String(repeating: "p", count: 10 * 1024) + ".s"

        let url = build(makeTestConfig(), user: ClarityUser(jwt: bigToken))

        XCTAssertLessThan(requestPart(url).count, 1024)
        XCTAssertEqual(fragment(url), "jwt=\(bigToken)")
    }

    func testARefreshedJwtStillChangesTheURL() {
        let config = makeTestConfig()
        let first = build(config, user: ClarityUser(externalId: "u_8891", jwt: "old.token.value"))
        let refreshed = build(config, user: ClarityUser(externalId: "u_8891", jwt: "new.token.value"))

        XCTAssertNotEqual(first, refreshed)
    }

    func testWithoutJwtTheIdentityStaysUnverified() {
        let url = build(makeTestConfig(), user: ClarityUser(externalId: "u_8891"))

        XCTAssertTrue(url.contains("identity=unverified"), url)
        XCTAssertFalse(url.contains("jwt="), url)
        XCTAssertNil(fragment(url), url)
    }

    func testLoggedURLDropsTheQueryAndTheFragment() {
        let url = build(makeTestConfig(), user: ClarityUser(jwt: "header.payload.signature"))

        let logged = WidgetURL.redactedForLog(url)

        XCTAssertEqual(logged, "https://chat.example.com/")
        XCTAssertEqual(
            WidgetURL.redactedForLog("https://chat.example.com/page#jwt=header.payload.signature"),
            "https://chat.example.com/page"
        )
    }

    func testChangingTheJwtAloneIsNotAnAccountSwitch() {
        let first = ClarityUser(externalId: "u_8891", jwt: "old.token.value")
        let refreshed = ClarityUser(externalId: "u_8891", jwt: "new.token.value")

        XCTAssertFalse(first.requiresSessionIsolation(switchingTo: refreshed))
    }

    func testTheJwtNeverShowsUpInTheUserDescription() {
        let user = ClarityUser(externalId: "u_8891", jwt: "header.payload.signature")

        XCTAssertFalse("\(user)".contains("header.payload.signature"))
        XCTAssertFalse(String(reflecting: user).contains("header.payload.signature"))
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
        let direct = build(
            config,
            token: "ONE_TIME_TOKEN",
            microphoneAvailable: HostCapabilities.microphoneCaptureProvisioned
        )
        XCTAssertEqual(preview, direct)
    }

    // The page offers voice and dictation inside the SDK only when the URL
    // says the host can grant the microphone — a wrong answer is silent: a
    // dead mic button, or none at all.
    func testMicrophoneCapabilityAdvertisedWhenProvisioned() {
        let url = build(makeTestConfig(), microphoneAvailable: true)
        XCTAssertTrue(url.contains("&nativeCapabilities=microphone"))
    }

    func testMicrophoneCapabilityOmittedWhenNotProvisioned() {
        let url = build(makeTestConfig(), microphoneAvailable: false)
        XCTAssertFalse(url.contains("nativeCapabilities="))
    }

    func testMicrophoneCapabilityLeavesTheRestOfTheUrlAlone() {
        let without = build(makeTestConfig())
        let with = build(makeTestConfig(), microphoneAvailable: true)
        XCTAssertEqual(with.replacingOccurrences(of: "&nativeCapabilities=microphone", with: ""), without)
    }
}
