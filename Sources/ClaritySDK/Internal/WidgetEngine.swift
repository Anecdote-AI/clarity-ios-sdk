#if canImport(UIKit)
import UIKit
import WebKit

/// Owns the widget WebView: performs the session handshake, pre-loads the
/// Live Chat page off-screen, gates presentation on the page reporting
/// `pageLoaded`, and keeps the warm instance cached between opens so the
/// conversation reopens instantly.
///
/// Port of the Android SDK's `WidgetWebViewController.kt` — behavioral rules,
/// state machine and debug-event strings are kept identical (the e2e suite
/// asserts on them).
///
/// MAIN-THREAD CONFINED: every entry point assumes it is already on the main
/// thread and does not hop again. `Clarity` performs the single
/// `MainThread.run` hop for all public calls, WebKit delivers its delegate
/// callbacks on main, and the bridge intake re-hops explicitly
/// (`WidgetEngine+WebKitBridge`). Only entry points with callers outside
/// that funnel keep their own wrapper (`setWidgetVisible`, the container
/// lifecycle callbacks). The handshake runs on a private serial queue (the
/// analog of Android's single-thread executor) and re-enters through
/// `MainThread.run`.
final class WidgetEngine: NSObject {

    enum State { case idle, loading, loaded, failed }

    private let sessionQueue = DispatchQueue(label: "com.onclarity.clarity.session")
    private let sessionApi = SessionAPI(log: ClarityLog.log)

    private(set) var config: ClarityConfig?

    var webView: WKWebView?
    var state: State = .idle
    /// Bumped on every reset, every new load, AND on load failure —
    /// `onPageFailed` bumps it so work still in flight for the failed load
    /// (most importantly a handshake outliving the page timeout) cannot
    /// resurrect it. Read (not written) by the presentation half: a reveal
    /// gate that outlives a reset must not present the WebView it captured.
    private(set) var loadGeneration = 0
    var pendingShowMode: PresentationMode?
    var pendingSheetFraction: Double?
    private let loadTimeoutWork = DebouncedWork()
    private let autoPreloadWork = DebouncedWork()

    /// In-flight `WebSessionCleaner` wipes. While non-zero, `startLoading` is
    /// deferred: a page booting over a half-deleted session can resurrect the
    /// previous user's conversation, and a deletion landing late can erase
    /// the replacement session mid-load. The wait is BOUNDED (`wipeFallbackWork`):
    /// WKWebsiteDataStore callbacks can starve entirely when the wipe starts
    /// with no live WebView on the store (e2e J1: updateConfig destroys the
    /// WebView, identify wipes right after — the completion never fired), and
    /// an unreleased deferral would otherwise disable the widget for good.
    private var webSessionWipesInFlight = 0
    private var loadDeferredByWipe = false
    private let wipeFallbackWork = DebouncedWork()

    /// Strong reference by design (Android parity — the SDK is the singleton).
    var listener: ClarityListener?

    private var user = ClarityUser()
    private var deviceToken: String?
    private var attributes: [AttributeScope: [String: ClarityAttributeValue]] = [:]
    private var pendingEvents: [String] = []

    /// True while the widget container is on screen.
    private var widgetVisible = false

    private(set) var unreadCount: Int = 0

    /// Last ticket status the page reported (`"open"` / `"closed"`), nil until
    /// the first report. User-scoped: cleared on identity switch and logout.
    private(set) var currentTicketStatus: String?

    /// Presenter the host pinned for a `show(from:)` that could not present
    /// immediately — staged with the pending show while the page loads,
    /// consumed when it presents, cleared with the rest of the triple by
    /// dismiss/reset. Never set on the `.loaded` fast path: the presenter
    /// goes straight into the presentation there, and a leftover assignment
    /// would leak into an unrelated later pageLoaded consume. Weak — the
    /// host owns its controllers.
    weak var pendingPresenter: UIViewController?

    // MARK: - Lifecycle

    func initialize(config: ClarityConfig) {
        self.config = config
        auditHostAppProvisioning()
        schedulePreloadIfEnabled()
    }

