import XCTest
@testable import ClaritySDK

/// Tools whose allowed card folds the voice call back to its bubble. The page
/// decides when (`collapseCallFor` in `inAppToolsStore.ts`); the SDK only says
/// which tools. The Android port is `InAppCollapseCallOnAllowTest.kt`.
final class InAppCollapseCallOnAllowTests: XCTestCase {

    private let registry = InAppToolRegistry()

    private func register(_ name: String, kind: ClarityToolKind = .action, collapse: Bool) -> Bool {
        registry.register(ClarityTool(
            name: name, description: "Does \(name)", kind: kind, collapseCallOnAllow: collapse
        ) { _, _ in })
    }

    func testThePageHearsWhichToolsFoldTheCall() throws {
        XCTAssertTrue(register("buy_addon", collapse: true))
        XCTAssertTrue(register("remove_device", collapse: false))

        let message = registry.registeredMessage()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["collapseCallOnAllow"] as? [String], ["buy_addon"])
        let tools = try JSONSerialization.data(withJSONObject: object["tools"] ?? [])
        XCTAssertFalse(
            String(decoding: tools, as: UTF8.self).contains("collapseCallOnAllow"),
            "the declarations the backend gets never carry it"
        )
    }

    func testOnlyAnActionMayFoldTheCall() {
        XCTAssertFalse(register("list_addons", kind: .read, collapse: true))
        XCTAssertEqual(
            InAppToolValidation.problem(with: ClarityTool(
                name: "open_screen", description: "Opens", kind: .safeAction, collapseCallOnAllow: true
            ) { _, _ in }),
            InAppToolValidation.collapseCallKindProblem
        )
    }
}
