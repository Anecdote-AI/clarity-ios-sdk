import Foundation

/// Ready-made in-app tools the SDK implements itself, the way a website gets
/// them from `inAppToolTemplates`. The same rules as the web:
///
/// - nothing passed (`ClarityConfig.inAppToolTemplates` left nil): every group is on;
/// - some groups set to `false`: only those groups are off;
/// - an empty `ClarityToolTemplates()`, or `ClarityToolTemplates.disabled`: every ready-made tool is off.
///
/// ```swift
/// var config = ClarityConfig(organizationId: "…", integrationKey: "…", baseUrl: "…")
/// // Every group but location, with the website and the app's screens:
/// config.inAppToolTemplates = ClarityToolTemplates(
///     siteSearch: .with(.init(siteURL: URL(string: "https://help.example.com")!)),
///     navigation: .with(.init(screens: [ClarityScreen(path: "/orders", title: "My orders")])),
///     location: false
/// )
/// ```
///
/// | Group | Tools |
/// | --- | --- |
/// | `page` | `read_page`, `show_on_page`, `get_page_text` |
/// | `siteSearch` | `find_on_site`, `read_link` (needs `siteURL`) |
/// | `navigation` | `open_link` (needs the app's `screens`) |
/// | `forms` | `get_form`, `focus_form_field`, `fill_form_fields` |
/// | `diagnostics` | `get_diagnostics`, and `reload_page` once the app sets `Clarity.setScreenReloader` |
/// | `location` | `get_location` (needs a provider from the `ClarityLocation` module) |
/// | `click` | `click_element` |
///
/// A group that is on but misses what it needs (`siteSearch` without a
/// website, `navigation` without screens, `location` without a provider) offers
/// nothing; one you turned on yourself (`true` or `.with`) also logs why.
///
/// The tools are offered to the agent only while the app's channel has
/// **Use for chat** (in chat) or **Use for voice** (in a call) switched on
/// under **In-app tools** in the cabinet; the server checks it. An action still
/// waits for the customer's Allow on the card, or their "yes" in a call.
///
/// Your own tools (`Clarity.registerTool`) are offered first; a tool of yours
/// with a template's name replaces the template. Keep a control from being
/// pressed by `click_element` with `UIView.clarityNoClick` or
/// `.clarityNoClick()` (SwiftUI).
public struct ClarityToolTemplates: Equatable, Sendable {
    public var page: Setting<Page>?
    public var siteSearch: Setting<SiteSearch>?
    public var navigation: Setting<Navigation>?
    public var forms: Setting<Forms>?
    public var diagnostics: Setting<Diagnostics>?
    public var location: Setting<Location>?
    public var click: Setting<Click>?

    /// Each group left nil keeps its default (on), unless every group is nil:
    /// `ClarityToolTemplates()` turns every ready-made tool off, like the web's `{}`.
    public init(
        page: Setting<Page>? = nil,
        siteSearch: Setting<SiteSearch>? = nil,
        navigation: Setting<Navigation>? = nil,
        forms: Setting<Forms>? = nil,
        diagnostics: Setting<Diagnostics>? = nil,
        location: Setting<Location>? = nil,
        click: Setting<Click>? = nil
    ) {
        self.page = page
        self.siteSearch = siteSearch
        self.navigation = navigation
        self.forms = forms
        self.diagnostics = diagnostics
        self.location = location
        self.click = click
    }

    /// No ready-made tool at all (the web's `inAppToolTemplates: false`).
    /// Not named `none`: on an optional, `.none` would be nil, which is every group.
    public static let disabled = ClarityToolTemplates()

    /// One group's setting: `false` (`.off`) turns it off, `true` (`.on`)
    /// keeps it on with its default options, `.with(options)` turns it on
    /// with yours.
    public enum Setting<Options: Equatable & Sendable>: Equatable, Sendable, ExpressibleByBooleanLiteral {
        case off
        case on
        case with(Options)

        public init(booleanLiteral value: Bool) {
            self = value ? .on : .off
        }
    }

    /// Reading the screen the customer is on, and showing them where
    /// something is on it.
    public struct Page: Equatable, Sendable {
        /// Whether `get_page_text` (the whole visible text, asked each time)
        /// is offered.
        public var pageText: PageText
        public init(pageText: PageText = .ask) {
            self.pageText = pageText
        }
    }

    public enum PageText: Equatable, Sendable {
        /// Offered; the customer allows each read on a card.
        case ask
        /// Not offered.
        case off
    }

    /// Finding and reading pages of your organization's public website.
    public struct SiteSearch: Equatable, Sendable {
        /// The website: an `https://` origin, with an optional base path.
        public var siteURL: URL
        /// The website's search, on the same origin, with `{query}` where the
        /// words go: `"https://help.example.com/search?q={query}"` or
        /// `"/search?q={query}"`. Without it, pages are matched in the sitemap.
        public var searchURL: String?
        public init(siteURL: URL, searchURL: String? = nil) {
            self.siteURL = siteURL
            self.searchURL = searchURL
        }
    }