    /// One-time integration audit: surface every host-app misconfiguration
    /// that would crash or degrade the SDK, at the moment the integrator is
    /// looking (first init), through the standard debug channel. The list is
    /// the enforcement point of the "never crash the host app" principle —
    /// any new feature that touches a privacy-gated or otherwise
    /// host-provisioned OS capability must add its check here alongside its
    /// runtime guard.
    private var didAuditHostApp = false
    private func auditHostAppProvisioning() {
        guard !didAuditHostApp else { return }
        didAuditHostApp = true
        if !HostCapabilities.cameraCaptureProvisioned {
            debug(
                "audit: \(HostCapabilities.cameraUsageKey) missing from the host "
                    + "app Info.plist — the attachment picker's Take Photo option "
                    + "will be blocked (add the key to enable camera capture)"
            )
        }
    }

    /// Warm up automatically shortly after init/identify so the first open is
    /// instant without the host app calling `preload()`. Delayed so it never
    /// competes with app-startup work; re-scheduling debounces rapid calls.
    func schedulePreloadIfEnabled() {
        // Cancel FIRST: an updateConfig that turns autoPreload off inside the
        // debounce window must not leave the already-queued item to fire and
        // load the page anyway.
        autoPreloadWork.cancel()
        guard let config, config.autoPreload else { return }
        autoPreloadWork.schedule(after: Self.autoPreloadDelay) { [weak self] in
            guard let self else { return }
            // .idle only — deliberately narrower than preload()/show(): a
            // .failed load must not auto-retry (failure loop); only an
            // explicit call may retry from .failed.
            if self.state == .idle { self.startLoading() }
        }
    }

    func updateConfig(_ config: ClarityConfig) {
        guard self.config != config else { return }
        // A config that points at a different org/channel/stand starts a
        // different conversation — the cached status would otherwise keep
        // reporting the previous one's state until the new page happens
        // to emit a status. Presentation-only updates keep it.
        let identityChanged = self.config.map {
            $0.organizationId != config.organizationId
                || $0.integrationKey != config.integrationKey
                || $0.baseUrl != config.baseUrl
                || $0.appId != config.appId
        } ?? false
        self.config = config
        if identityChanged {
            currentTicketStatus = nil
        }
        resetWebView()
        schedulePreloadIfEnabled()
    }

    // MARK: - Public operations

    /// Pre-load the widget page off-screen so `show` presents instantly.
    func preload() {
        if state == .idle || state == .failed { startLoading() }
    }

    func show(
        mode: PresentationMode,
        sheetHeightFraction: Double?,
        presenter: UIViewController? = nil
    ) {
        switch state {
        case .loaded:
            presentContainer(
                mode: mode, sheetHeightFraction: sheetHeightFraction, presenter: presenter
            )
        case .loading:
            pendingShowMode = mode
            pendingSheetFraction = sheetHeightFraction
            pendingPresenter = presenter
        case .idle, .failed:
            pendingShowMode = mode
            pendingSheetFraction = sheetHeightFraction
            pendingPresenter = presenter
            startLoading()
        }
    }

    func dismiss() {
        WidgetHolder.closeRequested = true
        // A show that is still loading is CANCELLED, not deferred: the
        // latch alone would not survive, because presentContainer clears it
        // ("a new presentation supersedes a stale close") and onPageLoaded
        // would then present the widget the host already dismissed — over
        // whatever screen the user navigated to instead.
        clearPendingShow()
    }

    /// Drop a staged show: mode, sheet fraction and pinned presenter always
    /// travel (and die) together — clearing only part of the triple would
    /// let a later show present with another request's leftovers.
    private func clearPendingShow() {
        pendingShowMode = nil
        pendingSheetFraction = nil
        pendingPresenter = nil
    }

    /// The staged show as one value, cleared atomically on read — the
    /// pageLoaded consumer must never observe a half-cleared triple.
    private func consumePendingShow()
        -> (mode: PresentationMode, fraction: Double?, presenter: UIViewController?)? {
        guard let mode = pendingShowMode else { return nil }
        let staged = (mode, pendingSheetFraction, pendingPresenter)
        clearPendingShow()
        return staged
    }

