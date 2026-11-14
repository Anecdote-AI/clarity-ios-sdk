import XCTest
@testable import ClaritySDK

/// The pure parts of the ready-made tools: what is offered, matching a name
/// on the screen, the app's screens, field types, the results' shapes and the
/// HTML reader's edges. The website tools' results are in the golden fixtures.
final class TemplateCoreTests: XCTestCase {

    // MARK: - What a config offers

    private func offered(_ templates: ClarityToolTemplates, _ environment: TemplateCatalog.Environment = .init())
        -> (names: [String], warnings: [String])
    {
        let (specs, warnings) = TemplateCatalog.specs(for: templates, environment: environment)
        return (specs.map(\.name), warnings)
    }

    // MARK: - Defaults (the web's DEFAULT_IN_APP_TOOL_TEMPLATES and chosenTemplates)

    private static let defaultNames = [
        "read_page", "show_on_page", "get_page_text",
        "get_form", "focus_form_field", "fill_form_fields",
        "get_diagnostics",
        "click_element",
    ]

    /// The defaults, with a screen reloader: `reload_page` in its place.
    private static let defaultNamesWithReload = [
        "read_page", "show_on_page", "get_page_text",
        "get_form", "focus_form_field", "fill_form_fields",
        "get_diagnostics", "reload_page",
        "click_element",
    ]

    /// Every group the app provides what it needs for.
    private static let everything = TemplateCatalog.Environment(
        hasNavigator: true, hasReloader: true, locationUsageDeclared: true, appURLSchemes: []
    )

    private static let site = ClarityToolTemplates.SiteSearch(siteURL: URL(string: "https://help.example.com")!)
    private static let screens = ClarityToolTemplates.Navigation(screens: [ClarityScreen(path: "/orders", title: "My orders")])

    func testNothingPassedTurnsEveryGroupOn() {
        let (specs, warnings) = TemplateCatalog.specs(for: nil, environment: .init())
        XCTAssertEqual(specs.map(\.name), Self.defaultNames)
        // The groups that need what only the app knows stay quiet.
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(
            TemplateCatalog.specs(for: nil, environment: Self.everything).specs.map(\.name),
            Self.defaultNamesWithReload
        )
    }

    func testOptionsForOneGroupKeepTheOthersOn() {
        let templates = ClarityToolTemplates(
            siteSearch: .with(Self.site),
            navigation: .with(Self.screens),
            location: .with(.init(provider: FakeLocation()))
        )
        XCTAssertEqual(offered(templates, Self.everything).names, TemplateCatalog.order)
    }

    func testAGroupSetToFalseIsTheOnlyOneOff() {
        XCTAssertEqual(
            offered(.init(forms: false)).names,
            ["read_page", "show_on_page", "get_page_text", "get_diagnostics", "click_element"]
        )
        let all = ClarityToolTemplates(
            siteSearch: .with(Self.site),
            navigation: .with(Self.screens),
            location: false
        )
        XCTAssertEqual(offered(all, Self.everything).names, TemplateCatalog.order.filter { $0 != "get_location" })
        XCTAssertEqual(
            offered(.init(page: .off, diagnostics: false, click: false)).names, ["get_form", "focus_form_field", "fill_form_fields"]
        )
    }

    func testAnEmptySetOrNoneTurnsEveryToolOff() {
        XCTAssertTrue(offered(ClarityToolTemplates(), Self.everything).names.isEmpty)
        XCTAssertTrue(offered(.disabled, Self.everything).names.isEmpty)
        XCTAssertTrue(TemplateCatalog.specs(for: ClarityToolTemplates.disabled, environment: Self.everything).specs.isEmpty)
        XCTAssertEqual(ClarityToolTemplates(), ClarityToolTemplates.disabled)
    }

    func testEveryGroupOffIsNone() {
        let off = ClarityToolTemplates(
            page: false, siteSearch: false, navigation: false, forms: false, diagnostics: false, location: false, click: false
        )
        XCTAssertTrue(offered(off, Self.everything).names.isEmpty)
    }

    func testAGroupTurnedOnWithoutWhatItNeedsSaysWhy() {
        let (names, warnings) = offered(.init(siteSearch: true, navigation: true, location: true), Self.everything)
        XCTAssertEqual(names, Self.defaultNamesWithReload)
        XCTAssertEqual(warnings.count, 3)
        XCTAssertTrue(warnings[0].hasPrefix("siteSearch"))
        XCTAssertTrue(warnings[1].hasPrefix("navigation"))
        XCTAssertTrue(warnings[2].hasPrefix("location"))
    }

    func testTrueIsTheDefault() {
        XCTAssertEqual(offered(.init(page: true)).names, Self.defaultNames)
        XCTAssertEqual(ClarityToolTemplates.Setting<ClarityToolTemplates.Forms>.on, true)
        XCTAssertEqual(ClarityToolTemplates.Setting<ClarityToolTemplates.Forms>.off, false)
    }

    // MARK: - One group's options

    private static func only(
        page: ClarityToolTemplates.Setting<ClarityToolTemplates.Page> = false,
        siteSearch: ClarityToolTemplates.Setting<ClarityToolTemplates.SiteSearch> = false,
        navigation: ClarityToolTemplates.Setting<ClarityToolTemplates.Navigation> = false,
        forms: ClarityToolTemplates.Setting<ClarityToolTemplates.Forms> = false,
        diagnostics: ClarityToolTemplates.Setting<ClarityToolTemplates.Diagnostics> = false,
        location: ClarityToolTemplates.Setting<ClarityToolTemplates.Location> = false,
        click: ClarityToolTemplates.Setting<ClarityToolTemplates.Click> = false
    ) -> ClarityToolTemplates {
        ClarityToolTemplates(
            page: page, siteSearch: siteSearch, navigation: navigation,
            forms: forms, diagnostics: diagnostics, location: location, click: click
        )
    }

