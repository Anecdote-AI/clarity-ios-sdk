import XCTest
@testable import ClaritySDK

/// In-app tools on the bridge. The Android port (`InAppToolsTest.kt`) asserts
/// the same messages, and the page side is `nativeSdkBridge.ts`.
final class InAppToolsTests: XCTestCase {

    func testACallDecodesWithSortedArguments() {
        XCTAssertEqual(
            BridgeMessage.parse(
                #"{"action":"inAppToolCall","callId":"c1","name":"remove_device","kind":"action","arguments":{"z":1,"device_id":"tv-1"},"timeoutMs":60000}"#
            ),
            .inAppToolCall(
                callId: "c1",
                name: "remove_device",
                kind: .action,
                argumentsJSON: #"{"device_id":"tv-1","z":1}"#,
                timeoutMs: 60000
            )
        )
    }

    /// A page that does not say how it treated the call (or says something
    /// this SDK does not know) claims the least: a read.
    func testACallWithoutArgumentsTimeoutOrKindGetsDefaults() {
        XCTAssertEqual(
            BridgeMessage.parse(#"{"action":"inAppToolCall","callId":"c1","name":"get_plan"}"#),
            .inAppToolCall(
                callId: "c1", name: "get_plan", kind: .read, argumentsJSON: "{}",
                timeoutMs: BridgeMessage.defaultInAppTimeoutMs
            )
        )
    }

    func testTheKindIsReadFromThePage() {
        let kinds = ["read": ClarityToolKind.read, "safe_action": .safeAction, "action": .action, "ACTION": .read, "approve": .read]
        for (raw, expected) in kinds {
            let message = BridgeMessage.parse(#"{"action":"inAppToolCall","callId":"c1","name":"get_plan","kind":"\#(raw)"}"#)
            guard case .inAppToolCall(_, _, let kind, _, _, _)? = message else {
                return XCTFail("not parsed: \(String(describing: message))")
            }
            XCTAssertEqual(kind, expected, raw)
        }
        let numeric = BridgeMessage.parse(#"{"action":"inAppToolCall","callId":"c1","name":"get_plan","kind":2}"#)
        guard case .inAppToolCall(_, _, .read, _, _, _)? = numeric else {
            return XCTFail("a kind that is not a string must read as a read: \(String(describing: numeric))")
        }
    }

    func testACallWithoutACallIdIsDropped() {
        XCTAssertNil(BridgeMessage.parse(#"{"action":"inAppToolCall","name":"get_plan"}"#))
    }

    /// The names in the declarations the registry announces to the page.
    private func declaredNames(_ registry: InAppToolRegistry) -> [String] {
        let message = JSONEncoding.object(from: registry.registeredMessage()) ?? [:]
        return (message["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    private func tool(
        _ name: String,
        description: String = "Does a thing",
        kind: ClarityToolKind = .action,
        parameters: [String: Any] = ["type": "object", "properties": [String: Any]()]
    ) -> ClarityTool {
        ClarityTool(name: name, description: description, kind: kind, parameters: parameters) { _, _ in }
    }

    func testTheRegistryAnnouncesTheDeclarations() {
        let registry = InAppToolRegistry()

        XCTAssertTrue(registry.register(ClarityTool(
            name: "get_plan",
            description: "Gets the plan",
            kind: .read,
            resultSchema: ["type": "object"],
            timeoutSeconds: 10
        ) { _, _ in }))
        XCTAssertTrue(registry.register(tool("list_devices", description: "Lists devices", kind: .read)))

        XCTAssertEqual(
            registry.registeredMessage(),
            #"{"action":"inAppToolsRegistered","collapseCallOnAllow":[],"securityCheck":[],"tools":[{"description":"Gets the plan","inputSchema":{"properties":{},"type":"object"},"kind":"read","name":"get_plan","resultSchema":{"type":"object"},"timeoutSeconds":10},{"description":"Lists devices","inputSchema":{"properties":{},"type":"object"},"kind":"read","name":"list_devices"}]}"#
        )
        XCTAssertTrue(registry.unregister("get_plan"))
        XCTAssertFalse(registry.unregister("get_plan"))
        XCTAssertEqual(declaredNames(registry), ["list_devices"])
    }

    // Regression (ACX-2094): the declarations were sorted by name (and kept
    // in a Dictionary, which has no order), which put the tools the app
    // listed first at the end, and the agent stopped using them (1 of 12
    // turns right on a replayed production turn, against 10 of 12 in the
    // declared order).
    func testTheDeclarationsKeepTheRegistrationOrder() {
        let registry = InAppToolRegistry()

        for name in ["show_on_page", "read_page", "list_devices", "get_plan", "a_last_one"] {
            XCTAssertTrue(registry.register(tool(name)))
        }

        XCTAssertEqual(declaredNames(registry), ["show_on_page", "read_page", "list_devices", "get_plan", "a_last_one"])
    }

    func testRegisteringANameAgainKeepsItsPlace() {
        let registry = InAppToolRegistry()
        registry.register(tool("list_devices"))
        registry.register(tool("get_plan", description: "Old"))
        registry.register(tool("open_screen"))

        registry.register(tool("get_plan", description: "New"))

        XCTAssertEqual(declaredNames(registry), ["list_devices", "get_plan", "open_screen"])
        let message = JSONEncoding.object(from: registry.registeredMessage()) ?? [:]
        let tools = message["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(tools.count == 3 ? tools[1]["description"] as? String : nil, "New")
    }

    func testAToolPastTheBackendsCapIsLeftOutWithAWarning() {
        var warnings: [String] = []
        let registry = InAppToolRegistry(log: { warnings.append($0) })
        let names = (1...InAppToolRegistry.maxDeclaredTools + 1).map { "tool_\($0)" }
        names.forEach { registry.register(tool($0, kind: .read)) }

        // The backend refuses a longer list as a whole: the first 32 go, the 33rd stays out.
        XCTAssertEqual(InAppToolRegistry.maxDeclaredTools, 32)
        XCTAssertEqual(declaredNames(registry), Array(names.prefix(32)))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasSuffix("left out: tool_33") == true, warnings.first ?? "")

        // Said once, not on every announcement.
        _ = declaredNames(registry)
        XCTAssertEqual(warnings.count, 1)

        // The 33rd is still registered: it is offered once another one goes.
        registry.unregister("tool_1")
        XCTAssertEqual(declaredNames(registry), Array(names.dropFirst()))
        XCTAssertEqual(warnings.count, 1)
    }

    func testASafeActionIsDeclaredAsSuch() {
        let registry = InAppToolRegistry()

        registry.register(ClarityTool(name: "open_devices", description: "Opens the devices screen", kind: .safeAction) { _, _ in })

        XCTAssertTrue(registry.registeredMessage().contains(#""kind":"safe_action""#))
    }

    func testAToolIsAnActionUnlessSaidOtherwise() {
        let registry = InAppToolRegistry()

        registry.register(ClarityTool(name: "remove_device", description: "Removes a device") { _, _ in })

        XCTAssertTrue(registry.registeredMessage().contains(#""kind":"action""#))
    }

    func testTheRegistryRefusesWhatCouldNeverBeDeclared() {
        let registry = InAppToolRegistry()

        XCTAssertFalse(registry.register(tool("List-Devices")))
        XCTAssertFalse(registry.register(tool("list_devices", description: "  ")))
        XCTAssertFalse(registry.register(tool("list_devices", description: String(repeating: "x", count: 1001))))
        XCTAssertFalse(registry.register(tool("list_devices", parameters: ["at": Date()])))
        XCTAssertEqual(declaredNames(registry), [])
    }

    func testRegisteringANameAgainReplacesTheTool() {
        let registry = InAppToolRegistry()

        registry.register(tool("get_plan", description: "Old"))
        registry.register(tool("get_plan", description: "New"))

        XCTAssertEqual(declaredNames(registry), ["get_plan"])
        XCTAssertTrue(registry.registeredMessage().contains(#""description":"New""#))
    }

    func testAResultIsEncoded() {
        XCTAssertEqual(
            InAppToolRegistry.doneMessage(callId: "c1", result: ["devices": [["id": "tv-1"]], "left": 3]),
            #"{"action":"inAppToolResult","callId":"c1","result":{"devices":[{"id":"tv-1"}],"left":3},"status":"done"}"#
        )
    }

    func testAResultThatIsNotJSONBecomesAnError() {
        XCTAssertEqual(
            InAppToolRegistry.doneMessage(callId: "c1", result: ["at": Date()]),
            #"{"action":"inAppToolResult","callId":"c1","error":"result_not_json","status":"error"}"#
        )
    }

    func testTheCompletionAnswersOnce() {
        var sent: [String] = []
        let completion = OnceCompletion(callId: "c1") { sent.append($0) }

        completion.complete(.success(["ok": true]))
        completion.complete(.failure("late"))
        completion.expire()

        XCTAssertEqual(sent, [#"{"action":"inAppToolResult","callId":"c1","result":{"ok":true},"status":"done"}"#])
    }

    func testAnUnansweredCallExpiresAsATimeout() {
        var sent: [String] = []
        let completion = OnceCompletion(callId: "c1") { sent.append($0) }

        completion.expire()
        completion.complete(.success(nil))

        XCTAssertEqual(sent, [#"{"action":"inAppToolResult","callId":"c1","error":"handler_timeout","status":"error"}"#])
    }

    // MARK: - Validation mirrors the backend (regression: these registered fine and the backend refused them unseen)

    private func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties]
    }

    func testABackendRefusalIsRefusedAtRegistration() {
        let refused: [ClarityTool] = [
            tool("remove_device", parameters: object(["deviceId": ["type": "string"]])),
            ClarityTool(name: "get_plan", description: "Gets the plan", timeoutSeconds: 120) { _, _ in },
            tool("get_plan", parameters: object(["amount": ["type": "number", "minimum": 0]])),
            tool("remove_device", parameters: object(["confirmation_text": ["type": "string"]])),
            tool("get_plan", parameters: object(["plan": ["type": "string", "description": String(repeating: "d", count: 301)]])),
            tool("get_plan", parameters: object(["plan": ["type": "string", "enum": [String(repeating: "v", count: 101)]]])),
        ]
        refused.forEach { XCTAssertNotNil(InAppToolRegistry.problem(with: $0), "\($0.parameters)") }
    }

    func testTheDescriptionIsCountedInCodePointsLikeTheBackend() {
        // 700 Arabic letters, each with a harakah: 700 graphemes, 1400 code points.
        let arabic = String(repeating: "\u{0628}\u{064E}", count: 700)
        XCTAssertEqual(arabic.count, 700)
        XCTAssertNotNil(InAppToolRegistry.problem(with: tool("get_plan", description: arabic)))

        // 990 letters and 6 emoji: 996 code points, 1002 UTF-16 units — the backend accepts it.
        let emoji = String(repeating: "x", count: 990) + String(repeating: "😀", count: 6)
        XCTAssertNil(InAppToolRegistry.problem(with: tool("get_plan", description: emoji)))
    }

    func testARefusalFromThePlatformIsReadFromThePage() {
        XCTAssertEqual(
            BridgeMessage.parse(#"{"action":"inAppToolsRejected","tools":[{"name":"get_plan","reason":"too long"}]}"#),
            .inAppToolsRejected([InAppToolRejection(name: "get_plan", reason: "too long")])
        )
    }

    // MARK: - Runner (the engine's part, regression: none of it was tested)

    private final class Harness {
        var sent: [String] = []
        var timers: [(Int, () -> Void)] = []
        var loaded = false
        lazy var runner = InAppToolRunner(
            registry: registry,
            send: { [unowned self] in self.sent.append($0) },
            after: { [unowned self] delay, block in self.timers.append((delay, block)) },
            isPageLoaded: { [unowned self] in self.loaded }
        )
        let registry = InAppToolRegistry()
    }

    func testANameWithoutAHandlerIsAnsweredUnavailable() {
        let harness = Harness()

        harness.runner.run(callId: "c1", name: "get_plan", kind: .action, arguments: [:], timeoutMs: 1000)

        XCTAssertEqual(harness.sent, [#"{"action":"inAppToolResult","callId":"c1","status":"unavailable"}"#])
    }

    func testAHandlerThatNeverAnswersTimesOut() {
        let harness = Harness()
        harness.registry.register(ClarityTool(name: "get_plan", description: "Gets the plan") { _, _ in })

        harness.runner.run(callId: "c1", name: "get_plan", kind: .action, arguments: [:], timeoutMs: 500)
        XCTAssertEqual(harness.timers.map(\.0), [500])
        harness.timers[0].1()

        XCTAssertEqual(harness.sent, [#"{"action":"inAppToolResult","callId":"c1","error":"handler_timeout","status":"error"}"#])
    }

    func testTheHandlerGetsTheArgumentsAndAnswersOnce() {
        let harness = Harness()
        var received: [String: Any] = [:]
        harness.registry.register(ClarityTool(name: "get_plan", description: "Gets the plan") { args, completion in
            received = args
            completion(.success(["plan": "premium"]))
            completion(.failure("late"))
        })

        harness.runner.run(callId: "c1", name: "get_plan", kind: .action, arguments: ["id": "a"], timeoutMs: 500)
        harness.timers[0].1()

        XCTAssertEqual(received["id"] as? String, "a")
        XCTAssertEqual(harness.sent, [#"{"action":"inAppToolResult","callId":"c1","result":{"plan":"premium"},"status":"done"}"#])
    }

    func testTheLoadedPageHearsTheDeclarations() {
        let harness = Harness()
        harness.registry.register(tool("get_plan"))

        harness.runner.toolsDidChange()
        XCTAssertEqual(harness.sent, [], "nothing goes to a page that is not loaded")

        harness.runner.pageDidLoad()
        harness.loaded = true
        harness.runner.toolsDidChange()

        XCTAssertEqual(harness.sent.count, 2)
        XCTAssertTrue(harness.sent.allSatisfy { $0.contains(#""action":"inAppToolsRegistered""#) && $0.contains(#""name":"get_plan""#) })
    }
}

