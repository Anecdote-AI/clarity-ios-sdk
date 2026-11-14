import XCTest
@testable import ClaritySDK

/// What the SDK checks itself before an in-app tool's handler runs, instead
/// of trusting the page: the kind the page treated the call as, and a pass
/// from a security check this SDK ran (`InAppCallGate`).
final class InAppCallGateTests: XCTestCase {

    private final class Harness {
        var sent: [String] = []
        var timers: [(Int, () -> Void)] = []
        var ran: [String] = []
        var logged: [String] = []
        /// Seconds on the gate's monotonic clock.
        var clock: TimeInterval = 1_000_000
        let registry = InAppToolRegistry()
        lazy var gate = InAppCallGate(now: { [unowned self] in self.clock })
        lazy var runner = InAppToolRunner(
            registry: registry,
            send: { [unowned self] in self.sent.append($0) },
            after: { [unowned self] delay, block in self.timers.append((delay, block)) },
            isPageLoaded: { true },
            gate: gate,
            log: { [unowned self] in self.logged.append($0) }
        )

        @discardableResult
        func register(_ name: String, kind: ClarityToolKind, requiresSecurityCheck: Bool = false) -> Bool {
            registry.register(ClarityTool(
                name: name,
                description: "Does \(name)",
                kind: kind,
                requiresSecurityCheck: requiresSecurityCheck
            ) { [unowned self] _, completion in
                self.ran.append(name)
                completion(.success(nil))
            })
        }

        func call(_ callId: String, _ name: String, kind: ClarityToolKind = .action) {
            runner.run(callId: callId, name: name, kind: kind, arguments: ["device_id": "tv-1"], timeoutMs: 30_000)
        }

        /// The customer allowed a card and the app's check answered `passed`.
        func check(tools: [String], callIds: [String]?, passed: Bool = true) {
            registry.securityCheck = { _, done in done(passed) }
            runner.securityCheck(requestId: "r1", tools: tools, callIds: callIds)
        }
    }

    private func refused(_ callId: String, _ reason: String) -> String {
        #"{"action":"inAppToolResult","callId":"\#(callId)","error":"\#(reason)","status":"error"}"#
    }

    private func done(_ callId: String) -> String {
        #"{"action":"inAppToolResult","callId":"\#(callId)","result":null,"status":"done"}"#
    }

    // MARK: - Kind floor

    func testTheKindRanks() {
        XCTAssertLessThan(ClarityToolKind.read.rank, ClarityToolKind.safeAction.rank)
        XCTAssertLessThan(ClarityToolKind.safeAction.rank, ClarityToolKind.action.rank)
    }

    /// Every registered kind against every kind the page can claim, a call
    /// that says nothing included: the handler runs only when the call was
    /// treated as at least the registered kind.
    func testACallTreatedAsLessThanItsToolIsRefused() {
        let claims: [(label: String, kind: ClarityToolKind)] = [
            ("missing", .fromPage(nil)),
            ("unknown", .fromPage("approved")),
            ("read", .read),
            ("safe_action", .safeAction),
            ("action", .action),
        ]
        for registered in [ClarityToolKind.read, .safeAction, .action] {
            for claim in claims {
                let harness = Harness()
                harness.register("the_tool", kind: registered)

                harness.call("c1", "the_tool", kind: claim.kind)

                let allowed = claim.kind.rank >= registered.rank
                let label = "registered \(registered.rawValue), page said \(claim.label)"
                XCTAssertEqual(harness.ran, allowed ? ["the_tool"] : [], label)
                XCTAssertEqual(harness.sent, [allowed ? done("c1") : refused("c1", "kind_mismatch")], label)
                XCTAssertTrue(allowed || harness.timers.isEmpty, "a refused call sets no timeout — \(label)")
            }
        }
    }

    /// The finding's shape: a call straight from the bridge, with no `kind`,
    /// for an action — no card was ever shown.
    func testAnActionCalledWithoutAKindNeverRuns() {
        let harness = Harness()
        harness.register("remove_device", kind: .action)
        let message = BridgeMessage.parse(
            #"{"action":"inAppToolCall","callId":"c1","name":"remove_device","arguments":{"device_id":"tv-1"}}"#
        )
        guard case .inAppToolCall(let callId, let name, let kind, _, let timeoutMs, _)? = message else {
            return XCTFail("not parsed")
        }

        harness.runner.run(callId: callId, name: name, kind: kind, arguments: [:], timeoutMs: timeoutMs)

        XCTAssertEqual(harness.ran, [])
        XCTAssertEqual(harness.sent, [refused("c1", "kind_mismatch")])
    }

