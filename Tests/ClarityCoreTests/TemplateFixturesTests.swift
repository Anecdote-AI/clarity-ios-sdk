import XCTest
@testable import ClaritySDK

/// The golden fixtures shared with the Android SDK
/// (`Fixtures/templates/`, a copy of `apps/android-sdk/sdk/src/test/resources/templates/`):
/// the canonical declarations and the website tools' results.
/// `CLARITY_UPDATE_FIXTURES=1 swift test` rewrites them from this SDK — only
/// on purpose, and then the Android copy must be updated to match.
final class TemplateFixturesTests: XCTestCase {

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/templates")

    private var updating: Bool { ProcessInfo.processInfo.environment["CLARITY_UPDATE_FIXTURES"] == "1" }

    /// The serialized form both platforms compare: sorted keys, no escaping of /.
    static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else { return "<not JSON>" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Declarations

    /// Every group on, with the screens and website the canonical copy names.
    static let fullConfig = ClarityToolTemplates(
        page: true,
        siteSearch: .with(.init(siteURL: URL(string: "https://help.example.com")!)),
        navigation: .with(.init(screens: [
            ClarityScreen(path: "/orders", title: "My orders"),
            ClarityScreen(path: "/orders/{order_id}", title: "One order", description: "Items and delivery"),
            ClarityScreen(path: "/profile/address", title: "Delivery address"),
        ])),
        forms: true,
        diagnostics: true,
        location: .with(.init(provider: FakeLocation())),
        click: true
    )

    static let fullEnvironment = TemplateCatalog.Environment(
        hasNavigator: true, hasReloader: true, locationUsageDeclared: true, appURLSchemes: []
    )

    func testTheDeclarationsAreTheCanonicalOnes() throws {
        let (specs, warnings) = TemplateCatalog.specs(for: Self.fullConfig, environment: Self.fullEnvironment)
        XCTAssertEqual(warnings, [])
        let declared: [String: Any] = [
            "about": "The declarations of every template with all groups on: siteUrl https://help.example.com, the three screens below, a navigator, a screen reloader and the location provider. Identical on Android and iOS (spec #2041, section 5).",
            "screens": [
                ["path": "/orders", "title": "My orders"],
                ["path": "/orders/{order_id}", "title": "One order", "description": "Items and delivery"],
                ["path": "/profile/address", "title": "Delivery address"],
            ],
            "tools": specs.map(\.declaration),
        ]
        let url = Self.directory.appendingPathComponent("declarations.json")
        if updating {
            try Self.canonical(declared).write(to: url, atomically: true, encoding: .utf8)
        }
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        XCTAssertEqual(Self.canonical(stored), Self.canonical(declared))
    }

    func testEveryDeclarationPassesTheBackendRules() {
        let (specs, _) = TemplateCatalog.specs(for: Self.fullConfig, environment: Self.fullEnvironment)
        XCTAssertEqual(specs.map(\.name), TemplateCatalog.order)
        for spec in specs {
            let tool = ClarityTool(name: spec.name, description: spec.description, kind: spec.kind, parameters: spec.parameters, timeoutSeconds: spec.timeoutSeconds) { _, _ in }
            XCTAssertNil(InAppToolValidation.problem(with: tool), spec.name)
        }
    }

    // MARK: - The website tools

    func testTheWebsiteToolsMatchTheGoldenCases() throws {
        let url = Self.directory.appendingPathComponent("cases.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var cases = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        for index in cases.indices {
            let item = cases[index]
            let name = item["name"] as? String ?? "?"
            let siteURL = try XCTUnwrap(URL(string: item["siteUrl"] as? String ?? ""))
            let tools = SiteSearchTools(
                siteURL: siteURL,
                searchURL: item["searchUrl"] as? String,
                fetcher: FixtureFetcher(root: Self.directory.appendingPathComponent("site"))
            )
            let arguments = item["arguments"] as? [String: Any] ?? [:]
            var outcome: Result<[String: Any], SiteFetchError>?
            if item["tool"] as? String == "read_link" {
                tools.read(path: arguments["path"] as? String ?? "") { outcome = $0 }
            } else {
                tools.find(query: arguments["query"] as? String) { outcome = $0 }
            }
            let actual: [String: Any]
            switch try XCTUnwrap(outcome, "\(name): the fake fetcher answers synchronously") {
            case .success(let value): actual = ["expected": value]
            case .failure(let error): actual = ["error": error.message]
            }
            if updating {
                cases[index]["expected"] = actual["expected"]
                cases[index]["error"] = actual["error"]
                continue
            }
            var stored: [String: Any] = [:]
            stored["expected"] = item["expected"]
            stored["error"] = item["error"]
            XCTAssertEqual(Self.canonical(stored), Self.canonical(actual), name)
        }
        if updating {
            manifest["cases"] = cases
            try Self.canonical(manifest).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Serves `site/<host>/` as the fixtures' manifest describes.
struct FixtureFetcher: SiteFetching {
    let root: URL

    func fetch(_ url: URL, completion: @escaping (Result<SiteResponse, SiteFetchError>) -> Void) {
        var path = url.path
        if path.isEmpty || path == "/" {
            path = "/index.html"
        } else if !(path.hasSuffix(".xml") || path.hasSuffix(".txt")) {
            path += ".html"
        }
        let file = root.appendingPathComponent(url.host ?? "").appendingPathComponent(String(path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else {
            completion(.failure(SiteFetchError(message: "\(SiteAddress.pathOf(url)) answered 404")))
            return
        }
        let type = path.hasSuffix(".xml") ? "application/xml" : (path.hasSuffix(".txt") ? "text/plain" : "text/html")
        completion(.success(SiteResponse(url: url, contentType: type, body: data)))
    }
}

final class FakeLocation: ClarityLocationProvider, @unchecked Sendable {
    var status = "prompt"
    var answer: Result<ClarityLocationFix, ClarityLocationFailure> = .failure(.denied)

    func authorizationStatus() -> String { status }

    func requestLocation(
        timeout: TimeInterval,
        maximumAge: TimeInterval,
        completion: @escaping @Sendable (Result<ClarityLocationFix, ClarityLocationFailure>) -> Void
    ) {
        completion(answer)
    }
}