    func testPageTextCanBeLeftOut() {
        XCTAssertEqual(offered(Self.only(page: true)).names, ["read_page", "show_on_page", "get_page_text"])
        XCTAssertEqual(offered(Self.only(page: .with(.init(pageText: .off)))).names, ["read_page", "show_on_page"])
    }

    func testReloadPageNeedsAReloader() {
        XCTAssertEqual(offered(Self.only(diagnostics: true)).names, ["get_diagnostics"])
        XCTAssertEqual(
            offered(Self.only(diagnostics: true), .init(hasReloader: true)).names,
            ["get_diagnostics", "reload_page"]
        )
    }

    func testNavigationNeedsANavigatorOrAppDeepLinks() {
        let screens = [ClarityScreen(path: "/orders", title: "My orders", deepLink: "myapp://orders")]
        let without = offered(Self.only(navigation: .with(.init(screens: screens))))
        XCTAssertEqual(without.names, [])
        XCTAssertEqual(without.warnings.count, 1)
        XCTAssertEqual(offered(Self.only(navigation: .with(.init(screens: screens))), .init(hasNavigator: true)).names, ["open_link"])
        XCTAssertEqual(offered(Self.only(navigation: .with(.init(screens: screens))), .init(appURLSchemes: ["myapp"])).names, ["open_link"])
        // A universal link is never routed back to the app that opens it.
        let web = [ClarityScreen(path: "/orders", title: "My orders", deepLink: "https://example.com/orders")]
        XCTAssertEqual(offered(Self.only(navigation: .with(.init(screens: web))), .init(appURLSchemes: ["https"])).names, [])
    }

    func testLocationNeedsTheUsageString() {
        let templates = Self.only(location: .with(.init(provider: FakeLocation())))
        let without = offered(templates)
        XCTAssertEqual(without.names, [])
        XCTAssertTrue(without.warnings[0].contains("NSLocationWhenInUseUsageDescription"))
        XCTAssertEqual(offered(templates, .init(locationUsageDeclared: true)).names, ["get_location"])
        XCTAssertEqual(
            TemplateCatalog.specs(for: templates, environment: .init(locationUsageDeclared: true)).specs[0].rememberFor,
            30 * 60
        )
    }

    func testSiteSearchNeedsAnHTTPSWebsite() {
        let http = offered(Self.only(siteSearch: .with(.init(siteURL: URL(string: "http://help.example.com")!))))
        XCTAssertEqual(http.names, [])
        XCTAssertEqual(http.warnings.count, 1)
        let bad = offered(Self.only(siteSearch: .with(.init(siteURL: URL(string: "https://help.example.com")!, searchURL: "/search"))))
        XCTAssertEqual(bad.names, ["find_on_site", "read_link"])
        XCTAssertEqual(bad.warnings.count, 1)
    }

    func testClickIsTheSeventhGroupOnByDefault() {
        XCTAssertEqual(TemplateCatalog.order.last, "click_element")
        XCTAssertTrue(TemplateCatalog.specs(for: nil, environment: .init()).specs.map(\.name).contains("click_element"))
        XCTAssertEqual(offered(Self.only(click: true)).names, ["click_element"])
        XCTAssertFalse(offered(.init(click: false)).names.contains("click_element"))
        let spec = TemplateCatalog.clickElement
        XCTAssertEqual(spec.kind, .action)
        XCTAssertEqual(spec.parameters["required"] as? [String], ["target"])
        XCTAssertEqual(spec.reveal?.message, .revealPressing)
    }

    func testTheWebsiteHostIsInTheDescriptions() {
        let (specs, _) = TemplateCatalog.specs(
            for: Self.only(siteSearch: .with(.init(siteURL: URL(string: "https://help.example.com/kb")!))), environment: .init()
        )
        XCTAssertTrue(specs.allSatisfy { $0.description.contains("(help.example.com)") })
    }

    // MARK: - show_on_page matching (the cases of the web's templates.test.ts)

    func testAHeadingIsFoundByItsName() {
        let candidates: [(name: String, role: ScreenRole)] = [("Plans", .link), ("Cancelling the pack", .heading)]
        XCTAssertEqual(PointMatch.best(candidates, target: "cancelling the pack"), 1)
        XCTAssertNil(PointMatch.best(candidates, target: "refunds"))
    }

    func testAControlBeatsAHeadingOfTheSameName() {
        let candidates: [(name: String, role: ScreenRole)] = [("Save address", .heading), ("Save address", .button)]
        XCTAssertEqual(PointMatch.best(candidates, target: "save address"), 1)
    }

    func testTheBetterScoreWinsThenTheShorterName() {
        let candidates: [(name: String, role: ScreenRole)] = [
            ("Help centre and contact", .link), ("Help centre", .link), ("Open the Help centre now", .button),
        ]
        XCTAssertEqual(PointMatch.best(candidates, target: "Help centre"), 1)
        XCTAssertEqual(PointMatch.best(candidates, target: "help"), 1)
        XCTAssertEqual(PointMatch.best([("Delivery address: street", .text)], target: "street delivery"), 0)
        XCTAssertNil(PointMatch.best([("Delivery", .text)], target: "street"))
    }

    func testMatchingIgnoresCaseAndPunctuation() {
        XCTAssertEqual(PointMatch.normalize("  Save — Address! "), "save  address")
        XCTAssertEqual(PointMatch.score(name: "Save address!", wanted: PointMatch.normalize("SAVE ADDRESS")), 4)
        XCTAssertEqual(PointMatch.normalize("حفظ العنوان؟"), "حفظ العنوان")
    }

    func testNothingMatchingNamesWhatThereIs() {
        XCTAssertEqual(
            PointMatch.notFound(target: "Delete account", names: ["Save address", "Help centre", "Save address"]),
            "nothing on this screen is called \"Delete account\"; you can point at: Save address · Help centre"
        )
        XCTAssertEqual(PointMatch.note(nil), "Here")
        XCTAssertEqual(PointMatch.note("  Tap   here "), "Tap here")
    }

