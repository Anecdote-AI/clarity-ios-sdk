import XCTest
@testable import ClaritySDK

/// Registry semantics with templates (spec 3.5): order, override, cap,
/// `rememberResult`, and the runner's handling of a remembered tool.
final class TemplateRegistryTests: XCTestCase {

    private func tool(
        _ name: String,
        kind: ClarityToolKind = .read,
        parameters: [String: Any] = ["type": "object", "properties": [String: Any]()],
        rememberResult: Bool = false,
        description: String = "Does a thing",
        handler: @escaping ClarityToolHandler = { _, _ in }
    ) -> ClarityTool {
        ClarityTool(
            name: name, description: description, kind: kind, parameters: parameters,
            rememberResult: rememberResult, handler: handler
        )
    }

    private func declared(_ registry: InAppToolRegistry) -> [[String: Any]] {
        let message = JSONEncoding.object(from: registry.registeredMessage()) ?? [:]
        return message["tools"] as? [[String: Any]] ?? []
    }

    private func names(_ registry: InAppToolRegistry) -> [String] {
        declared(registry).compactMap { $0["name"] as? String }
    }

    func testHostToolsComeFirstThenTemplatesInCanonicalOrder() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.replaceNativeTemplates([tool("get_form"), tool("read_page"), tool("open_link"), tool("show_on_page")])
        registry.register(tool("zeta"))
        registry.register(tool("alpha"))

