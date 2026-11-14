import Foundation

/// The ready-made tools' declarations: names, kinds, descriptions, schemas,
/// the way each steps the chat aside, and which are offered for a config.
/// Identical on Android, iOS and Flutter (spec section 5); the core tests
/// compare them with the shared canonical copy
/// (`Tests/ClarityCoreTests/Fixtures/templates/declarations.json`).
enum TemplateCatalog {

    enum Name {
        static let readPage = "read_page"
        static let showOnPage = "show_on_page"
        static let getPageText = "get_page_text"
        static let findOnSite = "find_on_site"
        static let readLink = "read_link"
        static let openLink = "open_link"
        static let getForm = "get_form"
        static let focusFormField = "focus_form_field"
        static let fillFormFields = "fill_form_fields"
        static let getDiagnostics = "get_diagnostics"
        static let reloadPage = "reload_page"
        static let getLocation = "get_location"
        static let clickElement = "click_element"
    }

    /// The canonical order (the web's `TEMPLATE_ORDER`): reading the screen
    /// and showing on it first.
    static let order = [
        Name.readPage, Name.showOnPage, Name.getPageText,
        Name.findOnSite, Name.readLink,
        Name.openLink,
        Name.getForm, Name.focusFormField, Name.fillFormFields,
        Name.getDiagnostics, Name.reloadPage,
        Name.getLocation,
        Name.clickElement,
    ]

    /// The `forms` group: any other tool lets go of the field being asked about.
    static let formsGroup: Set<String> = [Name.getForm, Name.focusFormField, Name.fillFormFields]

    /// Position in `order`; a name it does not know sorts last.
    static func rank(_ name: String) -> Int {
        order.firstIndex(of: name) ?? order.count
    }

    /// How long `get_location`'s answer is remembered: a phone moves.
    static let locationRememberSeconds: TimeInterval = 30 * 60

    static let noArguments: [String: Any] = ["type": "object", "properties": [String: Any]()]

    /// One template's declaration, before its handler is attached.
    struct Spec {
        let name: String
        let kind: ClarityToolKind
        let description: String
        let parameters: [String: Any]
        /// The chat steps aside while it runs: the loader text and the pause after.
        let reveal: (message: NativeStrings.Key, holdAfter: TimeInterval)?
        let rememberFor: TimeInterval?
        /// The tool's own timeout (declared), when the default for its kind is too short.
        let timeoutSeconds: Int?

        init(
            _ name: String,
            _ kind: ClarityToolKind,
            _ description: String,
            parameters: [String: Any] = TemplateCatalog.noArguments,
            reveal: (message: NativeStrings.Key, holdAfter: TimeInterval)? = nil,
            rememberFor: TimeInterval? = nil,
            timeoutSeconds: Int? = nil
        ) {
            self.name = name
            self.kind = kind
            self.description = description
            self.parameters = parameters
            self.reveal = reveal
            self.rememberFor = rememberFor
            self.timeoutSeconds = timeoutSeconds
        }

        /// The declaration as the backend gets it.
        var declaration: [String: Any] {
            var declaration: [String: Any] = ["name": name, "kind": kind.rawValue, "description": description, "inputSchema": parameters]
            if let timeoutSeconds { declaration["timeoutSeconds"] = timeoutSeconds }
            return declaration
        }
    }

    /// What the app provides at run time, which decides what is offered.
    struct Environment {
        var hasNavigator = false
        var hasReloader = false
        var locationUsageDeclared = false
        /// The app's own URL schemes (`CFBundleURLSchemes`), lowercased.
        var appURLSchemes: Set<String> = []
    }