    func testARefusalLogsNamesOnly() {
        let harness = Harness()
        harness.register("remove_device", kind: .action)

        harness.call("c1", "remove_device", kind: .read)

        XCTAssertEqual(harness.logged, ["in-app tool remove_device (c1) refused: kind_mismatch"])
        XCTAssertFalse(harness.logged.joined().contains("tv-1"), "arguments never reach the log")
    }

    // MARK: - Security check bound natively

    func testAToolThatNeedsTheCheckDoesNotRunWithoutAPass() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)

        harness.call("c1", "remove_device")

        XCTAssertEqual(harness.ran, [])
        XCTAssertEqual(harness.sent, [refused("c1", "security_check_required")])
    }

    /// `rememberResult` on a tool that requires the check is ignored: the
    /// second call needs its own pass instead of the first call's answer.
    func testARememberResultToolThatNeedsTheCheckAsksEveryTime() {
        let harness = Harness()
        harness.registry.register(ClarityTool(
            name: "show_balance", description: "Shows it", kind: .action,
            requiresSecurityCheck: true, rememberResult: true
        ) { [unowned harness] _, completion in
            harness.ran.append("show_balance")
            completion(.success(nil))
        })
        harness.check(tools: ["show_balance"], callIds: ["c1"])
        harness.sent.removeAll()

        harness.call("c1", "show_balance")
        harness.call("c2", "show_balance")
        harness.call("c3", "show_balance", kind: .read)

        XCTAssertEqual(harness.ran, ["show_balance"])
        XCTAssertEqual(harness.sent, [
            done("c1"),
            refused("c2", "security_check_required"),
            refused("c3", "kind_mismatch"),
        ])
    }

    func testAPassedCheckCoversEachStepOnce() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device", "remove_device"], callIds: ["c1", "c2"])
        harness.sent.removeAll()

        harness.call("c1", "remove_device")
        harness.call("c2", "remove_device")
        harness.call("c1", "remove_device")

        XCTAssertEqual(harness.ran, ["remove_device", "remove_device"])
        XCTAssertEqual(harness.sent, [done("c1"), done("c2"), refused("c1", "security_check_required")])
    }

    func testAPassIsBoundToItsCallIdAndTool() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.register("transfer_money", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device"], callIds: ["c1"])
        harness.sent.removeAll()

        harness.call("c9", "remove_device")
        harness.call("c1", "transfer_money")
        harness.call("c1", "remove_device")

        XCTAssertEqual(harness.ran, ["remove_device"])
        XCTAssertEqual(harness.sent, [
            refused("c9", "security_check_required"),
            refused("c1", "security_check_required"),
            done("c1"),
        ])
    }

    func testAPassExpiresTenMinutesAfterTheCheck() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device", "remove_device"], callIds: ["c1", "c2"])
        harness.sent.removeAll()

        harness.clock += 10 * 60 - 1
        harness.call("c1", "remove_device")
        harness.clock += 1
        harness.call("c2", "remove_device")

        XCTAssertEqual(harness.ran, ["remove_device"])
        XCTAssertEqual(harness.sent, [done("c1"), refused("c2", "security_check_required")])
    }

    /// `callIds: []` is not an older page: the card has steps the ids do not
    /// cover, so nothing is recorded — not even per-name counts.
    func testAnEmptyCallIdListRecordsNothing() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device", "remove_device"], callIds: [])
        harness.sent.removeAll()

        harness.call("c1", "remove_device")
        harness.call("c2", "remove_device")

        XCTAssertEqual(harness.ran, [])
        XCTAssertEqual(harness.sent, [
            refused("c1", "security_check_required"),
            refused("c2", "security_check_required"),
        ])
        XCTAssertTrue(harness.logged.contains(
            "The security check passed, but the card's call ids do not match its steps: no step may run"
        ))
    }

    /// Call ids that do not pair up with the steps one to one — too few, too
    /// many, or one empty — record nothing for any step, the ones that do
    /// pair up included.
    func testMisalignedCallIdsRecordNothing() {
        let cases: [(label: String, tools: [String], callIds: [String])] = [
            ("fewer ids than steps", ["remove_device", "remove_device"], ["c1"]),
            ("more ids than steps", ["remove_device"], ["c1", "c2"]),
            ("an empty id", ["remove_device", "remove_device"], ["c1", ""]),
        ]
        for testCase in cases {
            let harness = Harness()
            harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
            harness.check(tools: testCase.tools, callIds: testCase.callIds)
            harness.sent.removeAll()

            harness.call("c1", "remove_device")
            harness.call("c2", "remove_device")

            XCTAssertEqual(harness.ran, [], testCase.label)
            XCTAssertEqual(harness.sent, [
                refused("c1", "security_check_required"),
                refused("c2", "security_check_required"),
            ], testCase.label)
        }
    }

    /// Only a step whose tool needs the check gets a pass; the others run
    /// without one anyway.
    func testOnlyStepsThatNeedTheCheckGetAPass() {
        let gate = InAppCallGate(now: { 0 })
        gate.recordPass(tools: ["rename_device", "remove_device"], callIds: ["c1", "c2"]) { $0 == "remove_device" }

        XCTAssertFalse(gate.consumePass(callId: "c1", name: "rename_device"))
        XCTAssertTrue(gate.consumePass(callId: "c2", name: "remove_device"))
    }

    /// A page that predates `callIds`: one pass per step, counted by name.
    func testWithoutCallIdsThePassesAreCountedByName() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.register("rename_device", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device", "remove_device"], callIds: nil)
        harness.sent.removeAll()

        harness.call("c1", "rename_device")
        harness.call("c1", "remove_device")
        harness.call("c2", "remove_device")
        harness.call("c3", "remove_device")

        XCTAssertEqual(harness.ran, ["remove_device", "remove_device"])
        XCTAssertEqual(harness.sent, [
            refused("c1", "security_check_required"),
            done("c1"),
            done("c2"),
            refused("c3", "security_check_required"),
        ])
    }

    func testACheckThatDidNotPassRecordsNothing() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device"], callIds: ["c1"], passed: false)
        harness.check(tools: ["remove_device"], callIds: nil, passed: false)
        harness.sent.removeAll()

        harness.call("c1", "remove_device")

        XCTAssertEqual(harness.ran, [])
        XCTAssertEqual(harness.sent, [refused("c1", "security_check_required")])
    }

    /// The page heard "not passed" when the cap ran out; the app's late yes
    /// must not leave a pass behind.
    func testALatePassAfterTheCapRecordsNothing() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        var late: ((Bool) -> Void)?
        harness.registry.securityCheck = { _, done in late = done }
        harness.runner.securityCheck(requestId: "r1", tools: ["remove_device"], callIds: ["c1"])
        harness.timers.removeFirst().1()
        late?(true)
        harness.sent.removeAll()

        harness.call("c1", "remove_device")

        XCTAssertEqual(harness.ran, [])
        XCTAssertEqual(harness.sent, [refused("c1", "security_check_required")])
    }

    func testAKindMismatchDoesNotUseUpThePass() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device"], callIds: ["c1"])
        harness.sent.removeAll()

        harness.call("c1", "remove_device", kind: .safeAction)
        harness.call("c1", "remove_device", kind: .action)

        XCTAssertEqual(harness.sent, [refused("c1", "kind_mismatch"), done("c1")])
    }

    func testAToolThatDoesNotNeedTheCheckRunsWithoutAPass() {
        let harness = Harness()
        harness.register("rename_device", kind: .action)

        harness.call("c1", "rename_device")

        XCTAssertEqual(harness.ran, ["rename_device"])
    }

    func testAResetForgetsThePasses() {
        let harness = Harness()
        harness.register("remove_device", kind: .action, requiresSecurityCheck: true)
        harness.check(tools: ["remove_device"], callIds: ["c1"])
        harness.check(tools: ["remove_device"], callIds: nil)
        harness.sent.removeAll()

        harness.runner.forgetSecurityPasses()
        harness.call("c1", "remove_device")

        XCTAssertEqual(harness.sent, [refused("c1", "security_check_required")])
    }
}