        XCTAssertEqual(names(registry), ["zeta", "alpha", "read_page", "show_on_page", "open_link", "get_form"])
    }

    func testAWrapperTemplateInterleavesByTheCanonicalOrderAndAnUnknownOneGoesLast() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.replaceNativeTemplates([tool("find_on_site"), tool("get_diagnostics")])
        registry.registerTemplate(tool("read_page"))
        registry.registerTemplate(tool("custom_template"))
        registry.registerTemplate(tool("get_form"))

        XCTAssertEqual(names(registry), ["read_page", "find_on_site", "get_form", "get_diagnostics", "custom_template"])
    }

    func testAHostToolWithATemplatesNameWinsWhicheverCameFirst() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.register(tool("read_page", description: "The host's own"))
        registry.replaceNativeTemplates([tool("read_page", description: "Template"), tool("get_form")])
        registry.register(tool("get_form", kind: .action, description: "The host's form"))

        let tools = declared(registry)
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["read_page", "get_form"])
        XCTAssertEqual(tools.compactMap { $0["description"] as? String }, ["The host's own", "The host's form"])
        XCTAssertEqual(registry.tool(named: "get_form")?.kind, .action)
        XCTAssertFalse(registry.isTemplate("get_form"))
    }

    func testUnregisteringTheHostToolOffersTheTemplateAgain() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.replaceNativeTemplates([tool("read_page", description: "Template")])
        registry.register(tool("read_page", description: "Host"))
        registry.unregister("read_page")

        XCTAssertEqual(declared(registry).first?["description"] as? String, "Template")
        XCTAssertTrue(registry.isTemplate("read_page"))
    }

    func testReplacingTheTemplatesTurnsOffAGroupLeftOut() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.replaceNativeTemplates([tool("read_page"), tool("get_form")])
        registry.replaceNativeTemplates([tool("read_page")])

        XCTAssertEqual(names(registry), ["read_page"])
        XCTAssertNil(registry.tool(named: "get_form"))
    }

    func testTheCapLeavesOutTemplatesFirstAndNamesThem() {
        var logged: [String] = []
        let registry = InAppToolRegistry(log: { logged.append($0) })
        (1...30).forEach { registry.register(tool("host_\($0)")) }
        registry.replaceNativeTemplates(TemplateCatalog.order.prefix(4).map { tool($0) })

        let offered = names(registry)
        XCTAssertEqual(offered.count, 32)
        XCTAssertEqual(Array(offered.suffix(2)), ["read_page", "show_on_page"])
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("get_page_text, find_on_site"), logged[0])
    }

    // MARK: - rememberResult

    func testARememberedActionIsOfferedAsAReadWithTheNote() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.register(tool("get_location", kind: .action, rememberResult: true, description: String(repeating: "x", count: 1000)))

        XCTAssertEqual(declared(registry).first?["kind"] as? String, "action")
        XCTAssertTrue(registry.remember("get_location", result: ["lat": 44.79]))

        let declaration = declared(registry).first ?? [:]
        let description = declaration["description"] as? String ?? ""
        XCTAssertEqual(declaration["kind"] as? String, "read")
        XCTAssertTrue(description.hasSuffix(InAppToolRegistry.rememberedNote))
        XCTAssertEqual(description.unicodeScalars.count, 1000)
    }

    func testOnlyAnActionWithoutArgumentsIsRemembered() {
        var logged: [String] = []
        let registry = InAppToolRegistry(log: { logged.append($0) })
        registry.register(tool("a_read", kind: .read, rememberResult: true))
        registry.register(tool(
            "with_args", kind: .action,
            parameters: ["type": "object", "properties": ["id": ["type": "string"]]],
            rememberResult: true
        ))

        XCTAssertFalse(registry.remember("a_read", result: 1))
        XCTAssertFalse(registry.remember("with_args", result: 1))
        XCTAssertEqual(logged.count, 2)
        XCTAssertTrue(declared(registry).allSatisfy { ($0["description"] as? String) == "Does a thing" })
    }

    func testARememberedAnswerExpiresAfterItsTimeAndOnForget() {
        var now: TimeInterval = 0
        let registry = InAppToolRegistry(log: { _ in }, now: { now })
        var location = tool("get_location", kind: .action, rememberResult: true)
        location.rememberFor = 30 * 60
        registry.replaceNativeTemplates([location])
        registry.register(tool("host_action", kind: .action, rememberResult: true))
        registry.remember("get_location", result: ["lat": 1])
        registry.remember("host_action", result: "ok")

        now += 29 * 60
        XCTAssertNotNil(registry.rememberedResult(for: "get_location"))
        now += 2 * 60
        XCTAssertNil(registry.rememberedResult(for: "get_location"))
        // A host tool's answer has no expiry of its own.
        XCTAssertNotNil(registry.rememberedResult(for: "host_action"))

        XCTAssertTrue(registry.forgetRemembered())
        XCTAssertNil(registry.rememberedResult(for: "host_action"))
        XCTAssertFalse(registry.forgetRemembered())
    }

    /// A remembered answer would skip the security check for the rest of
    /// the session, so a tool that requires the check is never remembered:
    /// it keeps its card and its check every time.
    func testAToolThatRequiresTheSecurityCheckIsNeverRemembered() {
        var logged: [String] = []
        let registry = InAppToolRegistry(log: { logged.append($0) })
        let checked = ClarityTool(
            name: "show_balance", description: "Shows it", kind: .action,
            requiresSecurityCheck: true, collapseCallOnAllow: true, rememberResult: true
        ) { _, _ in }
        registry.register(checked)

        XCTAssertFalse(InAppToolRegistry.remembers(checked))
        XCTAssertTrue(logged.contains { $0.contains("\"show_balance\"") && $0.contains("requiresSecurityCheck") })
        XCTAssertFalse(registry.remember("show_balance", result: "12,345.67"))
        XCTAssertNil(registry.rememberedResult(for: "show_balance"))

        let message = JSONEncoding.object(from: registry.registeredMessage()) ?? [:]
        XCTAssertEqual(declared(registry).first?["kind"] as? String, "action")
        XCTAssertEqual(message["securityCheck"] as? [String], ["show_balance"])
        XCTAssertEqual(message["collapseCallOnAllow"] as? [String], ["show_balance"])
    }

    /// A remembered tool without the check is answered without a card, so it
    /// has nothing to allow.
    func testARememberedToolHasNoCollapse() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.register(ClarityTool(
            name: "share_location", description: "Shares it", kind: .action,
            collapseCallOnAllow: true, rememberResult: true
        ) { _, _ in })
        registry.remember("share_location", result: "here")

        let message = JSONEncoding.object(from: registry.registeredMessage()) ?? [:]
        XCTAssertEqual(declared(registry).first?["kind"] as? String, "read")
        XCTAssertEqual(message["securityCheck"] as? [String], [])
        XCTAssertEqual(message["collapseCallOnAllow"] as? [String], [])
    }

    // MARK: - The runner

    func testTheRunnerRemembersASuccessAndAnswersLaterCallsWithoutTheHandler() throws {
        let registry = InAppToolRegistry(log: { _ in })
        var runs = 0
        registry.register(tool("get_location", kind: .action, rememberResult: true) { _, completion in
            runs += 1
            completion(.success(["lat": 44.79, "lon": 20.45]))
        })
        var sent: [String] = []
        let runner = InAppToolRunner(
            registry: registry, send: { sent.append($0) }, after: { ms, block in if ms == 0 { block() } },
            isPageLoaded: { true }
        )

        runner.run(callId: "c1", name: "get_location", kind: .action, arguments: [:], timeoutMs: 1000)
        // Declared as a read now, so the page calls it as one: answered
        // before the native kind floor, never refused as kind_mismatch.
        runner.run(callId: "c2", name: "get_location", kind: .read, arguments: [:], timeoutMs: 1000)

        XCTAssertEqual(runs, 1)
        let answers = sent.compactMap(JSONEncoding.object(from:)).filter { $0["action"] as? String == "inAppToolResult" }
        XCTAssertEqual(answers.map { $0["callId"] as? String }, ["c1", "c2"])
        XCTAssertEqual(answers.map { $0["status"] as? String }, ["done", "done"])
        XCTAssertEqual((answers[1]["result"] as? [String: Any])?["lat"] as? Double, 44.79)
        // The page heard the tool turn into a read right after the first answer.
        let announcement = try XCTUnwrap(sent.compactMap(JSONEncoding.object(from:)).first {
            $0["action"] as? String == "inAppToolsRegistered"
        })
        XCTAssertEqual((announcement["tools"] as? [[String: Any]])?.first?["kind"] as? String, "read")

        runner.forgetRemembered()
        // Forgotten: a read call is below the action again.
        runner.run(callId: "c3", name: "get_location", kind: .read, arguments: [:], timeoutMs: 1000)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(JSONEncoding.object(from: sent.last ?? "")?["error"] as? String, InAppCallGate.errorKindMismatch)
        runner.run(callId: "c4", name: "get_location", kind: .action, arguments: [:], timeoutMs: 1000)
        XCTAssertEqual(runs, 2)
    }

    /// When a remembered answer expires, the page hears the tool as an
    /// action again; it kept calling it as a read, which the kind floor
    /// refuses, until something else re-announced the tools.
    func testThePageHearsTheActionAgainWhenTheAnswerExpires() throws {
        var now: TimeInterval = 100
        let registry = InAppToolRegistry(log: { _ in }, now: { now })
        var location = tool("get_location", kind: .action, rememberResult: true) { _, completion in
            completion(.success(["lat": 1]))
        }
        location.rememberFor = 30 * 60
        registry.replaceNativeTemplates([location])
        var sent: [String] = []
        var timers: [(Int, () -> Void)] = []
        let runner = InAppToolRunner(
            registry: registry, send: { sent.append($0) },
            after: { ms, block in if ms == 0 { block() } else { timers.append((ms, block)) } },
            isPageLoaded: { true }
        )
        func announcedKind() -> String? {
            let last = sent.compactMap(JSONEncoding.object(from:)).last { $0["action"] as? String == "inAppToolsRegistered" }
            return (last?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "get_location" }?["kind"] as? String
        }

        runner.run(callId: "c1", name: "get_location", kind: .action, arguments: [:], timeoutMs: 1000)
        XCTAssertEqual(announcedKind(), "read")
        let expiry = try XCTUnwrap(timers.first { $0.0 == 30 * 60 * 1000 }, "a timer for the answer's expiry")

        now += 30 * 60
        expiry.1()

        XCTAssertEqual(announcedKind(), "action")
    }

    /// The backstop: a read call for a remembered tool whose answer is gone
    /// re-announces the tools before it is refused.
    func testAReadCallAfterTheAnswerExpiredReannouncesTheAction() {
        var now: TimeInterval = 100
        let registry = InAppToolRegistry(log: { _ in }, now: { now })
        var location = tool("get_location", kind: .action, rememberResult: true) { _, completion in
            completion(.success(["lat": 1]))
        }
        location.rememberFor = 60
        registry.replaceNativeTemplates([location])
        var sent: [String] = []
        let runner = InAppToolRunner(
            registry: registry, send: { sent.append($0) }, after: { ms, block in if ms == 0 { block() } },
            isPageLoaded: { true }
        )
        runner.run(callId: "c1", name: "get_location", kind: .action, arguments: [:], timeoutMs: 1000)
        now += 61
        sent.removeAll()

        runner.run(callId: "c2", name: "get_location", kind: .read, arguments: [:], timeoutMs: 1000)

        let messages = sent.compactMap(JSONEncoding.object(from:))
        XCTAssertEqual(messages.map { $0["action"] as? String }, ["inAppToolsRegistered", "inAppToolResult"])
        let tools = messages.first?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first { $0["name"] as? String == "get_location" }?["kind"] as? String, "action")
        XCTAssertEqual(messages.last?["error"] as? String, InAppCallGate.errorKindMismatch)
    }

    /// An answer that arrives after a logout or a user switch is not kept:
    /// the next session would get it without a card.
    func testAnAnswerAfterForgetIsNotRemembered() {
        let registry = InAppToolRegistry(log: { _ in })
        var answer: ClarityToolCompletion?
        registry.register(tool("get_balance", kind: .action, rememberResult: true) { _, completion in
            answer = completion
        })
        var sent: [String] = []
        let runner = InAppToolRunner(
            registry: registry, send: { sent.append($0) }, after: { ms, block in if ms == 0 { block() } },
            isPageLoaded: { true }
        )

        runner.run(callId: "c1", name: "get_balance", kind: .action, arguments: [:], timeoutMs: 1000)
        runner.forgetRemembered()
        answer?(.success("€12,345.67"))

        XCTAssertNil(registry.rememberedResult(for: "get_balance"))
        XCTAssertFalse(sent.contains { $0.contains("inAppToolsRegistered") }, "never re-announced as a read")
    }

    /// `updateConfig` to another org, channel, stand or app forgets the
    /// remembered answers (WidgetEngine); presentation changes keep them.
    func testAnotherOrgOrChannelIsAnotherConversation() {
        let base = ClarityConfig(organizationId: "1", integrationKey: "k", baseUrl: "https://chat.example.com")
        var other = base
        other.organizationId = "2"
        XCTAssertTrue(base.isAnotherConversation(than: other))
        other = base
        other.integrationKey = "k2"
        XCTAssertTrue(base.isAnotherConversation(than: other))
        other = base
        other.baseUrl = "https://stage.example.com"
        XCTAssertTrue(base.isAnotherConversation(than: other))
        other = base
        other.appId = "com.example.other"
        XCTAssertTrue(base.isAnotherConversation(than: other))
        other = base
        other.language = "de"
        other.presentationMode = .fullScreen
        XCTAssertFalse(base.isAnotherConversation(than: other))
    }

    func testAFailureIsNotRemembered() {
        let registry = InAppToolRegistry(log: { _ in })
        var runs = 0
        registry.register(tool("get_location", kind: .action, rememberResult: true) { _, completion in
            runs += 1
            completion(.failure("the customer did not allow the location on the device"))
        })
        let runner = InAppToolRunner(registry: registry, send: { _ in }, after: { _, _ in }, isPageLoaded: { true })

        runner.run(callId: "c1", name: "get_location", kind: .action, arguments: [:], timeoutMs: 1000)
        runner.run(callId: "c2", name: "get_location", kind: .action, arguments: [:], timeoutMs: 1000)

        XCTAssertEqual(runs, 2)
        XCTAssertNil(registry.rememberedResult(for: "get_location"))
    }

    func testWillRunSeesEveryHandlerRunButNotARememberedAnswer() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.register(tool("get_location", kind: .action, rememberResult: true) { _, completion in
            completion(.success("here"))
        })
        registry.replaceNativeTemplates([tool("read_page") { _, completion in completion(.success([:])) }])
        let runner = InAppToolRunner(registry: registry, send: { _ in }, after: { _, _ in }, isPageLoaded: { true })
        var seen: [String] = []
        runner.willRun = { seen.append($0.name) }

        runner.run(callId: "c1", name: "get_location", kind: .action, arguments: [:], timeoutMs: 1000)
        runner.run(callId: "c2", name: "get_location", kind: .read, arguments: [:], timeoutMs: 1000)
        runner.run(callId: "c3", name: "read_page", kind: .read, arguments: [:], timeoutMs: 1000)

        XCTAssertEqual(seen, ["get_location", "read_page"])
    }

    func testATemplatesKindIsTheFloorLikeAnyTool() {
        let registry = InAppToolRegistry(log: { _ in })
        var runs = 0
        registry.replaceNativeTemplates([tool("get_page_text", kind: .action) { _, completion in
            runs += 1
            completion(.success([:]))
        }])
        var sent: [String] = []
        let runner = InAppToolRunner(registry: registry, send: { sent.append($0) }, after: { _, _ in }, isPageLoaded: { true }, log: { _ in })

        runner.run(callId: "c1", name: "get_page_text", kind: .read, arguments: [:], timeoutMs: 1000)

        XCTAssertEqual(runs, 0)
        XCTAssertEqual(JSONEncoding.object(from: sent.last ?? "")?["error"] as? String, InAppCallGate.errorKindMismatch)
    }

    func testATemplateCallRunsItsHandler() {
        let registry = InAppToolRegistry(log: { _ in })
        registry.replaceNativeTemplates([tool("read_page") { _, completion in completion(.success(["path": "/x"])) }])
        var sent: [String] = []
        let runner = InAppToolRunner(registry: registry, send: { sent.append($0) }, after: { _, _ in }, isPageLoaded: { true })

        runner.run(callId: "c1", name: "read_page", kind: .read, arguments: [:], timeoutMs: 1000)

        let answer = JSONEncoding.object(from: sent.last ?? "") ?? [:]
        XCTAssertEqual(answer["status"] as? String, "done")
        XCTAssertEqual((answer["result"] as? [String: Any])?["path"] as? String, "/x")
    }
}
