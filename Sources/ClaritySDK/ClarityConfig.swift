import Foundation

/// Static configuration for the Clarity support widget.
///
/// `organizationId` / `integrationKey` are identifiers, not secrets — the same
/// values the web embed snippet exposes. Field semantics and defaults mirror
/// the Android SDK's `ClarityConfig` one-to-one.
public struct ClarityConfig: Equatable, Sendable {
    /// Platform organization id (also drives the widget's brand customization).
    public var organizationId: String
    /// The ios_sdk channel's integration key.
    public var integrationKey: String
    /// Live Chat host the widget page is served from, e.g. `https://live-chat.onclarity.com`.
    public var baseUrl: String
    /// Web-channel Domain Address; when set it is sent as the `Origin` header
    /// during the handshake (testing workaround for web-widget credentials).
    public var channelHost: String?
    /// Overrides the app id sent as `x-app-id`; defaults to the app's bundle
    /// identifier. Must match the channel's App ID configured in the cabinet.
    public var appId: String?
    /// Optional widget UI language override (`language` URL param).
    public var language: String?
    /// Default presentation used by `Clarity.show()` with no arguments.
    public var presentationMode: PresentationMode
    /// Bottom-sheet height as a fraction of the screen; clamped to 0.3...1.0 at use.
    public var sheetHeightFraction: Double
    /// Focus the message composer (and try to raise the keyboard) after the widget opens.
    public var autoFocusInput: Bool
    /// Pre-warm the widget page shortly after `initialize`/`identify` so opening is instant.
    public var autoPreload: Bool
    /// Render a native ✕ button over the widget (the page has its own close control).
    public var showNativeCloseButton: Bool
    /// How long to wait for the page's `pageLoaded` signal before failing the load.
    public var loadTimeout: TimeInterval

    public static let defaultSheetHeightFraction: Double = 0.85
    public static let defaultLoadTimeout: TimeInterval = 15

    public init(
        organizationId: String,
        integrationKey: String,
        baseUrl: String,
        channelHost: String? = nil,
        appId: String? = nil,
        language: String? = nil,
        presentationMode: PresentationMode = .bottomSheet,
        sheetHeightFraction: Double = ClarityConfig.defaultSheetHeightFraction,
        autoFocusInput: Bool = false,
        autoPreload: Bool = true,
        showNativeCloseButton: Bool = false,
        loadTimeout: TimeInterval = defaultLoadTimeout
    ) {
        self.organizationId = organizationId
        self.integrationKey = integrationKey
        self.baseUrl = baseUrl
        self.channelHost = channelHost
        self.appId = appId
        self.language = language
        self.presentationMode = presentationMode
        self.sheetHeightFraction = sheetHeightFraction
        self.autoFocusInput = autoFocusInput
        self.autoPreload = autoPreload
        self.showNativeCloseButton = showNativeCloseButton
        self.loadTimeout = loadTimeout
    }
}