    /// show_on_page runs with no card: neither answer may hand the agent a
    /// text label's own words, which get_page_text gives only after Allow.
    func testAPlainTextIsNeverNamedBack() {
        let candidates: [(name: String, role: ScreenRole)] = [
            ("Hi, Jane Doe", .text), ("SENTINEL-4F2A €12,345.67", .text), ("Pay now", .button), ("Account", .heading),
        ]
        let error = PointMatch.notFound(target: "zzz", candidates: candidates)
        XCTAssertFalse(error.contains("SENTINEL"), error)
        XCTAssertFalse(error.contains("Jane"), error)
        XCTAssertTrue(error.hasSuffix("you can point at: Pay now · Account"), error)

        let index = PointMatch.best(candidates, target: "sentinel")
        XCTAssertEqual(index, 1, "a text can still be pointed at")
        XCTAssertEqual(PointMatch.elementName(candidates[1].name, role: .text, target: "the sentinel"), "the sentinel")
        XCTAssertEqual(PointMatch.elementName("Pay now", role: .button, target: "pay"), "Pay now")
    }

    // MARK: - The app's screens

    private let screens = [
        ClarityScreen(path: "/orders", title: "My orders"),
        ClarityScreen(path: "/orders/{order_id}", title: "One order", description: "Items and delivery",
                      deepLink: "myapp://orders/{order_id}"),
        ClarityScreen(path: "/profile/address", title: "Delivery address"),
    ]

    func testAPathMatchesADeclaredScreenWithItsParams() {
        let request = ScreenPaths.match("/orders/A-12.3?tab=items", screens: screens)
        XCTAssertEqual(request?.path, "/orders/A-12.3")
        XCTAssertEqual(request?.screen.title, "One order")
        XCTAssertEqual(request?.params, ["order_id": "A-12.3"])
        XCTAssertEqual(ScreenPaths.match("/orders", screens: screens)?.params, [:])
        XCTAssertNil(ScreenPaths.match("/orders/a b", screens: screens))
        XCTAssertNil(ScreenPaths.match("/orders/1/items", screens: screens))
        XCTAssertNil(ScreenPaths.match("orders", screens: screens))
        XCTAssertEqual(
            ScreenPaths.notOpenableMessage(screens),
            "only these screens of the app can be opened: /orders, /orders/{order_id}, /profile/address"
        )
    }

    func testADeepLinkIsFilledURLEncoded() {
        XCTAssertEqual(ScreenPaths.fillDeepLink("myapp://orders/{order_id}", params: ["order_id": "A 1/2"]), "myapp://orders/A%201%2F2")
        XCTAssertTrue(ScreenPaths.isAppLink("MyApp://orders/1", schemes: ["myapp"]))
        XCTAssertFalse(ScreenPaths.isAppLink("other://orders/1", schemes: ["myapp"]))
    }

    func testMenuLinksAreTheScreensWithoutPlaceholders() {
        let links = ScreenPaths.menuLinks(screens)
        XCTAssertEqual(links.compactMap { $0["path"] as? String }, ["/orders", "/profile/address"])
        XCTAssertEqual(links.compactMap { $0["text"] as? String }, ["My orders", "Delivery address"])
    }

    func testInvalidScreensAreLeftOutWithAWarning() {
        var warnings: [String] = []
        let valid = ScreenPaths.validScreens([
            ClarityScreen(path: "orders", title: "No slash"),
            ClarityScreen(path: "/orders/x{id}", title: "Half a placeholder"),
            ClarityScreen(path: "/orders", title: ""),
            ClarityScreen(path: "/a", title: "Bad link", deepLink: "myapp://a/{other}"),
            ClarityScreen(path: "/ok", title: "Fine"),
            ClarityScreen(path: "/ok", title: "Twice"),
        ]) { warnings.append($0) }
        XCTAssertEqual(valid.map(\.title), ["Fine"])
        XCTAssertEqual(warnings.count, 5)
    }

    func testTheOpenLinkDescriptionStopsAtAWholeEntry() {
        let many = (1...80).map { ClarityScreen(path: "/screen-number-\($0)", title: "Screen number \($0)") }
        let description = ScreenPaths.openLinkDescription(intro: TemplateCatalog.openLinkIntro, screens: many)
        XCTAssertLessThanOrEqual(description.unicodeScalars.count, 1000)
        XCTAssertTrue(description.hasSuffix(")"), description)
        XCTAssertTrue(description.contains(" Screens: /screen-number-1 (Screen number 1), /screen-number-2"))
    }

    // MARK: - Field types (Appendix A)

    func testContentTypesMapToWebTokens() {
        XCTAssertEqual(FieldTypes.type(contentType: "email", keyboardType: 0, isSecure: false), "email")
        XCTAssertEqual(FieldTypes.type(contentType: "tel", keyboardType: 0, isSecure: false), "tel")
        XCTAssertEqual(FieldTypes.type(contentType: "street-address", keyboardType: 0, isSecure: false), "street-address")
        XCTAssertEqual(FieldTypes.type(contentType: "address-level2", keyboardType: 0, isSecure: false), "address-level2")
        XCTAssertEqual(FieldTypes.type(contentType: "one-time-code", keyboardType: 0, isSecure: false), "one-time-code")
        XCTAssertEqual(FieldTypes.type(contentType: "cc-number", keyboardType: 4, isSecure: false), "cc-number")
        XCTAssertEqual(FieldTypes.type(contentType: "UITextContentTypeEmailAddress", keyboardType: 0, isSecure: false), "email")
        XCTAssertEqual(FieldTypes.type(contentType: "username", keyboardType: 0, isSecure: false), nil)
    }