    /// The templates a config turns on, in canonical order, and one log line
    /// for each group the app turned on itself that is left out because
    /// something it needs is missing. nil is a config that passes none: every
    /// group on (the web's `DEFAULT_IN_APP_TOOL_TEMPLATES`).
    static func specs(
        for templates: ClarityToolTemplates?,
        environment: Environment
    ) -> (specs: [Spec], warnings: [String]) {
        let chosen = Chosen(templates)
        var specs: [Spec] = []
        var warnings: [String] = []

        // A group on by default (`implied`) stays quiet when it misses what it
        // needs: an app that never mentioned it gets no log line for it. One
        // the app turned on with `true` (`on`) is told what is missing.
        switch chosen.page {
        case .off: break
        case .implied, .on: specs.append(contentsOf: pageSpecs(.init()))
        case .with(let page): specs.append(contentsOf: pageSpecs(page))
        }

        switch chosen.siteSearch {
        case .off, .implied: break
        case .on: warnings.append("siteSearch is left out: it needs the website, .with(.init(siteURL: …))")
        case .with(let site):
            if let problem = SiteAddress.problem(siteURL: site.siteURL) {
                warnings.append("siteSearch is left out: \(problem)")
            } else {
                let host = site.siteURL.host ?? ""
                specs.append(findOnSite(host: host))
                specs.append(readLink(host: host))
                if let search = site.searchURL, SiteAddress.searchTemplate(search, siteURL: site.siteURL) == nil {
                    warnings.append(
                        "siteSearch.searchURL takes a URL of the website with {query}, such as \"/search?q={query}\"; it is ignored"
                    )
                }
            }
        }

        switch chosen.navigation {
        case .off, .implied: break
        case .on: warnings.append("navigation is left out: it needs the app's screens, .with(.init(screens: […]))")
        case .with(let navigation):
            let screens = ScreenPaths.validScreens(navigation.screens) { warnings.append("navigation: \($0)") }
            let openable = screens.allSatisfy { screen in
                screen.deepLink.map { ScreenPaths.isAppLink($0, schemes: environment.appURLSchemes) } ?? false
            }
            if screens.isEmpty {
                warnings.append("navigation is left out: it has no screens")
            } else if !environment.hasNavigator && !openable {
                warnings.append(
                    "navigation is left out until the app calls Clarity.setNavigator (or gives every screen a deepLink in one of its URL schemes)"
                )
            } else {
                specs.append(openLink(screens: screens))
            }
        }

        if chosen.forms.isOn {
            specs.append(contentsOf: [getForm, focusFormField, fillFormFields])
        }
        if chosen.diagnostics.isOn {
            specs.append(getDiagnostics)
            if environment.hasReloader { specs.append(reloadPage) }
        }

        switch chosen.location {
        case .off, .implied: break
        case .on:
            warnings.append(
                "location is left out: it needs a provider, .with(.init(provider: ClarityCoreLocation())) from the ClarityLocation module"
            )
        case .with:
            if environment.locationUsageDeclared {
                specs.append(getLocation)
            } else {
                warnings.append("location is left out: Info.plist has no NSLocationWhenInUseUsageDescription")
            }
        }

        if chosen.click.isOn {
            specs.append(clickElement)
        }
        return (specs, warnings)
    }

    private static func pageSpecs(_ page: ClarityToolTemplates.Page) -> [Spec] {
        page.pageText == .ask ? [readPage, showOnPage, getPageText] : [readPage, showOnPage]
    }

    /// Each group's setting under the web's rules (`chosenTemplates` in the
    /// web's templates/index.ts):
    /// - no templates at all: every group on (`implied`);
    /// - an empty `ClarityToolTemplates()`: none;
    /// - otherwise a group left nil keeps its default (`implied`), and the
    ///   app's `false` / `true` / `.with` decide the others.
    struct Chosen {
        enum Choice<Options> {
            case off
            /// On because the app did not say otherwise.
            case implied
            /// On because the app said `true`, with the default options.
            case on
            case with(Options)

            var isOn: Bool {
                if case .off = self { return false }
                return true
            }
        }

        let page: Choice<ClarityToolTemplates.Page>
        let siteSearch: Choice<ClarityToolTemplates.SiteSearch>
        let navigation: Choice<ClarityToolTemplates.Navigation>
        let forms: Choice<ClarityToolTemplates.Forms>
        let diagnostics: Choice<ClarityToolTemplates.Diagnostics>
        let location: Choice<ClarityToolTemplates.Location>
        let click: Choice<ClarityToolTemplates.Click>

        init(_ templates: ClarityToolTemplates?) {
            let none = templates == ClarityToolTemplates.disabled
            func choice<O>(_ setting: ClarityToolTemplates.Setting<O>?) -> Choice<O> {
                switch setting {
                case nil: return none ? .off : .implied
                case .off?: return .off
                case .on?: return .on
                case .with(let options)?: return .with(options)
                }
            }
            page = choice(templates?.page)
            siteSearch = choice(templates?.siteSearch)
            navigation = choice(templates?.navigation)
            forms = choice(templates?.forms)
            diagnostics = choice(templates?.diagnostics)
            location = choice(templates?.location)
            click = choice(templates?.click)
        }