    /// Set the user identity. Identity is bound to the widget session when the
    /// page loads, so call this before `show`/`preload`. Switching to a
    /// DIFFERENT `externalId` (or dropping it) is treated as logout+login: the
    /// previous user's widget session (cookies + origin storage) is wiped and
    /// the next load starts fresh. Re-identifying the SAME `externalId` with
    /// changed profile fields is an update, not an account switch — the
    /// session and the conversation survive.
    func identify(_ user: ClarityUser) {
        guard self.user != user else { return }
        let previous = self.user
        self.user = user
        if previous.requiresSessionIsolation(switchingTo: user) {
            debug("identify: identity switched — clearing widget web session")
            wipeUserSession()
        } else if previous != ClarityUser() {
            // Same identity key (a profile update), or an anonymous
            // session gaining an identity (the platform merges the
            // visitor into the identified user) — wiping here would log
            // the same person out and orphan their conversation.
            debug("identify: no account switch — keeping widget web session")
        }
        if state != .idle {
            resetWebView()
        }
        schedulePreloadIfEnabled()
    }

    /// Long-lived attributes of the person (merged into the contact).
    func setUserAttributes(_ attributes: [String: ClarityAttributeValue]) {
        setAttributes(attributes, scope: .user)
    }

    /// Context for the NEXT ticket created in this session (e.g. order_id).
    func setTicketAttributes(_ attributes: [String: ClarityAttributeValue]) {
        setAttributes(attributes, scope: .ticket)
    }

    /// One pipeline for both scopes: store, and forward when the page is up
    /// (a fresh page re-receives everything in the pageLoaded flush).
    private func setAttributes(
        _ new: [String: ClarityAttributeValue], scope: AttributeScope
    ) {
        // Non-finite doubles are not JSON — one NaN would make the
        // serializers silently drop the WHOLE dictionary (URL and bridge
        // both), losing every other attribute in the call.
        let sanitized = ClarityAttributeValue.droppingNonFiniteValues(new)
        attributes[scope] = sanitized
        if state == .loaded {
            sendMessageToWebView(OutboundMessage.setAttributes(sanitized, scope: scope))
            if scope == .ticket {
                // Handed off: the platform stages ticket context on the
                // session and consumes it into exactly ONE ticket. Keeping
                // a local copy would re-stage the already-consumed context
                // on the next page rebuild (renderer recovery,
                // updateConfig), leaking it into a later ticket.
                attributes[.ticket] = nil
            }
        }
    }

    /// Product event for automations / AI context; queued until the page loads.
    func logEvent(name: String, params: [String: String]) {
        let message = OutboundMessage.logEvent(name: name, params: params)
        if state == .loaded {
            sendMessageToWebView(message)
        } else {
            pendingEvents.append(message)
            if pendingEvents.count > Self.maxPendingEvents {
                pendingEvents.removeFirst()
            }
        }
    }

    /// APNs device token of THIS device. Forwarded to the widget page, which
    /// registers it against the session-authenticated customer — the backend
    /// can then target agent replies at it while the app is backgrounded.
    func setDeviceToken(_ token: String) {
        guard deviceToken != token else { return }
        deviceToken = token
        if state == .loaded { sendDeviceTokenToWebView() }
    }

    private func sendDeviceTokenToWebView() {
        guard let token = deviceToken else { return }
        sendMessageToWebView(OutboundMessage.setDeviceToken(token))
    }

    /// Host-requested on-demand sync of the latest ticket state. Warm page:
    /// ask it to refetch the conversation — anything new flows through the
    /// normal reporting path (unread flag, onNewMessage, notification). Cold
    /// engine: warm up; the page's boot fetch establishes the fresh state.
    func refreshConversation() {
        switch state {
        case .loaded:
            sendMessageToWebView(OutboundMessage.refreshConversation())
        case .idle, .failed:
            startLoading()
        case .loading:
            break // the boot fetch is already about to deliver everything
        }
    }

    /// Called by the widget container; mirrored to the page for unread logic.
    func setWidgetVisible(_ visible: Bool) {
        MainThread.run { [self] in
            widgetVisible = visible
            if visible {
                resetUnreadState()
            }
            sendMessageToWebView(OutboundMessage.widgetVisibilityChanged(visible: visible))
        }
    }

