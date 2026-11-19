import XCTest
@testable import ClaritySDK

/// Approval modes of in-app actions on the app's side: what the
/// app declares (`label`, `approval`, `approvalModes`), the always-ask
/// lexicon, and the refusal of a call that came without a card when the
/// app's registration says it must ask. The Android port is `InAppApprovalTest.kt`.
final class InAppApprovalTests: XCTestCase {

    // MARK: - The lexicon: the same examples as the platform and the web chat

    private let lexiconCases: [(String, String?)] = [
        ("Pay now", "payment"),
        ("pay_bill", "payment"),
        ("Checkout", "payment"),
        ("Transfer money to Anna", "payment"),
        ("Place order", "payment"),
        ("Top-up", "payment"),
        ("Withdraw cash", "payment"),
        ("Refund my order", "payment"),
        ("Upgrade plan", "subscription"),
        ("Subscribe", "subscription"),
        ("ادفع الآن", "payment"),
        ("Оплатить", "payment"),
        ("Jetzt bezahlen", "payment"),
        ("Confirm 48.20 EUR", "payment"),
        ("Continue to pay €12", "payment"),
        ("Sort order", nil),
        ("Pin", nil),
        ("Share", nil),
        ("Delete", nil),
        ("Delete account", nil),
        ("Reset password", nil),
        ("Sign the contract", nil),
        ("Confirm", nil),
        ("Continue", nil),
        ("Confirm your new address", nil),
        ("Save profile", nil),
        ("remove_device", nil),
    ]

    func testTheLexiconReadsMoneyOnly() {
        for (text, category) in lexiconCases {
            XCTAssertEqual(InAppApproval.sensitiveCategory(of: [text]), category, text)
        }
    }

    func testAnAmountNeedsACurrencyStandingAlone() {
        XCTAssertTrue(InAppApproval.hasAmount(["48.20 EUR"]))
        XCTAssertTrue(InAppApproval.hasAmount(["$ 5"]))
        XCTAssertTrue(InAppApproval.hasAmount(["12 000 ₽"]))
        XCTAssertFalse(InAppApproval.hasAmount(["5 euros"]))
        XCTAssertFalse(InAppApproval.hasAmount(["focusd 5"]))
        XCTAssertFalse(InAppApproval.hasAmount(["Room 48"]))
    }

    func testALinkLeadsToMoneyByItsPathOrADeepLinksHost() {
        XCTAssertTrue(InAppApproval.isMoneyPath("https://shop.example.com/checkout/pay"))
        XCTAssertTrue(InAppApproval.isMoneyPath("/billing"))
        // A deep link's first segment is its host.
        XCTAssertTrue(InAppApproval.isMoneyPath("myapp://checkout"))
        XCTAssertTrue(InAppApproval.isMoneyPath("myapp://billing/42"))
        XCTAssertTrue(InAppApproval.isMoneyPath("myapp://orders/cart"))
        XCTAssertTrue(InAppApproval.isMoneyPath("MyApp://Checkout?step=2"))
        // Read although `URL` refuses it.
        XCTAssertTrue(InAppApproval.isMoneyPath("https://shop.example.com/my cart/checkout"))
        XCTAssertTrue(InAppApproval.isMoneyPath("https://shop.example.com/%63heckout"))
        // A web address's host is not where it leads; neither are the query and the fragment.
        XCTAssertFalse(InAppApproval.isMoneyPath("https://checkout.example.com/help"))
        XCTAssertFalse(InAppApproval.isMoneyPath("https://shop.example.com/help?next=checkout#billing"))
        XCTAssertFalse(InAppApproval.isMoneyPath("myapp://profile/42"))
        XCTAssertFalse(InAppApproval.isMoneyPath("myapp://"))
        XCTAssertFalse(InAppApproval.isMoneyPath(nil))
        XCTAssertFalse(InAppApproval.isMoneyPath(""))
    }

    func testTheClickIsJudgedByWhatItPresses() {
        func reason(_ target: String) -> String? {
            InAppApproval.alwaysAskReason(name: "click_element", label: "Press a button", sensitive: nil, arguments: ["target": target])
        }
        XCTAssertEqual(reason("Pay now"), "payment")
        XCTAssertEqual(reason("Delete my account"), "account_deletion")
        XCTAssertNil(reason("Save profile"))
        XCTAssertNil(reason("Sort order"))
        XCTAssertNil(reason("Pin"))
    }