        /// The options a group's handlers run with: only `.with` carries any.
        static func options<O>(_ choice: Choice<O>) -> O? {
            if case .with(let options) = choice { return options }
            return nil
        }
    }

    // MARK: - page

    static let readPage = Spec(
        Name.readPage, .read,
        "The app screen the customer is on, in one read: its path (when the app names its screens), title, main heading and language, the messages it shows them now (alerts, errors, dialogs, snackbars), the app's main screens you can open (menu_links), the links on the screen, its form fields (labels only, never what is typed in them) and its other buttons. Read it first for any question about the app or this screen; look in both lists before searching the website."
    )

    static let showOnPage = Spec(
        Name.showOnPage, .safeAction,
        "Shows the customer where something is on the app screen they are on, without moving them to another screen: the chat steps aside, the screen scrolls to the button, link, field, heading or section with that name, the rest dims for a few seconds and your short note appears next to it. It never taps. Call it whenever your answer tells the customer to tap, open, read or find something on the current screen, in the same turn as the answer, not only when they ask \"where\": \"tap Help in the menu\" comes with show_on_page on \"Help\". Call it again for the next step. Never say you highlighted or showed something unless you called it in this turn.",
        parameters: [
            "type": "object",
            "properties": [
                "target": [
                    "type": "string",
                    "description": "The visible name of the element, e.g. \"Save address\" or \"Cancelling a pack\"",
                ],
                "note": [
                    "type": "string",
                    "description": "A short note shown next to it, e.g. \"Tap here to save\"",
                ],
            ],
            "required": ["target"],
        ],
        reveal: (.revealShowing, 3.0)
    )

    static let getPageText = Spec(
        Name.getPageText, .action,
        "The whole visible text of the app screen the customer is on, as the app shows it now (up to 5000 characters), including their own account details on it, never what they typed into a field. Use it when read_page does not answer the question about this screen and the screen shows the customer's own data. The customer is asked to allow each read."
    )

    // MARK: - siteSearch