    /// Opening the app's own screens. Needs `Clarity.setNavigator`, unless
    /// every screen has a `deepLink` in one of the app's URL schemes.
    public struct Navigation: Equatable, Sendable {
        public var screens: [ClarityScreen]
        public init(screens: [ClarityScreen]) {
            self.screens = screens
        }
    }

    /// Helping with the form on the current screen. Set `textContentType` on
    /// your fields so the agent knows what each one is.
    public struct Forms: Equatable, Sendable {
        public init() {}
    }

    /// Why the app may not work for the customer: device, permissions, the
    /// errors the app reported (`Clarity.recordAppError`).
    public struct Diagnostics: Equatable, Sendable {
        public init() {}
    }

    /// The customer's location, after they allow it on a card and the system
    /// asks them. Needs the `ClarityLocation` module and
    /// `NSLocationWhenInUseUsageDescription` in your Info.plist.
    public struct Location: Equatable, Sendable {
        public let provider: ClarityLocationProvider
        public init(provider: ClarityLocationProvider) {
            self.provider = provider
        }

        public static func == (lhs: Location, rhs: Location) -> Bool {
            lhs.provider === rhs.provider
        }
    }

    /// Pressing a button, link or other control on the screen for the
    /// customer (`click_element`), after they allow it on the chat's card. It
    /// never types, and never presses a text field, a disabled or hidden
    /// control, a control in a private region, or one marked
    /// `clarityNoClick`. A SwiftUI button is pressed through the action you
    /// give its `clarityLabel(_:role:url:action:)` (or, while VoiceOver is on,
    /// through its accessibility element).
    public struct Click: Equatable, Sendable {
        public init() {}
    }
}

/// A screen of your app the agent may open with `open_link`.
public struct ClarityScreen: Equatable, Sendable {
    /// Starts with `/`; letters, digits, `_ - . /` and `{name}` segments for
    /// the parts the agent fills in: `"/orders/{order_id}"`. At most 100.
    public var path: String
    /// What the customer calls the screen, at most 60 characters.
    public var title: String
    /// For the agent: what the screen is for, at most 120 characters.
    public var description: String?
    /// Opens the screen without a navigator, e.g. `"myapp://orders/{order_id}"`;
    /// its scheme must be one of the app's own URL schemes.
    public var deepLink: String?

    public init(path: String, title: String, description: String? = nil, deepLink: String? = nil) {
        self.path = path
        self.title = title
        self.description = description
        self.deepLink = deepLink
    }
}

/// How a navigator or reloader answers.
public enum ClarityTaskOutcome: Sendable, Equatable {
    case done
    /// Failed; the message reaches the agent.
    case failed(String)
}

/// The screen `open_link` asked for: its declared screen, the concrete path
/// and the values of its `{name}` segments.
public struct ClarityNavigationRequest: Sendable, Equatable {
    public let path: String
    public let screen: ClarityScreen
    public let params: [String: String]

    public init(path: String, screen: ClarityScreen, params: [String: String]) {
        self.path = path
        self.screen = screen
        self.params = params
    }
}

/// Opens your app's screens for `open_link` (`Clarity.setNavigator`).
public struct ClarityNavigator {
    let open: @MainActor (ClarityNavigationRequest, @escaping @Sendable (ClarityTaskOutcome) -> Void) -> Void
    let currentPath: (@MainActor () -> String?)?

    /// - Parameters:
    ///   - open: called on the main thread; call the completion once, from
    ///     any thread, with `.done` once the screen is shown or
    ///     `.failed(reason)`.
    ///   - currentPath: the path of the screen on top, in the form of
    ///     `ClarityScreen.path` with the values filled in ("/orders/123").
    public init(
        open: @escaping @MainActor (ClarityNavigationRequest, @escaping @Sendable (ClarityTaskOutcome) -> Void) -> Void,
        currentPath: (@MainActor () -> String?)? = nil
    ) {
        self.open = open
        self.currentPath = currentPath
    }
}

/// The location `get_location` returns: rounded to about a kilometre by the SDK.
public struct ClarityLocationFix: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Metres.
    public let accuracy: Double

    public init(latitude: Double, longitude: Double, accuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }
}

/// Why no location could be had.
public enum ClarityLocationFailure: Error, Sendable, Equatable {
    /// The customer did not allow it on the device.
    case denied
    /// Location services are off.
    case servicesOff
    case unavailable(String)
}

/// Where the location comes from. `ClarityCoreLocation()` in the
/// `ClarityLocation` module is the one to use; the core SDK links no location
/// framework, so an app that does not use location never carries one.
public protocol ClarityLocationProvider: AnyObject, Sendable {
    /// "granted", "denied" or "prompt" (not asked yet).
    @MainActor func authorizationStatus() -> String
    /// Asks the system for permission when it has not been asked, then for
    /// one fix. Called on the main thread; answer once, from any thread.
    @MainActor func requestLocation(
        timeout: TimeInterval,
        maximumAge: TimeInterval,
        completion: @escaping @Sendable (Result<ClarityLocationFix, ClarityLocationFailure>) -> Void
    )
}