    func testTheKeyboardIsAFallbackAndASecureFieldIsAPassword() {
        XCTAssertEqual(FieldTypes.type(contentType: nil, keyboardType: FieldTypes.keyboardEmail, isSecure: false), "email")
        XCTAssertEqual(FieldTypes.type(contentType: nil, keyboardType: FieldTypes.keyboardPhonePad, isSecure: false), "tel")
        XCTAssertEqual(FieldTypes.type(contentType: nil, keyboardType: 0, isSecure: true), "current-password")
        XCTAssertEqual(FieldTypes.type(contentType: "email", keyboardType: 0, isSecure: true), "current-password")
        XCTAssertEqual(FieldTypes.type(contentType: "new-password", keyboardType: 0, isSecure: true), "new-password")
        XCTAssertEqual(FieldTypes.inputKind(keyboardType: FieldTypes.keyboardNumberPad), "number")
    }

    // MARK: - Results

    private func node(
        _ role: ScreenRole, _ name: String, y: CGFloat, x: CGFloat = 16,
        field: ScreenField? = nil, url: String? = nil, kind: ScreenMessageKind? = nil
    ) -> ScreenNode {
        ScreenNode(role: role, name: name, url: url, rect: CGRect(x: x, y: y, width: 100, height: 20),
                   field: field, messageKind: kind, handle: nil)
    }

    private var profileScreen: ScreenSnapshot {
        var snapshot = ScreenSnapshot()
        snapshot.title = "Profile"
        snapshot.path = "/profile/address"
        snapshot.lang = "en-US"
        snapshot.nodes = ScreenSnapshot.readingOrder([
            node(.button, "Track parcel", y: 40, x: 200),
            node(.heading, "Delivery address", y: 40),
            node(.message, "Payment failed. Try another card.", y: 70, kind: .toast),
            node(.message, "Try another card.", y: 90, kind: .status),
            node(.field, "Street", y: 120, field: ScreenField(type: "street-address", filled: true)),
            node(.field, "Postcode", y: 160, field: ScreenField(type: "postal-code", error: "Enter a valid postcode")),
            node(.field, "PIN", y: 200, field: ScreenField(type: "current-password", customerOnly: true)),
            node(.field, "Nickname", y: 240, field: ScreenField(type: nil, inputKind: "text", error: "Too long")),
            node(.button, "Save address", y: 280),
            node(.link, "Return policy", y: 320, url: "https://help.example.com/help/returns?x=1"),
            node(.link, "Partner", y: 340, url: "https://partner.example.org/"),
            node(.tab, "Orders", y: 800),
            node(.text, "Balance 1 234 EUR", y: 360),
        ], rightToLeft: false)
        return snapshot
    }

