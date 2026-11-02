import XCTest
@testable import ClaritySDK

/// The app's security check, run once for a card the customer allowed. The
/// Android port (`InAppSecurityCheckTest.kt`) asserts the same messages, and
/// the page side is `requestNativeSecurityCheck` in `nativeSdkBridge.ts`.
final class InAppSecurityCheckTests: XCTestCase {

    private final class Harness {
        var sent: [String] = []
        var timers: [(Int, () -> Void)] = []
        let registry = InAppToolRegistry()
        lazy var runner = InAppToolRunner(
            registry: registry,
            send: { [unowned self] in self.sent.append($0) },
            after: { [unowned self] delay, block in self.timers.append((delay, block)) },
            isPageLoaded: { true }
        )

        func register(_ name: String, kind: ClarityToolKind = .action, requiresSecurityCheck: Bool) -> Bool {
            registry.register(ClarityTool(
                name: name,
                description: "Does \(name)",
                kind: kind,
                requiresSecurityCheck: requiresSecurityCheck
            ) { _, _ in })
        }
    }

    private func answer(_ passed: Bool) -> String {
        #"{"action":"inAppSecurityCheckResult","passed":\#(passed),"requestId":"r1"}"#
    }

    func testThePageHearsWhichToolsNeedTheCheck() {
        let harness = Harness()
        XCTAssertTrue(harness.register("remove_device", requiresSecurityCheck: true))
        XCTAssertTrue(harness.register("list_devices", kind: .read, requiresSecurityCheck: false))

        let message = harness.registry.registeredMessage()

        XCTAssertTrue(message.contains(#""securityCheck":["remove_device"]"#))
        XCTAssertFalse(message.contains("requiresSecurityCheck"), "the declarations the backend gets never carry it")
    }

    func testOnlyAnActionMayNeedTheCheck() {
        let harness = Harness()

        XCTAssertFalse(harness.register("list_devices", kind: .read, requiresSecurityCheck: true))
        XCTAssertFalse(harness.register("open_screen", kind: .safeAction, requiresSecurityCheck: true))
        XCTAssertEqual(
            InAppToolValidation.problem(with: ClarityTool(
                name: "open_screen", description: "Opens", kind: .safeAction, requiresSecurityCheck: true
            ) { _, _ in }),
            InAppToolValidation.securityCheckKindProblem
        )
    }

    func testACardThatNeedsItRunsTheCheckOnceWithItsSteps() {
        let harness = Harness()
        _ = harness.register("remove_device", requiresSecurityCheck: true)
        var asked: [[String]] = []
        harness.registry.securityCheck = { request, done in
            asked.append(request.toolNames)
            done(true)
        }

        harness.runner.securityCheck(requestId: "r1", tools: ["remove_device", "remove_device"])

        XCTAssertEqual(asked, [["remove_device", "remove_device"]])
        XCTAssertEqual(harness.sent, [answer(true)])
        XCTAssertEqual(harness.timers.map(\.0), [60_000])
    }

    func testACheckThatDidNotPassIsNotPassed() {
        let harness = Harness()
        _ = harness.register("remove_device", requiresSecurityCheck: true)
        harness.registry.securityCheck = { _, done in done(false) }

        harness.runner.securityCheck(requestId: "r1", tools: ["remove_device"])

        XCTAssertEqual(harness.sent, [answer(false)])
    }

    func testOnlyTheFirstAnswerCounts() {
        let harness = Harness()
        _ = harness.register("remove_device", requiresSecurityCheck: true)
        harness.registry.securityCheck = { _, done in
            done(false)
            done(true)
        }

        harness.runner.securityCheck(requestId: "r1", tools: ["remove_device"])
        harness.timers.forEach { $0.1() }

        XCTAssertEqual(harness.sent, [answer(false)])
    }

    func testNoAnswerWithinTheCapIsNotPassed() {
        let harness = Harness()
        _ = harness.register("remove_device", requiresSecurityCheck: true)
        var late: ((Bool) -> Void)?
        harness.registry.securityCheck = { _, done in late = done }

        harness.runner.securityCheck(requestId: "r1", tools: ["remove_device"])
        XCTAssertEqual(harness.sent, [])
        harness.timers[0].1()
        late?(true)

        XCTAssertEqual(harness.sent, [answer(false)])
    }

    func testACardThatNeedsItWithNoCheckSetDoesNotPass() {
        let harness = Harness()
        _ = harness.register("remove_device", requiresSecurityCheck: true)

        harness.runner.securityCheck(requestId: "r1", tools: ["remove_device"])

        XCTAssertEqual(harness.sent, [answer(false)])
    }

    func testACardThatDoesNotNeedItPassesWithoutAsking() {
        let harness = Harness()
        _ = harness.register("remove_device", requiresSecurityCheck: false)
        var asked = false
        harness.registry.securityCheck = { _, done in
            asked = true
            done(false)
        }

        harness.runner.securityCheck(requestId: "r1", tools: ["remove_device"])

        XCTAssertFalse(asked)
        XCTAssertEqual(harness.sent, [answer(true)])
    }

    func testTheRequestIsReadFromThePage() {
        let message = BridgeMessage.parse(#"{"action":"inAppSecurityCheck","requestId":"r1","tools":["remove_device",7]}"#)

        guard case .inAppSecurityCheck(let requestId, let tools)? = message else {
            return XCTFail("not parsed: \(String(describing: message))")
        }
        XCTAssertEqual(requestId, "r1")
        XCTAssertEqual(tools, ["remove_device"])
    }
}