    static func findOnSite(host: String) -> Spec {
        Spec(
            Name.findOnSite, .read,
            "Finds pages on the organization's website (\(host)) when read_page does not have it. With query: links to the matching pages, from the website's own search when the app set one, otherwise by matching the words against the page addresses of its sitemap. Without query: the pages of its sitemap, to learn what the website has. Read a result with read_link.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "A few key words in the site’s language, e.g. \"returns\", not the customer’s whole question: a site’s search often finds only pages that hold every word. Leave it out to list the pages.",
                    ],
                ],
            ]
        )
    }

    static func readLink(host: String) -> Spec {
        Spec(
            Name.readLink, .read,
            "Reads a page of the organization's website (\(host)) without opening it for the customer: its title, main text and schema.org data. It reads the public page, as a signed-out visitor sees it, never the customer's own account. A page drawn by JavaScript cannot be read this way; the result says so (readable: false).",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path of the page on this site, e.g. /help/returns"],
                ],
                "required": ["path"],
            ]
        )
    }

    // MARK: - navigation

    static let openLinkIntro =
        "Opens a screen of this app for the customer: it moves them away from the screen they are on. Only when the customer asks to be taken there (\"open it\", \"take me there\"), not when they ask how to get there. Use only a path from this list or from read_page's menu_links, never one you made up; fill a {placeholder} only with an id another tool gave you. The chat stays open, also during a voice call."

    static func openLink(screens: [ClarityScreen]) -> Spec {
        Spec(
            Name.openLink, .safeAction,
            ScreenPaths.openLinkDescription(intro: openLinkIntro, screens: screens),
            parameters: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path of the app screen, from the list in this tool's description or read_page's menu_links, e.g. /orders",
                    ],
                ],
                "required": ["path"],
            ],
            reveal: (.revealOpening, 1.0)
        )
    }

    // MARK: - forms

    static let getForm = Spec(
        Name.getForm, .read,
        "The form on the current app screen: its standard fields (name, email, phone, address) in screen order, by type, with their label and whether they are filled; errors, the fields the screen marks as wrong now with the error it shows (any field, not only the standard ones); and buttons, the names of the buttons below the fields. It never returns what is in them. To show the customer a button or a field, call show_on_page with its name. customer_types_it lists fields only the customer types (passwords, cards, codes): never ask for their value in the chat. Use it to help with a form, or when the customer cannot send one."
    )

    static let focusFormField = Spec(
        Name.focusFormField, .safeAction,
        "Scrolls the app screen to a form field and highlights it while you ask the customer about it. Help with a form one field at a time: focus a field, ask for its value, and say the customer can also type it into the highlighted field themselves and just tell you when done; then fill it with fill_form_fields and focus the next one. For a field in customer_types_it, focus it and ask the customer to type it themselves. In a voice call, spell an email or a phone number back and wait for a yes before filling it. Pass \"none\" when the form is done or the customer turns to something else.",
        parameters: [
            "type": "object",
            "properties": [
                "field": ["type": "string", "enum": FieldTypes.fillable + FieldTypes.customerOnly + [FieldTypes.none]],
            ],
            "required": ["field"],
        ],
        reveal: (.revealField, 2.0)
    )

    static let fillFormFields = Spec(
        Name.fillFormFields, .safeAction,
        "Puts values the customer gave you into standard fields of a form on the current screen: one field, or several when the customer gave several at once. To fill one field, pass field and value; for several, pass fields. Each value replaces the field’s whole content: to correct part of it (one word, one letter), send the full corrected value and keep what the customer did not change. In a voice call, before filling a value the customer spelled or dictated (name, email, phone, address), read it back, spelling it out, and fill it only after they say yes. It never submits the form: the customer checks it and sends it themselves. Returns still_empty, the fields left to ask about.",
        // Either one field flat or several in fields: neither is required (the
        // backend's schema subset has no oneOf), the handler refuses neither or both.
        parameters: [
            "type": "object",
            "properties": [
                "field": ["type": "string", "enum": FieldTypes.fillable],
                "value": ["type": "string"],
                "fields": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "field": ["type": "string", "enum": FieldTypes.fillable],
                            "value": ["type": "string"],
                        ],
                        "required": ["field", "value"],
                    ],
                ],
            ],
        ],
        reveal: (.revealFilling, 1.5)
    )

    // MARK: - diagnostics

    static let getDiagnostics = Spec(
        Name.getDiagnostics, .read,
        "Why the app may not work for the customer, in one read: their device, operating system and app version, language, time zone and local time, screen size, text size and dark mode, whether it is online and on which network, data and battery saver; what the device lets this app use (microphone, camera, location, notifications): granted, denied, prompt when the app will still ask, not_granted when Android cannot tell whether it was never asked or refused for good, not_declared when the app does not use it; how many microphones and cameras it sees; the errors the app reported since it started, and on Android how it last closed unexpectedly. Use it when something does not work for them: a screen, a button, a call, a camera, location or notifications."
    )

    static let reloadPage = Spec(
        Name.reloadPage, .action,
        "Reloads the app screen the customer is on: the app fetches its data again, for example after a fix or when the screen is stuck or out of date. Anything they typed on it and did not save may be lost. The chat stays open. Call it on its own, never together with other tools.",
        reveal: (.revealRefreshing, 1.0)
    )

    // MARK: - location

    static let getLocation = Spec(
        Name.getLocation, .action,
        "The customer’s location from their device: lat and lon, rounded to about 1 km. Call it when the customer asks about the nearest place or anything near them, and work out their city from lat and lon. Look up the addresses before you call it: when the customer has to allow it, the location reaches you in a later turn where you cannot look anything up. The message that comes with the card is one short sentence asking for their location: no list of places, no guess. Then answer exactly what they asked, in one or two sentences. \"Is there one in my city?\": \"Yes, in <city>: <address>.\" or \"No, the nearest is in <city>: <address>.\" \"Which is nearest?\": the ONE nearest by straight-line distance, with its address. Never list them all.",
        rememberFor: locationRememberSeconds,
        timeoutSeconds: locationTimeoutSeconds
    )

    // MARK: - click

    static let clickElement = Spec(
        Name.clickElement, .action,
        "Presses a button, link or other control on the current screen for the customer, after they allow it. Use it when the customer asks you to press, save, submit, continue or open something. It never types: use fill_form_fields for text. If it fails, highlight the element with show_on_page and ask the customer to press it.",
        parameters: [
            "type": "object",
            "properties": [
                "target": [
                    "type": "string",
                    "description": "The visible name of the button, link or control, e.g. \"Save profile\"",
                ],
            ],
            "required": ["target"],
        ],
        reveal: (.revealPressing, 1.5)
    )

    /// `get_location`'s own timeout, counted from the customer's Allow: the
    /// system prompt comes after it, and a customer may take a while to decide
    /// (30 s, an action's default, was too short). The same on Android and web.
    static let locationTimeoutSeconds = 60
}