    func testReadPageHasTheWebsFieldsAndNoValues() {
        let result = PageResults.readPage(
            profileScreen,
            menuLinks: ScreenPaths.menuLinks(screens),
            siteURL: URL(string: "https://help.example.com")
        )
        XCTAssertEqual(
            Set(result.keys),
            ["path", "title", "heading", "lang", "selection", "messages", "menu_links", "page_links", "forms", "buttons"]
        )
        XCTAssertEqual(result["heading"] as? String, "Delivery address")
        XCTAssertTrue(result["selection"] is NSNull)
        let messages = result["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 1, "a message inside one already listed is dropped")
        XCTAssertEqual(messages.first?["kind"] as? String, "toast")
        XCTAssertEqual(
            (result["page_links"] as? [[String: Any]])?.compactMap { $0["path"] as? String },
            ["/help/returns?x=1", "https://partner.example.org/"]
        )
        let form = (result["forms"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(form["heading"] as? String, "Delivery address")
        XCTAssertEqual(form["fields"] as? [String], ["Street", "Postcode", "PIN", "Nickname"])
        XCTAssertEqual(form["buttons"] as? [String], ["Save address"])
        XCTAssertEqual(result["buttons"] as? [String], ["Track parcel", "Orders"])
        XCTAssertNil(result["note"])
    }

    /// The biggest label on a home screen is often a balance: never the
    /// heading by its font alone. A marked heading, then the navigation
    /// title, come before a label that is a heading by its font.
    func testABalanceIsNeverTheHeadingByItsFont() {
        XCTAssertFalse(PageResults.readsLikeTitle("$12,345.67"))
        XCTAssertFalse(PageResults.readsLikeTitle("€ 1 234,50"))
        XCTAssertFalse(PageResults.readsLikeTitle("12 345 ₽"))
        XCTAssertFalse(PageResults.readsLikeTitle("4242"))
        XCTAssertTrue(PageResults.readsLikeTitle("Your accounts"))
        XCTAssertTrue(PageResults.readsLikeTitle("Order 1234"))

        var inferred = ScreenNode(role: .heading, name: "Big title", rect: .zero)
        inferred.inferredHeading = true
        var snapshot = ScreenSnapshot()
        snapshot.nodes = [inferred, ScreenNode(role: .heading, name: "Marked heading", rect: CGRect(x: 0, y: 50, width: 10, height: 10))]
        snapshot.title = "Home"
        func heading() -> String? { PageResults.readPage(snapshot, menuLinks: [], siteURL: nil)["heading"] as? String }
        XCTAssertEqual(heading(), "Marked heading")
        snapshot.nodes.removeLast()
        XCTAssertEqual(heading(), "Home", "the navigation title before a heading by font")
        snapshot.title = nil
        XCTAssertEqual(heading(), "Big title")
    }

    func testAPartlyReadScreenTellsTheAgentToAsk() {
        var snapshot = profileScreen
        snapshot.partial = true
        let note = PageResults.readPage(snapshot, menuLinks: [], siteURL: nil)["note"] as? String ?? ""
        XCTAssertTrue(note.hasPrefix("Only part of this screen could be read"))
        XCTAssertTrue(note.contains("ask the customer"))
        snapshot.partial = false
        snapshot.truncated = true
        XCTAssertEqual(PageResults.readPage(snapshot, menuLinks: [], siteURL: nil)["note"] as? String, PageResults.truncatedNote)
    }

    func testGetFormListsStandardFieldsCustomerOnlyOnesAndErrors() {
        let result = PageResults.getForm(profileScreen)
        XCTAssertEqual((result["fields"] as? [[String: Any]])?.compactMap { $0["field"] as? String }, ["street-address", "postal-code"])
        XCTAssertEqual((result["fields"] as? [[String: Any]])?.compactMap { $0["filled"] as? Bool }, [true, false])
        XCTAssertEqual((result["customer_types_it"] as? [[String: Any]])?.first?["field"] as? String, "current-password")
        let errors = result["errors"] as? [[String: Any]] ?? []
        XCTAssertEqual(errors.compactMap { $0["type"] as? String }, ["postal-code", "text"])
        XCTAssertEqual(errors.compactMap { $0["error"] as? String }, ["Enter a valid postcode", "Too long"])
        XCTAssertEqual(result["buttons"] as? [String], ["Save address"])
    }

    // MARK: - fill_form_fields: one field flat or several in fields

    // A voice model (gemini-3.5-flash-lite) twice failed to build the fields
    // list and the fill never happened: one field may be passed flat.

    func testFillDeclaresBothFormsAndRequiresNeither() throws {
        let schema = TemplateCatalog.fillFormFields.parameters
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["field", "value", "fields"])
        XCTAssertNil(schema["required"])
        XCTAssertTrue(TemplateCatalog.fillFormFields.description.contains(
            "To fill one field, pass field and value; for several, pass fields."
        ))
    }

    func testFillTakesOneFieldFlat() throws {
        XCTAssertEqual(
            try PageResults.requestedFields(["field": "postal-code", "value": "NW1 6XE"]),
            [.init(field: "postal-code", value: "NW1 6XE")]
        )
    }

    func testFillTakesSeveralFieldsInFields() throws {
        let arguments: [String: Any] = ["fields": [
            ["field": "street-address", "value": "Baker street 221b"],
            ["field": "postal-code", "value": "NW1 6XE"],
            ["field": "email"],
        ]]
        XCTAssertEqual(
            try PageResults.requestedFields(arguments),
            [.init(field: "street-address", value: "Baker street 221b"), .init(field: "postal-code", value: "NW1 6XE")]
        )
    }

    func testFillRefusesBothForms() {
        let arguments: [String: Any] = [
            "field": "postal-code", "value": "NW1 6XE",
            "fields": [["field": "postal-code", "value": "12345"]],
        ]
        XCTAssertThrowsError(try PageResults.requestedFields(arguments)) { error in
            XCTAssertEqual(error as? PageResults.FillArgumentsError, .init(message: PageResults.fillBothForms))
        }
    }

    func testFillRefusesNeitherForm() {
        XCTAssertThrowsError(try PageResults.requestedFields([:])) { error in
            XCTAssertEqual(error as? PageResults.FillArgumentsError, .init(message: PageResults.fillNeitherForm))
        }
        // A null from JSON is no value.
        XCTAssertThrowsError(try PageResults.requestedFields(["fields": NSNull(), "field": NSNull()])) { error in
            XCTAssertEqual(error as? PageResults.FillArgumentsError, .init(message: PageResults.fillNeitherForm))
        }
    }

    func testFillRefusesAFlatFieldWithoutItsValue() {
        XCTAssertThrowsError(try PageResults.requestedFields(["field": "postal-code"])) { error in
            XCTAssertEqual(error as? PageResults.FillArgumentsError, .init(message: PageResults.fillFlatIncomplete))
        }
    }

    func testPageTextHasTheTextButNoFields() {
        let text = PageResults.pageText(profileScreen)["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Delivery address\n"))
        XCTAssertTrue(text.contains("Balance 1 234 EUR"))
        XCTAssertFalse(text.contains("Street"))
        XCTAssertFalse(text.contains("Orders"), "tabs are buttons in read_page, not text")
    }

    func testReadingOrderIsRowsThenTheLeadingEdge() {
        let ordered = ScreenSnapshot.readingOrder(
            [node(.text, "right", y: 10, x: 200), node(.text, "left", y: 12, x: 10), node(.text, "below", y: 30)],
            rightToLeft: false
        )
        XCTAssertEqual(ordered.map(\.name), ["left", "right", "below"])
        let rtl = ScreenSnapshot.readingOrder(
            [node(.text, "left", y: 10, x: 10), node(.text, "right", y: 10, x: 200)], rightToLeft: true
        )
        XCTAssertEqual(rtl.map(\.name), ["right", "left"])
    }

    func testAResultIsTrimmedUnderTheLimitFromTheEndOfTheLinks() throws {
        var snapshot = ScreenSnapshot()
        snapshot.nodes = (0..<30).map {
            node(.link, String(repeating: "L", count: 80), y: CGFloat($0) * 10, url: "https://x.example/" + String(repeating: "p", count: 600) + "\($0)")
        }
        let result = PageResults.readPage(snapshot, menuLinks: [], siteURL: nil)
        let size = try JSONSerialization.data(withJSONObject: result).count
        XCTAssertLessThanOrEqual(size, PageResults.maxResultBytes)
        XCTAssertLessThan((result["page_links"] as? [Any])?.count ?? 0, 30)
    }

    // MARK: - Diagnostics and location

    func testPermissionValues() {
        XCTAssertEqual(DiagnosticsCore.capturePermission(rawStatus: 3, usageDeclared: true), .granted)
        XCTAssertEqual(DiagnosticsCore.capturePermission(rawStatus: 2, usageDeclared: true), .denied)
        XCTAssertEqual(DiagnosticsCore.capturePermission(rawStatus: 0, usageDeclared: true), .prompt)
        XCTAssertEqual(DiagnosticsCore.capturePermission(rawStatus: 3, usageDeclared: false), .notDeclared)
        XCTAssertEqual(DiagnosticsCore.notificationPermission(rawStatus: 3), .granted)
        XCTAssertEqual(DiagnosticsCore.notificationPermission(rawStatus: 1), .denied)
        XCTAssertEqual(DiagnosticsCore.locationPermission(providerStatus: nil, usageDeclared: true), .unknown)
        XCTAssertEqual(DiagnosticsCore.locationPermission(providerStatus: "granted", usageDeclared: false), .notDeclared)
    }

    /// ITMS-90683: an app without the usage string must never reach
    /// AVCaptureDevice, so the probe is not even asked.
    func testWithoutTheUsageStringTheCameraIsNotDeclaredAndNeverProbed() {
        var asked: [String] = []
        var counted = 0
        let probe = CaptureDeviceProbe(
            authorizationStatus: { asked.append($0); return 3 },
            cameraCount: { counted += 1; return 2 }
        )
        XCTAssertEqual(DiagnosticsCore.capturePermission(mediaType: CaptureDeviceProbe.video, usageDeclared: false, probe: probe), .notDeclared)
        XCTAssertEqual(DiagnosticsCore.capturePermission(mediaType: CaptureDeviceProbe.audio, usageDeclared: false, probe: probe), .notDeclared)
        XCTAssertNil(DiagnosticsCore.cameraCount(usageDeclared: false, probe: probe))
        XCTAssertEqual(asked, [])
        XCTAssertEqual(counted, 0)
    }

    func testWithTheUsageStringTheCameraIsReadThroughTheProbe() {
        var asked: [String] = []
        let probe = CaptureDeviceProbe(
            authorizationStatus: { asked.append($0); return $0 == CaptureDeviceProbe.video ? 3 : 2 },
            cameraCount: { 2 }
        )
        XCTAssertEqual(DiagnosticsCore.capturePermission(mediaType: CaptureDeviceProbe.video, usageDeclared: true, probe: probe), .granted)
        XCTAssertEqual(DiagnosticsCore.capturePermission(mediaType: CaptureDeviceProbe.audio, usageDeclared: true, probe: probe), .denied)
        XCTAssertEqual(DiagnosticsCore.cameraCount(usageDeclared: true, probe: probe), 2)
        XCTAssertEqual(asked, ["vide", "soun"])

        // The class is missing: unknown, no crash.
        let missing = CaptureDeviceProbe.objcRuntime(deviceClass: "ClarityNoSuchCaptureDevice", discoveryClass: "ClarityNoSuchDiscovery")
        XCTAssertNil(missing.authorizationStatus(CaptureDeviceProbe.video))
        XCTAssertNil(missing.cameraCount())
        XCTAssertEqual(DiagnosticsCore.capturePermission(mediaType: CaptureDeviceProbe.video, usageDeclared: true, probe: missing), .unknown)
    }

    func testTheLocationIsRoundedToAboutAKilometre() {
        let result = DiagnosticsCore.locationResult(ClarityLocationFix(latitude: 44.78654, longitude: 20.44891, accuracy: 1234.6))
        XCTAssertEqual(result["lat"] as? Double, 44.79)
        XCTAssertEqual(result["lon"] as? Double, 20.45)
        XCTAssertEqual(result["accuracy_m"] as? Int, 1235)
        XCTAssertEqual(DiagnosticsCore.locationError(.servicesOff), "location is turned off on the device")
    }

    func testAppErrorsKeepTheLastTwentyCut() {
        let log = AppErrorLog()
        (1...25).forEach { log.record("Error \($0) " + String(repeating: "x", count: 300), screen: "/checkout") }
        XCTAssertEqual(log.all.count, 20)
        XCTAssertTrue((log.all.first?["message"] as? String)?.hasPrefix("Error 6 ") == true)
        XCTAssertEqual((log.all.first?["message"] as? String)?.count, 200)
        log.record("   ", screen: nil)
        XCTAssertEqual(log.all.count, 20)
    }

    func testDiagnosticsHaveTheWebsKeysForTheSameFacts() {
        let result = DiagnosticsCore.result(
            environment: .init(osVersion: "18.4", device: "Apple iPhone17,3", appVersion: "1.0 (1)", language: "en-US",
                               timezone: "Europe/Belgrade", localTime: "2026-11-10T14:03:11+01:00", screen: "1179x2556",
                               fontScale: 1, darkMode: false, online: true, connection: "wifi", metered: false,
                               dataSaver: false, batterySaver: false),
            permissions: ["microphone": .granted, "camera": .prompt, "geolocation": .unknown, "notifications": .denied],
            microphones: 1, cameras: 2, appErrors: []
        )
        XCTAssertEqual(Set(result.keys), ["environment", "permissions", "devices", "app_errors", "last_exit"])
        let environment = result["environment"] as? [String: Any] ?? [:]
        XCTAssertEqual(environment["platform"] as? String, "ios")
        XCTAssertEqual(environment["sdk_version"] as? String, "ios \(ClarityVersion.current)")
        XCTAssertTrue((result["devices"] as? [String: Any])?["speakers"] is NSNull)
        XCTAssertEqual((result["permissions"] as? [String: String])?["camera"], "prompt")
    }

    // MARK: - The HTML reader's edges

    func testTheHTMLReaderToleratesBrokenMarkup() {
        let page = HTMLDocument(html: """
        <HTML><BODY><DIV class=x>Unclosed <B>bold <a href=/a>A link</div><p>Next</p></span>
        <script>if (a < b) { document.write("</div>") }</script><p>After &amp; &unknown; &#0;</p>
        """)
        XCTAssertEqual(page.mainText(limit: 100), "Unclosed bold A link Next After & &unknown; \u{FFFD}")
        XCTAssertEqual(page.links().map(\.href), ["/a"])
        XCTAssertTrue(page.isScriptShell == false)
    }

    /// Unclosed `<p>`/`<li>` is ordinary markup; it nested a level per tag,
    /// and the walks (and the release of the tree) recursed once per level:
    /// a few thousand of them crashed the host app on the URLSession
    /// delegate queue's 512 KB stack.
    func testDeeplyNestedMarkupIsReadOnASmallStack() {
        let html = "<body><main>" + String(repeating: "<p>x", count: 3000)
            + String(repeating: "<div>", count: 5000) + "<a href=/deep>deep</a>"
            + String(repeating: "<span>", count: 5000) + "y"
        let done = expectation(description: "read on a 512 KB stack")
        var text = ""
        var links: [String] = []
        let thread = Thread {
            let page = HTMLDocument(html: html)
            text = page.mainText(limit: 100_000)
            links = page.links().map(\.href)
            _ = (page.title, page.structuredData, page.isScriptShell)
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 60)

        XCTAssertTrue(text.hasPrefix("x x x x"), "each <p> closes the one before it")
        XCTAssertTrue(text.hasSuffix("deepy"), "past the cap an element keeps its text: \(text.suffix(20))")
        XCTAssertEqual(links, ["/deep"])
    }

    func testHTMLsImpliedEndTagsCloseTheOpenElement() {
        let page = HTMLDocument(html: """
        <body><ul><li>one<li>two</ul><dl><dt>t<dd>d<dt>t2</dl>\
        <table><tr><td>a<td>b<tr><td>c</table><p>para<div>block</div></body>
        """)
        let body = page.contentRoot
        func names(_ element: HTMLDocument.Element) -> [String] {
            element.children.compactMap { if case .element(let e) = $0 { return e.name } else { return nil } }
        }
        func child(_ element: HTMLDocument.Element, _ name: String) -> HTMLDocument.Element? {
            element.children.lazy.compactMap { if case .element(let e) = $0, e.name == name { return e } else { return nil } }.first
        }
        XCTAssertEqual(names(body), ["ul", "dl", "table", "p", "div"])
        XCTAssertEqual(child(body, "ul").map(names), ["li", "li"])
        XCTAssertEqual(child(body, "dl").map(names), ["dt", "dd", "dt"])
        XCTAssertEqual(child(body, "table").map(names), ["tr", "tr"])
        XCTAssertEqual(child(body, "table").flatMap { child($0, "tr") }.map(names), ["td", "td"])
    }

    func testNestingStopsAtTheDepthCap() {
        let page = HTMLDocument(html: String(repeating: "<div>", count: 1000) + "<a href=/x>end</a>")
        var deepest = 0
        HTMLDocument.visit(page.root) { deepest = max(deepest, $0.depth); return true }
        XCTAssertEqual(deepest, HTMLDocument.maxDepth)
        XCTAssertEqual(HTMLDocument.readableText(page.root), "end")
        XCTAssertEqual(page.links(in: page.root).map(\.text), ["end"], "a link past the cap keeps its text")
    }

    func testAPageWithOnlyAMountPointIsAScriptShell() {
        XCTAssertTrue(HTMLDocument(html: "<body><div id=root></div><script src=app.js></script></body>").isScriptShell)
        XCTAssertFalse(HTMLDocument(html: "<body><div id=root></div></body>").isScriptShell)
        XCTAssertFalse(HTMLDocument(html: #"<body><script type="application/ld+json">{}</script></body>"#).isScriptShell)
    }

    func testSitemapsComeFromRobotsOrTheConventionalPlace() {
        let site = URL(string: "https://help.example.com/kb")!
        XCTAssertEqual(
            Sitemap.sitemapURLs(robots: "SITEMAP: /a.xml\nsitemap: https://evil.example/b.xml\nSitemap: /c.xml.gz", siteURL: site)
                .map(\.absoluteString),
            ["https://help.example.com/a.xml"]
        )
        XCTAssertEqual(Sitemap.sitemapURLs(robots: nil, siteURL: site).map(\.absoluteString), ["https://help.example.com/sitemap.xml"])
        XCTAssertNil(Sitemap.parse(Data("not xml at all <".utf8)))
        XCTAssertEqual(Sitemap.pathsMatching(["/b", "/a"], query: "to", limit: 1), ["/b"])
    }

    func testSearchURLsAreFilledLikeEncodeURIComponent() {
        let site = URL(string: "https://help.example.com")!
        let template = SiteAddress.searchTemplate("/search?q={query}&start={startPage?}", siteURL: site)
        XCTAssertEqual(template, "https://help.example.com/search?q={query}&start={startPage?}")
        XCTAssertEqual(
            SiteAddress.fillSearch(template!, query: "café & co's (1)", siteURL: site)?.absoluteString,
            "https://help.example.com/search?q=caf%C3%A9%20%26%20co's%20(1)&start="
        )
        XCTAssertNil(SiteAddress.searchTemplate("https://other.example.org/?q={query}", siteURL: site))
        XCTAssertNil(SiteAddress.searchTemplate("/search", siteURL: site))
    }
}

/// The chat's accent colour rides on a tool call (spec 7.1); an older page
/// sends none.
final class TemplateBridgeTests: XCTestCase {

    func testACallMayCarryTheChatsAccentColour() {
        let message = BridgeMessage.parse(
            ##"{"action":"inAppToolCall","callId":"c1","name":"show_on_page","kind":"safe_action","arguments":{},"accentColor":"#FF5500"}"##
        )
        guard case .inAppToolCall(_, _, .safeAction, _, _, let accent)? = message else { return XCTFail("not parsed") }
        XCTAssertEqual(accent, "#FF5500")

        let old = BridgeMessage.parse(#"{"action":"inAppToolCall","callId":"c1","name":"read_page"}"#)
        guard case .inAppToolCall(_, _, _, _, _, let none)? = old else { return XCTFail("not parsed") }
        XCTAssertNil(none)
    }

    // MARK: - click_element

    private func clickNode(_ role: ScreenRole, _ name: String, y: CGFloat, noClick: Bool = false) -> ScreenNode {
        var node = ScreenNode(role: role, name: name, rect: CGRect(x: 0, y: y, width: 300, height: 40))
        node.noClick = noClick
        if role == .field { node.field = ScreenField(type: "name") }
        return node
    }

    private var profile: ScreenSnapshot {
        var screen = ScreenSnapshot()
        screen.nodes = [
            clickNode(.heading, "Your profile", y: 0),
            clickNode(.field, "Full name", y: 40),
            clickNode(.button, "Save profile", y: 80),
            clickNode(.text, "Saved at 12:27", y: 120),
            clickNode(.link, "Return policy", y: 160),
            clickNode(.toggle, "Order updates", y: 200),
            clickNode(.button, "Delete my account", y: 240, noClick: true),
        ]
        return screen
    }

    private func refusal(_ target: String) -> String? {
        if case .failure(let refusal) = ClickCheck.target(target, on: profile) { return refusal.message }
        return nil
    }

    func testClickFindsTheNamedControlAsShowOnPageDoes() throws {
        let found = try ClickCheck.target("save profile", on: profile).get()
        XCTAssertEqual(found.name, "Save profile")
        XCTAssertEqual(try ClickCheck.target("Return policy", on: profile).get().role, .link)
        XCTAssertEqual(try ClickCheck.target("Order updates", on: profile).get().role, .toggle)
    }

    func testClickRefusesWhatItMustNotPress() {
        XCTAssertEqual(
            refusal("Full name"),
            "\"Full name\" is a text field, so nothing was pressed; use focus_form_field or fill_form_fields for it"
        )
        XCTAssertEqual(
            refusal("Saved at"),
            "\"Saved at\" is not a button, link or control, so nothing was pressed; highlight it with show_on_page and ask the customer to press it",
            "a text label's own words are not quoted back, only the agent's target"
        )
        XCTAssertEqual(
            refusal("Delete my account"),
            "the app does not let you press \"Delete my account\", so nothing was pressed; highlight it with show_on_page and ask the customer to press it"
        )
        XCTAssertEqual(refusal("Checkout"), PointMatch.notFound(target: "Checkout", candidates: profile.nodes.map { ($0.name, $0.role) }))
        XCTAssertFalse(refusal("Checkout")?.contains("Saved at") ?? true, "no text label among the suggestions")
        XCTAssertEqual(
            ClickCheck.disabled("Save profile"),
            "\"Save profile\" is disabled, so nothing was pressed; highlight it with show_on_page and ask the customer to press it"
        )
        XCTAssertEqual(
            ClickCheck.notVisible("Save profile"),
            "\"Save profile\" is not visible on the screen, so nothing was pressed; highlight it with show_on_page and ask the customer to press it"
        )
        XCTAssertEqual(
            ClickCheck.notPressed("Save profile"),
            "\"Save profile\" could not be pressed; highlight it with show_on_page and ask the customer to press it"
        )
    }

    /// A text link opens only the app's own website or one of its own
    /// schemes; a call, a message, a mail, another app or another site is
    /// the customer's to press, with the web's refusal texts.
    func testClickOpensOnlyTheAppsOwnLinks() {
        let site = URL(string: "https://help.example.com")
        func refusal(_ link: String) -> String? {
            ClickCheck.linkRefusal(link, label: "Call us", siteURL: site, appSchemes: ["myshop"])
        }
        XCTAssertNil(refusal("https://help.example.com/help/returns"))
        XCTAssertNil(refusal("myshop://orders/42"))
        XCTAssertNil(refusal("MyShop://orders/42"), "schemes are case-insensitive")
        let anotherApp = "\"Call us\" opens another app, which happens only when the customer presses it, so nothing was pressed; highlight it with show_on_page and ask the customer to press it"
        XCTAssertEqual(refusal("tel:+15550100"), anotherApp)
        XCTAssertEqual(refusal("sms:+15550100"), anotherApp)
        XCTAssertEqual(refusal("mailto:help@example.com"), anotherApp)
        XCTAssertEqual(refusal("otherapp://pay?to=me"), anotherApp)
        let anotherSite = "\"Call us\" leads to another site, so nothing was pressed; highlight it with show_on_page and ask the customer to press it"
        XCTAssertEqual(refusal("https://evil.example.org/login"), anotherSite)
        XCTAssertEqual(refusal("https://help.example.com@evil.example.org/"), anotherSite)
        XCTAssertEqual(refusal("http://help.example.com/help/returns"), anotherSite, "not https")
        XCTAssertEqual(
            ClickCheck.linkRefusal("https://help.example.com/x", label: "Call us", siteURL: nil, appSchemes: []),
            anotherSite, "no website configured: every site is another"
        )
    }

    func testANoClickRegionMarksTheControlsInside() {
        let nodes = [clickNode(.button, "Pay now", y: 0), clickNode(.button, "Cancel", y: 100)]
        let marked = ClickCheck.markNoClick(nodes, regions: [CGRect(x: 0, y: 0, width: 300, height: 40)])
        XCTAssertEqual(marked.map(\.noClick), [true, false])
    }

    func testAPressSaysWhichScreenItOpened() {
        let same = ClickCheck.pressed(label: "Save profile", before: ("Profile", "/profile"), after: ("Profile", "/profile"))
        XCTAssertEqual(same.keys.sorted(), ["label", "pressed"])
        XCTAssertEqual(same["pressed"] as? Bool, true)
        let moved = ClickCheck.pressed(label: "Orders", before: ("Profile", "/profile"), after: ("My orders", "/orders"))
        XCTAssertEqual(moved["title"] as? String, "My orders")
        XCTAssertEqual(moved["path"] as? String, "/orders")
    }
}