    /// Drop the cached WebView and clear widget cookies + storage, ending the
    /// current visitor session (e.g. on logout).
    func resetSession() {
        user = ClarityUser()
        wipeUserSession()
        resetWebView()
    }

    /// The logout-equivalent wipe shared by the identity switch and
    /// `resetSession`. Cookies and origin storage still hold the PREVIOUS
    /// user's widget session; a fresh page booting over them can resurrect
    /// that session, leaving the new user riding a websocket bound to the
    /// old one — agent replies then never reach the device. Attributes and
    /// queued events are user-scoped too — without clearing them, user B's
    /// first session would carry user A's contact and ticket context. Same
    /// for the externally visible unread surfaces (host badge callback,
    /// posted notification), which may still show user A's state.
    private func wipeUserSession() {
        clearWebSession()
        clearUserScopedState()
        resetUnreadState()
    }

    /// Attributes, queued events and the ticket status are user-scoped —
    /// never carried across an identity change or logout.
    private func clearUserScopedState() {
        attributes = [:]
        pendingEvents.removeAll()
        currentTicketStatus = nil
    }

    /// Zero every externally visible unread surface: the counter, the posted
    /// notification and the host badge callback.
    private func resetUnreadState() {
        unreadCount = 0
        NotificationHelper.cancel()
        notify { $0.onUnreadCountChanged(0) }
    }

    // MARK: - Web session wipe

    /// Wipe the widget's web session: cookies, caches, and origin storage —
    /// scoped to the widget's domains only (the default data store is shared
    /// with the host app's own web content). Ends the current visitor session
    /// so the next page load starts fresh instead of resurrecting the
    /// previous user.
    private func clearWebSession() {
        guard let config else { return }
        beginWipe()
        WebSessionCleaner.clear(baseUrl: config.baseUrl) { [weak self] in
            self?.endWipe()
        }
        // Belt-and-braces for the currently loaded document; the native wipe
        // above covers persisted storage even when no page is loaded.
        webView?.evaluateJavaScript(
            "try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}",
            completionHandler: nil
        )
    }

    /// Count an asynchronous wipe in, so a load requested while it runs
    /// waits for the completion (see `startLoading`). The counter (not a
    /// flag) keeps overlapping wipes honest: only the LAST completion may
    /// release a deferred load. The wait is bounded: when WebKit never calls
    /// back (see the property doc), degrade to the pre-deferral behavior —
    /// load anyway — instead of hanging the widget forever. Re-scheduling
    /// debounces, so the cap covers the latest of overlapping wipes.
    private func beginWipe() {
        webSessionWipesInFlight += 1
        wipeFallbackWork.schedule(after: Self.maxSessionWipeWait) { [weak self] in
            guard let self, self.webSessionWipesInFlight > 0 else { return }
            self.debug(
                "session wipe still running after "
                    + "\(Int(Self.maxSessionWipeWait))s — releasing the deferred load"
            )
            self.webSessionWipesInFlight = 0
            self.releaseLoadDeferredByWipe()
        }
    }

    /// One wipe completed. The fallback may have zeroed the counter already —
    /// a late completion must not drive it negative or double-release.
    private func endWipe() {
        webSessionWipesInFlight = max(0, webSessionWipesInFlight - 1)
        guard webSessionWipesInFlight == 0 else { return }
        wipeFallbackWork.cancel()
        releaseLoadDeferredByWipe()
    }

    private func releaseLoadDeferredByWipe() {
        guard loadDeferredByWipe else { return }
        loadDeferredByWipe = false
        startLoading()
    }

    func resetWebView() {
        loadTimeoutWork.cancel()
        loadGeneration += 1
        clearPendingShow()
        // A reset supersedes any load a still-running wipe was holding back;
        // whoever needs the next load re-requests it (show/preload/schedule).
        loadDeferredByWipe = false
        let dying = webView
        webView = nil
        state = .idle
        WidgetHolder.closeRequested = false
        if let dying { teardownWebViewInstance(dying) }
    }

