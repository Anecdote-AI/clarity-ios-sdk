import Foundation
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

/// Public entry point of the Clarity support SDK — the iOS counterpart of the
/// Android SDK's `Clarity` object. All methods are safe to call from any
/// thread; work is confined to the main thread internally. One caveat: the
/// synchronous getters (`config`, `unreadCount`, `isWidgetVisible`,
/// `currentTicketStatus`) marshal through `DispatchQueue.main.sync` when
/// called off-main — never call them from a thread the main thread is
/// itself blocked waiting on, or both sides deadlock.
///
/// Until `initialize` has been called, mutating methods are silent no-ops
/// and the getters are UNGATED — they simply return their empty values
/// (`config`/`currentTicketStatus` nil, `unreadCount` 0, `isWidgetVisible`
/// false); `initialize`, `previewWidgetUrl`, `setListener`, `isClarityPush`
/// and `handlePush` work regardless, and `handleNotificationResponse` is
/// safe but its `show()` routing no-ops until then.
public enum Clarity {

    #if canImport(UIKit)
    private static let controller = WidgetEngine()
    /// Main-thread confined, like all engine state: written inside
    /// `MainThread.run` and read via `engineIfInitialized` from the same
    /// confinement, so a background `initialize` + immediate call sequence
    /// is ordered by the main queue instead of racing on a plain Bool.
    private static var isInitialized = false

    /// The engine, or nil before `initialize` — the single home of the
    /// "mutating methods silently no-op until initialize" contract.
    /// Main-thread confined; off-main callers reach it via `MainThread`.
    private static var engineIfInitialized: WidgetEngine? {
        isInitialized ? controller : nil
    }

    /// The one main-thread hop every mutating public method shares: the
    /// engine is main-confined and does not re-hop internally, so entering
    /// it anywhere else than through this (or `MainThread` directly) would
    /// race its state.
    private static func onEngine(_ block: @escaping (WidgetEngine) -> Void) {
        MainThread.run {
            guard let engine = engineIfInitialized else { return }
            block(engine)
        }
    }
    #endif

    // MARK: - Setup

    /// Call once early (e.g. in your App initializer or
    /// `application(_:didFinishLaunchingWithOptions:)`). Pre-warms the widget
    /// page shortly after unless `config.autoPreload` is false.
    public static func initialize(config: ClarityConfig) {
        #if canImport(UIKit)
        MainThread.run {
            isInitialized = true
            controller.initialize(config: config)
        }
        #endif
    }

    /// Replace the configuration at runtime. A changed config drops the warm
    /// WebView; the next open starts a fresh page (the conversation itself
    /// lives in cookies and survives unless the identity changes).
    public static func updateConfig(_ config: ClarityConfig) {
        #if canImport(UIKit)
        onEngine { $0.updateConfig(config) }
        #endif
    }

    /// Current configuration; nil before `initialize`.
    public static var config: ClarityConfig? {
        #if canImport(UIKit)
        return MainThread.sync { controller.config }
        #else
        return nil
        #endif
    }

    /// The exact widget page URL the SDK will load for the given
    /// configuration, with the one-time session token rendered as
    /// `tokenPlaceholder`. Debug/demo helper — usable before `initialize`;
    /// builds through the same URL builder as the real load path.
    public static func previewWidgetUrl(
        config: ClarityConfig,
        user: ClarityUser = ClarityUser(),
        userAttributes: [String: String] = [:],
        ticketAttributes: [String: String] = [:],
        tokenPlaceholder: String = "ONE_TIME_TOKEN"
    ) -> String {
        WidgetURL.build(
            config: config,
            user: user,
            userAttributes: userAttributes.mapValues(ClarityAttributeValue.string),
            ticketAttributes: ticketAttributes.mapValues(ClarityAttributeValue.string),
            oneTimeToken: tokenPlaceholder
        )
    }

    // MARK: - Identity & data

    /// Set the user identity. Call before `show`/`preload` so the session is
    /// created for the right person. Switching to a different `externalId`
    /// later is treated as logout+login: the previous user's widget web
    /// session is wiped. Re-identifying the same `externalId` with updated
    /// profile fields (email, name, avatar…) keeps the session and the
    /// conversation.
    public static func identify(_ user: ClarityUser) {
        #if canImport(UIKit)
        onEngine { $0.identify(user) }
        #endif
    }