    func testTheAppsCategoryWinsAndTheDescriptionIsNotRead() {
        XCTAssertEqual(InAppApproval.alwaysAskReason(name: "open_vault", label: nil, sensitive: "credentials", arguments: [:]), "credentials")
        XCTAssertNil(InAppApproval.alwaysAskReason(
            name: "add_to_cart", label: "Add to cart", sensitive: nil, arguments: ["description": "pay at checkout"]
        ))
    }

    /// The SDK's copy of the lexicon is the platform's, word for word, but for
    /// the platform's `_comment` keys, which the copy leaves out. Skipped where
    /// the platform's file is not in the checkout.
    func testTheCopyIsThePlatformsLexicon() throws {
        let apps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let platform = [
            apps.appendingPathComponent("back/app/ai/agents/in_app_approval_lexicon.json"),
            apps.appendingPathComponent("front/packages/shared/src/entities/liveChatPostMessage/inAppApprovalLexicon.json"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(platform.isEmpty, "the platform's lexicon is not in this checkout")
        let copy = try JSONSerialization.jsonObject(with: Data(InAppApprovalLexicon.json.utf8)) as? NSDictionary
        XCTAssertFalse(InAppApprovalLexicon.json.contains("_comment"), "the shipped copy carries no comments")
        for file in platform {
            let theirs = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            XCTAssertEqual(Self.withoutComments(theirs) as? NSDictionary, copy, file.path)
        }
    }

    private static func withoutComments(_ value: Any) -> Any {
        guard let object = value as? [String: Any] else { return value }
        return object.filter { $0.key != "_comment" }.mapValues(withoutComments)
    }

    // MARK: - What the app declares

    private func tool(
        _ name: String,
        label: String? = nil,
        approval: ClarityToolApproval? = nil,
        kind: ClarityToolKind = .action,
        requiresSecurityCheck: Bool = false,
        rememberResult: Bool = false,
        ran: @escaping (String) -> Void = { _ in }
    ) -> ClarityTool {
        ClarityTool(
            name: name,
            description: "Does \(name)",
            kind: kind,
            requiresSecurityCheck: requiresSecurityCheck,
            rememberResult: rememberResult,
            label: label,
            approval: approval
        ) { _, completion in
            ran(name)
            completion(.success(["ok": true]))
        }
    }

    func testTheDeclarationCarriesTheLabelAndOnlyWhatDiffersFromTheDefaults() {
        let plain = InAppToolRegistry.declaration(tool("remove_device", label: "  Sign a device out "))
        XCTAssertEqual(plain["label"] as? String, "Sign a device out")
        XCTAssertNil(plain["approval"])
        XCTAssertNil(InAppToolRegistry.declaration(tool("x", approval: ClarityToolApproval()))["approval"])
        XCTAssertNil(InAppToolRegistry.declaration(tool("y", label: "   "))["label"])

        let strict = InAppToolRegistry.declaration(
            tool("delete_account", approval: ClarityToolApproval(allowAll: false, sensitive: .accountDeletion))
        )["approval"] as? NSDictionary
        XCTAssertEqual(strict, ["allowAll": false, "sensitive": "account_deletion"] as NSDictionary)
    }

    func testThePageHearsTheAppsModes() {
        let registry = InAppToolRegistry()
        func modes() -> NSDictionary? {
            (JSONEncoding.object(from: registry.registeredMessage())?["approvalModes"]) as? NSDictionary
        }
        XCTAssertEqual(modes(), ["allowForSession": true, "allowAll": true] as NSDictionary)
        registry.approvalModes = ClarityInAppToolApproval(allowAll: false)
        XCTAssertEqual(modes(), ["allowForSession": true, "allowAll": false] as NSDictionary)
    }

    /// `updateConfig` that changes only `inAppToolApproval` keeps the page
    /// (`equalsIgnoringTemplates` → `applyTemplates`), which re-announces the
    /// declarations when `updateApprovalModes` says the modes changed.
    func testAConfigUpdateOfOnlyTheModesReachesTheLoadedPage() {
        let base = ClarityConfig(organizationId: "1", integrationKey: "k", baseUrl: "https://chat.example.com")
        var narrowed = base
        narrowed.inAppToolApproval = ClarityInAppToolApproval(allowForSession: false)
        XCTAssertNotEqual(base, narrowed)
        XCTAssertTrue(base.equalsIgnoringTemplates(narrowed), "the page is kept, not reloaded")

        let registry = InAppToolRegistry()
        XCTAssertFalse(registry.updateApprovalModes(base.inAppToolApproval), "the defaults are no change")
        XCTAssertTrue(registry.updateApprovalModes(narrowed.inAppToolApproval))
        XCTAssertFalse(registry.updateApprovalModes(narrowed.inAppToolApproval), "the same modes again are no change")
        let announced = JSONEncoding.object(from: registry.registeredMessage())?["approvalModes"] as? NSDictionary
        XCTAssertEqual(announced, ["allowForSession": false, "allowAll": true] as NSDictionary)
        XCTAssertTrue(registry.updateApprovalModes(nil), "back to the defaults")
    }

    func testALabelLongerThanTheCardTakesIsRefused() {
        XCTAssertEqual(
            InAppToolValidation.problem(with: tool("x", label: String(repeating: "L", count: 61))),
            "the label must be at most 60 characters"
        )
        XCTAssertNil(InAppToolValidation.problem(with: tool("x", label: "  " + String(repeating: "L", count: 60) + "  ")))
    }

    // MARK: - A call that came without a card

    private final class Harness {
        var sent: [String] = []
        var ran: [String] = []
        let registry = InAppToolRegistry()
        lazy var runner = InAppToolRunner(
            registry: registry,
            send: { [unowned self] in self.sent.append($0) },
            after: { _, _ in },
            isPageLoaded: { true },
            log: { _ in }
        )

        func call(_ name: String, _ approval: String?, arguments: [String: Any] = [:]) {
            runner.run(callId: "c1", name: name, kind: .action, arguments: arguments, timeoutMs: 30_000, approval: approval)
        }

        var lastError: String? {
            guard let last = sent.last, let json = JSONEncoding.object(from: last), json["status"] as? String == "error" else {
                return nil
            }
            return json["error"] as? String
        }

        var lastStatus: String? {
            sent.last.flatMap { JSONEncoding.object(from: $0)?["status"] as? String }
        }
    }

    private func harness(_ tools: (@escaping (String) -> Void) -> [ClarityTool]) -> Harness {
        let harness = Harness()
        for tool in tools({ [unowned harness] in harness.ran.append($0) }) {
            XCTAssertTrue(harness.registry.register(tool))
        }
        return harness
    }

    func testAPlainActionRunsUnderEitherMode() {
        let harness = harness { ran in [tool("remove_device", ran: ran)] }
        harness.call("remove_device", "session")
        harness.call("remove_device", "allow_all")
        XCTAssertEqual(harness.ran, ["remove_device", "remove_device"])
    }

    func testAnActionThatAlwaysAsksIsRefusedNamingWhy() {
        let harness = harness { ran in [
            tool("settle", approval: ClarityToolApproval(sensitive: .payment), ran: ran),
            tool("delete_account", approval: ClarityToolApproval(sensitive: .accountDeletion), ran: ran),
            tool("pay_bill", ran: ran),
            tool("open_vault", label: "Top up your card", ran: ran),
            tool("travel_mode", requiresSecurityCheck: true, ran: ran),
        ] }
        let answers = ["settle", "delete_account", "pay_bill", "open_vault", "travel_mode"].map { name -> String? in
            harness.call(name, "allow_all")
            return harness.lastError
        }
        XCTAssertEqual(answers, [
            "approval_required:payment",
            "approval_required:account_deletion",
            "approval_required:payment",
            "approval_required:payment",
            "approval_required:security_check",
        ])
        XCTAssertEqual(harness.ran, [])
    }

    func testAModeTheAppKeepsTheToolOutOfIsRefused() {
        let harness = harness { ran in [
            tool("open_vault", approval: ClarityToolApproval(allowForSession: false), ran: ran),
            tool("remove_device", ran: ran),
        ] }
        harness.call("open_vault", "session")
        XCTAssertEqual(harness.lastError, "approval_required")
        harness.call("open_vault", "allow_all")
        XCTAssertEqual(harness.lastStatus, "done")

        harness.registry.approvalModes = ClarityInAppToolApproval(allowAll: false)
        harness.call("remove_device", "allow_all")
        XCTAssertEqual(harness.lastError, "approval_required")
        harness.call("remove_device", "session")
        XCTAssertEqual(harness.lastStatus, "done")
        harness.call("remove_device", "something_else")
        XCTAssertEqual(harness.lastError, "approval_required")

        XCTAssertEqual(harness.ran, ["open_vault", "remove_device"])
    }

    func testTheBuiltInClicksTargetIsReadToo() {
        let harness = harness { ran in [tool("click_element", label: "Press a button", ran: ran)] }
        harness.call("click_element", "allow_all", arguments: ["target": "Delete my account"])
        XCTAssertEqual(harness.lastError, "approval_required:account_deletion")
        harness.call("click_element", "allow_all", arguments: ["target": "Save"])
        XCTAssertEqual(harness.ran, ["click_element"])
    }

    func testACallAfterTheCustomersAllowIsNotJudged() {
        let harness = harness { ran in [tool("pay_bill", approval: ClarityToolApproval(sensitive: .payment), ran: ran)] }
        harness.call("pay_bill", nil)
        XCTAssertEqual(harness.ran, ["pay_bill"])
    }

    func testARememberedAnswerDoesNotGetPastTheCheck() {
        let harness = harness { ran in [
            tool("account_pin", approval: ClarityToolApproval(sensitive: .credentials), rememberResult: true, ran: ran),
        ] }
        XCTAssertTrue(harness.registry.remember("account_pin", result: ["pin": "1234"]))
        harness.call("account_pin", "allow_all")
        XCTAssertEqual(harness.lastError, "approval_required:credentials")
    }

    func testTheCallCarriesHowItWasApproved() {
        let raw = #"{"action":"inAppToolCall","callId":"c1","name":"remove_device","kind":"action","approval":"allow_all"}"#
        guard case .inAppToolCall(_, _, _, _, _, _, let approval)? = BridgeMessage.parse(raw) else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(approval, "allow_all")
    }

    // MARK: - The built-in click

    private func node(_ role: ScreenRole, _ name: String, row: Int, url: String? = nil) -> ScreenNode {
        ScreenNode(role: role, name: name, url: url, rect: CGRect(x: 0, y: row * 40, width: 300, height: 40))
    }

    private var bill: ScreenSnapshot {
        var screen = ScreenSnapshot()
        screen.nodes = [
            node(.heading, "Electricity bill", row: 0),
            node(.text, "48.20 EUR", row: 1),
            node(.button, "Confirm", row: 2),
            node(.button, "Pay now", row: 3),
            node(.text, "Delivery address", row: 4),
            node(.text, "12 Main Street", row: 5),
            node(.text, "Saved addresses", row: 6),
            node(.text, "Your settings", row: 7),
            node(.button, "Save", row: 8),
            node(.link, "Go to checkout", row: 9, url: "https://shop.example.com/checkout/pay"),
            node(.button, "Delete my account", row: 10),
        ]
        return screen
    }

    func testWithoutACardAPressThatMovesMoneyAsksInstead() {
        let screen = bill
        func press(_ name: String) -> String? {
            let found = screen.nodes.first { $0.name == name }!
            return ClickCheck.sensitivePress(found, target: name, on: screen)
        }
        XCTAssertEqual(press("Pay now"), "payment")
        XCTAssertEqual(press("Confirm"), "payment")
        XCTAssertEqual(press("Go to checkout"), "payment")
        XCTAssertEqual(press("Delete my account"), "account_deletion")
        XCTAssertNil(press("Save"))
    }

    func testADeepLinkToMoneyAsks() {
        var screen = ScreenSnapshot()
        screen.nodes = [node(.link, "Open basket", row: 0, url: "myapp://checkout")]
        XCTAssertEqual(ClickCheck.sensitivePress(screen.nodes[0], target: "Open basket", on: screen), "payment")
    }

    func testTheContextIsABandFromThreeHeightsAboveToOneBelowAcrossTheScreen() {
        var screen = ScreenSnapshot()
        screen.nodes = ["far above", "three above", "two above", "one above", "Confirm", "one below", "two below"]
            .enumerated()
            .map { node($0.element == "Confirm" ? .button : .text, $0.element, row: $0.offset) }
        XCTAssertEqual(
            ClickCheck.contextText(screen.nodes[4], on: screen),
            "three above two above one above one below"
        )
    }
}