    /// Detach and destroy one WebView instance: close the container if it is
    /// the presented one, unhook delegates and the bridge, drop the holder
    /// references. Shared by `resetWebView` and the failed-load teardown.
    private func teardownWebViewInstance(_ dying: WKWebView) {
        if WidgetHolder.warmWebView === dying { WidgetHolder.warmWebView = nil }
        // Never drop a WebView that is still presented without closing
        // the widget UI first — the visible container would keep
        // rendering a dead view.
        if WidgetHolder.presentedWebView === dying {
            WidgetHolder.presentedWebView = nil
            (WidgetHolder.presentedContainer as? ClarityWidgetViewController)?
                .forceCloseForReset()
        }
        dying.stopLoading()
        dying.configuration.userContentController
            .removeScriptMessageHandler(forName: ClarityBridgeScript.handlerName)
        dying.navigationDelegate = nil
        dying.uiDelegate = nil
        WarmupHost.detach(dying)
        dying.removeFromSuperview()
    }

    // MARK: - Loading

    func startLoading() {
        guard let config else { return }
        // A session wipe is still deleting cookies/storage — loading now
        // would race it (resurrected old session, or the new one erased
        // mid-boot). Defer; the wipe's completion re-invokes us. Any
        // pendingShowMode set by show() survives the deferral.
        guard webSessionWipesInFlight == 0 else {
            loadDeferredByWipe = true
            return
        }
        state = .loading
        loadGeneration += 1
        let generation = loadGeneration

        let webView: WKWebView
        if let existing = self.webView {
            webView = existing
        } else {
            webView = WebViewFactory.makeWidgetWebView(handler: self)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            self.webView = webView
            WidgetHolder.warmWebView = webView
        }
        // The page only reports pageLoaded from inside a rAF, which WebKit
        // suspends while the WebView is windowless — host it off-screen for
        // the whole load (no-op when already presented).
        WarmupHost.attach(webView)

        // The pageLoaded timeout starts when the page NAVIGATION starts (in
        // finishHandshake) — not here. The handshake has its own bounded
        // retry budget (3 × 10 s + backoff) that can legitimately exceed
        // loadTimeout, and it reports its own failure; arming the page timer
        // over it reported PAGE_LOAD_FAILED for a handshake still running.
        let appId = config.appId ?? Bundle.main.bundleIdentifier ?? "unknown"
        let base = WidgetURL.trimTrailingSlashes(config.baseUrl)
        debug(
            "handshake: GET \(base)\(SessionAPI.unverifiedSessionPath)"
                + " (appId=\(appId), origin=\(config.channelHost ?? "-"))"
        )

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let token = self.sessionApi.fetchOneTimeToken(config: config, appId: appId)
            let lastHttpCode = self.sessionApi.lastHttpCode
            let lastError = self.sessionApi.lastError
            MainThread.run { [weak self] in
                self?.finishHandshake(
                    generation: generation,
                    config: config,
                    webView: webView,
                    token: token,
                    lastHttpCode: lastHttpCode,
                    lastError: lastError
                )
            }
        }
    }

    /// Main-thread continuation of `startLoading` after the background
    /// handshake. The generation guard MUST stay the first statement — a
    /// reset/identity switch mid-handshake invalidates this load.
    private func finishHandshake(
        generation: Int,
        config: ClarityConfig,
        webView: WKWebView,
        token: String?,
        lastHttpCode: Int?,
        lastError: String?
    ) {
        guard generation == loadGeneration else { return }
        if let token {
            debug("handshake: ok, loading widget page")
            let urlString = WidgetURL.build(
                config: config,
                user: user,
                userAttributes: attributes[.user] ?? [:],
                ticketAttributes: attributes[.ticket] ?? [:],
                oneTimeToken: token
            )
            if let url = URL(string: urlString) {
                scheduleTimeout()
                webView.load(URLRequest(url: url))
            } else {
                onPageFailed(
                    kind: .internalError,
                    code: ClarityError.codeNone,
                    message: "invalid widget URL"
                )
            }
        } else {
            onPageFailed(
                kind: .forHandshakeFailure(lastHttpCode: lastHttpCode),
                code: lastHttpCode ?? ClarityError.codeNoHTTPResponse,
                message: "Session handshake failed: \(lastError ?? "unknown error")"
            )
        }
    }

    private func onPageLoaded() {
        guard state != .loaded else { return }
        loadTimeoutWork.cancel()
        state = .loaded
        debug("page: loaded, widget ready")
        for scope in AttributeScope.allCases {
            if let stored = attributes[scope], !stored.isEmpty {
                sendMessageToWebView(OutboundMessage.setAttributes(stored, scope: scope))
            }
        }
        // Ticket context is consumed by exactly one ticket server-side; see
        // setAttributes — a re-flush on the next page rebuild would re-stage it.
        attributes[.ticket] = nil
        pendingEvents.forEach { sendMessageToWebView($0) }
        pendingEvents.removeAll()
        sendDeviceTokenToWebView()
        if let show = consumePendingShow() {
            presentContainer(
                mode: show.mode, sheetHeightFraction: show.fraction, presenter: show.presenter
            )
        } else {
            // The page badge store boots assuming the widget is visible (the
            // web-embed reality). A preloaded-but-never-shown page must learn
            // it is hidden, or agent replies arriving before the first open
            // would be treated as seen — no unread callback, no notification.
            // Sent after the flush: by pageLoaded the page has folded the
            // initial history into its seen boundary, so only genuinely new
            // replies count. containerDidAppear posts `true` on real opens.
            if !widgetVisible {
                sendMessageToWebView(OutboundMessage.widgetVisibilityChanged(visible: false))
            }
            if let webView {
                // Warm and idle: back to windowless. Websocket delivery is
                // event-driven and works without a window; only the rAF-bound
                // phases (load, reveal gate) need one.
                WarmupHost.detach(webView)
            }
        }
    }

    func onPageFailed(kind: ClarityError.Kind, code: Int, message: String) {
        ClarityLog.log("Widget failed to load: \(code) \(message)")
        debug("failed: \(code) \(message)")
        loadTimeoutWork.cancel()
        // Failure is TERMINAL for this load generation: without the bump, work
        // still in flight for it — most importantly a handshake that outlives
        // the page-load timeout — passes finishHandshake's generation guard and
        // loads the page into a failed engine, so the host gets onWidgetFailed
        // and then a silently loaded widget it was never told about. Only an
        // explicit show/preload starts the next generation.
        loadGeneration += 1
        state = .failed
        pendingShowMode = nil
        // The failed document is DISCARDED, not parked: WebKit does not abort
        // a timed-out load, so the instance can still fire pageLoaded later —
        // from .failed that message would flip the engine back to .loaded,
        // and a retrying show() reusing the instance would present the stale
        // document before its fresh handshake lands. A retry builds a new
        // WebView instead.
        if let dying = webView {
            webView = nil
            teardownWebViewInstance(dying)
        }
        notify { $0.onWidgetFailed(code: code, message: message) }
        reportError(kind: kind, code: code, message: message)
    }

    private func scheduleTimeout() {
        guard let config else { return }
        // NaN/±inf/non-positive would break the dispatch deadline arithmetic
        // and leave a never-finishing load stuck in .loading with no
        // onWidgetFailed — normalize like the sheet fraction is normalized.
        let timeout = config.loadTimeout.isFinite && config.loadTimeout > 0
            ? config.loadTimeout
            : ClarityConfig.defaultLoadTimeout
        loadTimeoutWork.schedule(after: timeout) { [weak self] in
            guard let self else { return }
            if self.state == .loading {
                self.onPageFailed(
                    kind: .pageLoadFailed,
                    code: ClarityError.codePageLoadTimeout,
                    message: "Timed out waiting for pageLoaded"
                )
            }
        }
    }

    // MARK: - Bridge actions

    func handle(_ message: BridgeMessage) {
        switch message {
        case .pageLoaded:
            onPageLoaded()
        case .pageLoadedError(let code, let message):
            onPageFailed(kind: .pageLoadFailed, code: code, message: message)
        case .contentHeightDidChange:
            // Browser-iframe sizing message; parsed so it never logs as
            // unknown, deliberately ignored in native mode.
            break
        case .close:
            // The page ✕. Unlike the host's dismiss(), this does NOT cancel a
            // pending show — and cannot race one: a pending show exists only
            // while the page is still loading, no user-facing ✕ exists before
            // pageLoaded, and the bridge intake drops messages from
            // superseded WebViews. By the time a page can send .close, the
            // pending-show triple is already consumed; the latch is enough.
            WidgetHolder.closeRequested = true
        case .newMessage(let text):
            notify { $0.onNewMessage(text) }
            if !widgetVisible {
                NotificationHelper.showNewMessage(text)
            }
        case .unreadCountDidChange(let count):
            unreadCount = count
            notify { $0.onUnreadCountChanged(count) }
        case .ticketStatusChanged(let status):
            currentTicketStatus = status
            debug("ticket status: \(status)")
            notify { $0.onTicketStatusChanged(status) }
        case .openImage(let url):
            openImagePreview(url)
        case .openLink(let url):
            openExternalLink(url)
        case .unknown(let action):
            ClarityLog.log("Unknown action: \(action)")
        }
    }

    /// The page asked to preview an image attachment (tap on a thumbnail) —
    /// present the native full-screen viewer over the widget container.
    private func openImagePreview(_ url: String) {
        guard let parsed = URL(string: url), parsed.isWebLink else { return }
        // Redacted: attachment URLs can carry signed query credentials, and
        // debug() fans out to NSLog and the host's onDebugEvent.
        debug("openImage: \(redact(parsed))")
        guard let presenter = WidgetHolder.presentedContainer ?? TopViewController.find() else {
            debug("openImage: no view controller to present from")
            return
        }
        let preview = ImagePreviewViewController(imageUrl: url)
        WidgetHolder.presentedPreview = preview
        presenter.present(preview, animated: true)
    }

    /// Open a message/article link in the external browser. The page renders
    /// links as click handlers and never navigates itself, so this bridge
    /// action is the ONLY way link taps leave the widget in native mode.
    private func openExternalLink(_ url: String) {
        guard let parsed = URL(string: url), parsed.isWebLink else { return }
        // Redacted like every other URL log (query strings can carry tokens).
        debug("link: opening \(redact(parsed)) externally")
        ExternalLinkOpener.open(parsed)
    }

    private func sendMessageToWebView(_ message: String) {
        guard let webView else { return }
        // The page opts in by assigning ClarityBridge.onMessage (same pattern
        // as the Android SDK); silently skip when it has not.
        let js = "if (typeof window.ClarityBridge.onMessage === 'function') "
            + "window.ClarityBridge.onMessage(\(JSONEncoding.javaScriptStringLiteral(message)))"
        // Action name + allowlisted SDK-generated fields only — the payloads
        // carry the APNs device token, the host's attribute values and event
        // params, and this log line lands in the device console (and any
        // sysdiagnose collected from it).
        ClarityLog.log(
            "Sending message to WebView: "
                + OutboundMessage.loggableSummary(ofPayload: message)
        )
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Safety net

    /// Host-listener dispatch. Swift cannot catch a crashing host closure the
    /// way Kotlin catches Throwable — the guarantee here is that all
    /// SDK-internal failure paths report through `onError` instead of
    /// trapping, and every callback arrives on the main thread.
    func notify(_ block: @escaping (ClarityListener) -> Void) {
        guard let listener else { return }
        MainThread.run { block(listener) }
    }

    func reportError(kind: ClarityError.Kind, code: Int, message: String) {
        let error = ClarityError(kind: kind, code: code, message: message)
        notify { $0.onError(error) }
    }

    func debug(_ message: String) {
        ClarityLog.log(message)
        notify { $0.onDebugEvent(message) }
    }

    private static let autoPreloadDelay: TimeInterval = 1.5
    private static let maxPendingEvents = 50
    /// Cap on how long a load waits for an in-flight session wipe. Real wipes
    /// complete in milliseconds; this only fires when WebKit's data-store
    /// callbacks starve (no live WebView on the store).
    private static let maxSessionWipeWait: TimeInterval = 3.0
}

#endif