    /// Fetch the latest ticket state on demand — status changes and any agent
    /// replies the realtime channel may have missed. Call it whenever
    /// freshness matters to you (app came to foreground, pull-to-refresh, a
    /// screen showing the support entry point appeared). Results surface
    /// through the normal listener callbacks: `onUnreadCountChanged`,
    /// `onNewMessage`, `onTicketStatusChanged`, and the local notification
    /// when the widget is hidden.
    public static func refresh() {
        #if canImport(UIKit)
        onEngine { $0.refreshConversation() }
        #endif
    }

    /// Long-lived attributes of the person (merged into the contact).
    public static func setUserAttributes(_ attributes: [String: String]) {
        setUserAttributes(attributes.mapValues(ClarityAttributeValue.string))
    }

    /// Typed variant: numbers/booleans store as real JSON types, `.stringList`
    /// selects options of a `list`-type attribute, `nil` removes an attribute.
    /// Disfavored only to break the tie for all-string/empty literals (the
    /// `[String: String]` overload wins those); any typed value selects this
    /// one.
    @_disfavoredOverload
    public static func setUserAttributes(_ attributes: [String: ClarityAttributeValue]) {
        #if canImport(UIKit)
        onEngine { $0.setUserAttributes(attributes) }
        #endif
    }

    /// Context for the NEXT ticket created in this session (e.g. order_id).
    /// Consumed by exactly one ticket: once a ticket is created with these
    /// attributes they are cleared server-side and do not carry over.
    public static func setTicketAttributes(_ attributes: [String: String]) {
        setTicketAttributes(attributes.mapValues(ClarityAttributeValue.string))
    }

    /// Typed variant of `setTicketAttributes` — see `setUserAttributes`.
    @_disfavoredOverload
    public static func setTicketAttributes(_ attributes: [String: ClarityAttributeValue]) {
        #if canImport(UIKit)
        onEngine { $0.setTicketAttributes(attributes) }
        #endif
    }

    /// Product event for automations / AI context; queued until the widget
    /// page loads (up to 50, oldest dropped first).
    public static func logEvent(_ name: String, params: [String: String] = [:]) {
        #if canImport(UIKit)
        onEngine { $0.logEvent(name: name, params: params) }
        #endif
    }

    // MARK: - Presentation

    /// Pre-load the widget page off-screen so `show()` presents instantly.
    /// Only needed when `config.autoPreload` is disabled.
    public static func preload() {
        #if canImport(UIKit)
        onEngine { $0.preload() }
        #endif
    }

    /// Present the support widget. Mode resolution: argument →
    /// `config.presentationMode` → bottom sheet.
    public static func show(
        mode: PresentationMode? = nil,
        sheetHeightFraction: Double? = nil
    ) {
        #if canImport(UIKit)
        present(mode: mode, sheetHeightFraction: sheetHeightFraction, presenter: nil)
        #endif
    }

    #if canImport(UIKit)
    /// Present the support widget from a specific view controller instead of
    /// the SDK's top-view-controller walk. Use it when your app runs multiple
    /// scenes (iPad, Catalyst) or when the automatic pick would race your own
    /// presentation logic. Held weakly; if the presenter is gone by the time
    /// the page is ready, the SDK falls back to the automatic pick.
    public static func show(
        mode: PresentationMode? = nil,
        sheetHeightFraction: Double? = nil,
        from presenter: UIViewController
    ) {
        present(mode: mode, sheetHeightFraction: sheetHeightFraction, presenter: presenter)
    }

    /// The body both public `show` overloads share. Mode defaulting needs
    /// the engine's live config, so it must run inside the main-thread hop —
    /// not at the overload call sites.
    private static func present(
        mode: PresentationMode?,
        sheetHeightFraction: Double?,
        presenter: UIViewController?
    ) {
        onEngine { engine in
            guard let config = engine.config else { return }
            engine.show(
                mode: mode ?? config.presentationMode,
                sheetHeightFraction: sheetHeightFraction,
                presenter: presenter
            )
        }
    }
    #endif

