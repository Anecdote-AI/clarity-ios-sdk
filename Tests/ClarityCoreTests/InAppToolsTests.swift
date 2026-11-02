import XCTest
@testable import ClaritySDK

/// In-app tools on the bridge. The Android port (`InAppToolsTest.kt`) asserts
/// the same messages, and the page side is `nativeSdkBridge.ts`.
final class InAppToolsTests: XCTestCase {

    func testACallDecodesWithSortedArguments() {
        XCTAssertEqual(
            BridgeMessage.parse(
                #"{"action":"inAppToolCall","callId":"c1","name":"remove_device","arguments":{"z":1,"device_id":"tv-1"},"timeoutMs":60000}"#
            ),
            .inAppToolCall(
                callId: "c1",
                name: "remove_device",
                argumentsJSON: #"{"device_id":"tv-1","z":1}"#,
                timeoutMs: 60000
            )
        )
    }

    func testACallWithoutArgumentsOrTimeoutGetsDefaults() {
        XCTAssertEqual(
            BridgeMessage.parse(#"{"action":"inAppToolCall","callId":"c1","name":"get_plan"}"#),
            .inAppToolCall(
                callId: "c1", name: "get_plan", argumentsJSON: "{}",
                timeoutMs: BridgeMessage.defaultInAppTimeoutMs
            )
        )
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

    func testTheRegistryAnnouncesSortedDeclarations() {
        let registry = InAppToolRegistry()

        XCTAssertTrue(registry.register(tool("list_devices", description: "Lists devices", kind: .read)))
        XCTAssertTrue(registry.register(ClarityTool(
            name: "get_plan",
            description: "Gets the plan",
            kind: .read,
            resultSchema: ["type": "object"],
            timeoutSeconds: 10
        ) { _, _ in }))

        XCTAssertEqual(
            registry.registeredMessage(),
            #"{"action":"inAppToolsRegistered","securityCheck":[],"tools":[{"description":"Gets the plan","inputSchema":{"properties":{},"type":"object"},"kind":"read","name":"get_plan","resultSchema":{"type":"object"},"timeoutSeconds":10},{"description":"Lists devices","inputSchema":{"properties":{},"type":"object"},"kind":"read","name":"list_devices"}]}"#
        )
        XCTAssertTrue(registry.unregister("get_plan"))
        XCTAssertFalse(registry.unregister("get_plan"))
        XCTAssertEqual(declaredNames(registry), ["list_devices"])
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

        harness.runner.run(callId: "c1", name: "get_plan", arguments: [:], timeoutMs: 1000)

        XCTAssertEqual(harness.sent, [#"{"action":"inAppToolResult","callId":"c1","status":"unavailable"}"#])
    }

    func testAHandlerThatNeverAnswersTimesOut() {
        let harness = Harness()
        harness.registry.register(ClarityTool(name: "get_plan", description: "Gets the plan") { _, _ in })

        harness.runner.run(callId: "c1", name: "get_plan", arguments: [:], timeoutMs: 500)
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

        harness.runner.run(callId: "c1", name: "get_plan", arguments: ["id": "a"], timeoutMs: 500)
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