    /// Dismiss the widget if it is on screen. The page keeps running warm so
    /// reopening is instant and replies keep arriving.
    public static func dismiss() {
        #if canImport(UIKit)
        onEngine { $0.dismiss() }
        #endif
    }

    /// True while the widget container is on screen. Main-thread confined,
    /// like the callbacks it mirrors (`onWidgetShown` / `onWidgetDismissed`).
    public static var isWidgetVisible: Bool {
        #if canImport(UIKit)
        return MainThread.sync { WidgetHolder.presentedContainer != nil }
        #else
        return false
        #endif
    }

    /// The conversation's last known ticket status (`"open"` / `"closed"`),
    /// nil before the page has reported one. Updated live and by
    /// `refresh()`; change notifications arrive via
    /// `ClarityListener.onTicketStatusChanged`.
    public static var currentTicketStatus: String? {
        #if canImport(UIKit)
        // Ungated like the other getters (see the type doc): pre-initialize
        // the engine has never seen a status report, so this is nil anyway.
        return MainThread.sync { controller.currentTicketStatus }
        #else
        return nil
        #endif
    }

    // MARK: - Notifications & badge

    /// APNs device token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// Forwarded lowercase-hex with `platform: "ios"`.
    public static func setDeviceToken(_ apnsToken: Data) {
        setDeviceToken(apnsToken.map { String(format: "%02x", $0) }.joined())
    }

    /// String overload for pre-formatted tokens (e.g. FCM-on-iOS setups).
    public static func setDeviceToken(_ token: String) {
        #if canImport(UIKit)
        onEngine { $0.setDeviceToken(token) }
        #endif
    }

    /// True when a remote-notification payload belongs to Clarity.
    public static func isClarityPush(userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[pushMarkerKey] as? String) == "true"
            || (userInfo[pushMarkerKey] as? Bool) == true
    }

    /// Handle a Clarity remote push by rendering it as the SDK's local
    /// notification. Returns false (untouched) for foreign payloads. Never
    /// throws into the host's push path.
    @discardableResult
    public static func handlePush(userInfo: [AnyHashable: Any]) -> Bool {
        guard isClarityPush(userInfo: userInfo) else { return false }
        #if canImport(UIKit)
        let body = (userInfo["body"] as? String) ?? ""
        NotificationHelper.showNewMessage(body)
        #endif
        return true
    }

    #if canImport(UIKit)
    /// Route a notification tap: when the response is Clarity's (the SDK's
    /// local "new message" notification), opens the widget and returns true.
    /// Forward from `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        // Two kinds of Clarity notification can be tapped: the SDK's own local
        // one (marker added by NotificationHelper) and a Clarity data push that
        // APNs displayed itself — that one arrives carrying only the push
        // marker, so matching the local marker alone would drop the tap.
        guard (userInfo[NotificationHelper.userInfoMarkerKey] as? Bool) == true
            || isClarityPush(userInfo: userInfo)
        else {
            return false
        }
        NotificationHelper.cancel()
        show()
        return true
    }
    #endif

    /// BINARY new-message flag: 1 while at least one unseen agent reply
    /// exists (widget hidden), 0 while the widget is open or nothing new
    /// arrived. Deliberately not a message count — use `onNewMessage` for
    /// per-message previews.
    public static var unreadCount: Int {
        #if canImport(UIKit)
        return MainThread.sync { controller.unreadCount }
        #else
        return 0
        #endif
    }

    // MARK: - Session

    /// Full logout: wipes the widget web session, resets the identity to
    /// anonymous and clears attributes, queued events and unread state.
    public static func resetSession() {
        #if canImport(UIKit)
        onEngine { $0.resetSession() }
        #endif
    }

    /// Single listener; the SDK keeps a STRONG reference (Android parity) —
    /// pass nil to clear. All callbacks arrive on the main thread.
    public static func setListener(_ listener: ClarityListener?) {
        #if canImport(UIKit)
        MainThread.run { controller.listener = listener }
        #endif
    }

    private static let pushMarkerKey = "clarity_push"
}
