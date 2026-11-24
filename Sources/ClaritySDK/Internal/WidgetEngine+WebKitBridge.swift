#if canImport(UIKit)
import UIKit
import AVFoundation
import WebKit

// The WebKit plumbing half of `WidgetEngine`: message-handler intake,
// navigation policy + failure classification, renderer-crash recovery and the
// target=_blank hand-off. Every debug string here is asserted by the e2e
// suite — keep them byte-identical through any restructuring.

// MARK: - WKScriptMessageHandler (page → native)

extension WidgetEngine: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == ClarityBridgeScript.handlerName,
              let raw = message.body as? String
        else { return }
        let source = message.webView
        // `webkit.messageHandlers.clarityBridge` is reachable from EVERY
        // frame, the chat's html-widget iframes included: only the main frame
        // at the widget's own origin is the live chat page
        // (`BridgeFrameFilter`). Read now — the frame info describes the
        // sender at the moment it posted.
        let frame = message.frameInfo
        let isMainFrame = frame.isMainFrame
        let origin = frame.securityOrigin
        let originProtocol = origin.protocol
        let originHost = origin.host
        let originPort = origin.port
        MainThread.run { [self] in
            // Only the engine's CURRENT WebView may drive the state machine:
            // a superseded or torn-down instance can still deliver queued
            // messages (most dangerously a late pageLoaded after a timeout,
            // which would flip a .failed engine back to .loaded).
            guard let source, source === webView else { return }
            guard BridgeFrameFilter.accepts(
                isMainFrame: isMainFrame,
                originProtocol: originProtocol,
                originHost: originHost,
                originPort: originPort,
                baseUrl: config?.baseUrl
            ) else {
                // The sender's origin is not a secret; the message is never
                // logged. A debug event, so the e2e suite can assert the drop.
                let sender = originProtocol.isEmpty
                    ? "an opaque origin"
                    : "\(originProtocol)://\(originHost)"
                debug(
                    "bridge: dropped a message from "
                        + (isMainFrame ? "a main frame" : "a subframe")
                        + " at \(sender)"
                )
                return
            }
            if let parsed = BridgeMessage.parse(raw) {
                handle(parsed)
            } else {
                ClarityLog.log(BridgeMessage.unparseableLogLine(raw))
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WidgetEngine: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Keep the widget origin inside the WebView; anything else (links in
        // messages, articles…) opens in the external browser. The rule itself
        // is `ExternalNavigationPolicy`, which is unit-tested — WKNavigationAction
        // cannot be built in a test, so only the unwrapping lives here.
        //
        // `targetFrame == nil` is a NEW WINDOW (target=_blank), which is a
        // link; a frame that exists and is not the main one is the page
        // loading its own content, which is not.
        let isSubframe = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false

        if let url = navigationAction.request.url,
           ExternalNavigationPolicy.shouldOpenExternally(
               url: url,
               baseUrl: config?.baseUrl,
               isSubframe: isSubframe
           ) {
            ExternalLinkOpener.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // The widget page itself answered an error status — fail fast with a
        // classified error instead of waiting for the pageLoaded timeout
        // (wrong baseUrl, broken deploy). Deliberately NOT
        // SessionAPI.rejectionStatusRange: that range exists to split
        // non-retryable 4xx from retryable 5xx during the handshake, while
        // here ANY error status — client or server — is equally terminal
        // for this navigation, so the plain HTTP error boundary is the
        // right test.
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            debug("nav: HTTP \(http.statusCode) for main frame \(redact(http.url))")
            if state == .loading {
                onPageFailed(
                    kind: .pageLoadFailed,
                    code: http.statusCode,
                    message: "widget page returned HTTP \(http.statusCode)"
                )
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        debug("nav: started \(redact(webView.url))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debug("nav: finished \(redact(webView.url))")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        // NSURLErrorCancelled fires for our own .cancel policy decisions.
        guard nsError.code != NSURLErrorCancelled else { return }
        debug("nav: error \(nsError.code) \(nsError.localizedDescription)")
        if state == .loading {
            onPageFailed(kind: .network, code: nsError.code, message: nsError.localizedDescription)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The OS killed the WebView's web content process (memory pressure or
        // crash). Without this handler the widget stays "LOADED" but renders
        // a permanently blank page — reset and warm up again instead.
        MainThread.run { [self] in
            // Inside the guard so a superseded instance dying quietly does
            // not log a recovery that never happens.
            guard webView === self.webView else { return }
            debug("render process gone — resetting widget")
            reportError(
                kind: .rendererCrashed,
                code: ClarityError.codeNone,
                message: "WebView renderer died — recovering automatically"
            )
            // The recovery reset must NOT eat a show the host already asked
            // for (Android field bug: recovery reloaded the page but never
            // presented). Stash the pending show across the reset. A crash
            // while the widget is ON SCREEN is the same case in disguise:
            // pendingShowMode is nil then (consumed at present) and the reset
            // force-closes the container — capture what was visible so the
            // recovery re-presents it instead of leaving the user staring at
            // a widget that silently vanished. The pinned show(from:)
            // presenter must survive the reset too, or the recovery would
            // re-present via the top-view-controller walk — in a multi-scene
            // app possibly in a different scene. For a crash while visible,
            // the container's presenting controller is the host VC that
            // originally presented it. Resolved BEFORE resetWebView: the
            // reset clears the pending fields and force-closes the container
            // these values are read from.
            let resume: (
                mode: PresentationMode, fraction: Double?,
                presenter: UIViewController?, log: String
            )?
            if let mode = pendingShowMode {
                resume = (
                    mode, pendingSheetFraction, pendingPresenter,
                    "render recovery: resuming pending show"
                )
            } else if let presented = WidgetHolder.presentedContainer
                as? ClarityWidgetViewController {
                resume = (
                    presented.presentationModeForRecovery,
                    presented.sheetHeightFractionForRecovery,
                    presented.presentingViewController,
                    "render recovery: re-presenting visible widget"
                )
            } else if let collapsed = collapsedCall {
                // A call collapsed to its bubble died with the page: the
                // chat it happened in comes back instead.
                resume = (
                    collapsed.mode, collapsed.fraction, collapsed.presenter,
                    "render recovery: re-presenting collapsed voice call"
                )
            } else {
                resume = nil
            }
            resetWebView()
            if let resume {
                debug(resume.log)
                pendingShowMode = resume.mode
                pendingSheetFraction = resume.fraction
                pendingPresenter = resume.presenter
                startLoading()
            } else {
                schedulePreloadIfEnabled()
            }
        }
    }
}

// MARK: - WKUIDelegate

extension WidgetEngine: WKUIDelegate {
    /// target=_blank etc. — route through the same foreign-host policy
    /// instead of spawning a child WebView.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, url.isWebLink {
            ExternalLinkOpener.open(url)
        }
        return nil
    }

    /// getUserMedia gate. Page code (current or future) requesting the
    /// camera/microphone in a host that lacks the matching usage description
    /// would TCC-kill the process exactly like the file-upload "Take Photo"
    /// path (see the airbag in `ClarityWidgetViewController.present`): denied
    /// up front, the page gets a catchable NotAllowedError. Otherwise the
    /// app's own permission decides (`MediaCapturePolicy`): WebKit's default
    /// asked the customer again on every page load, on top of the system
    /// prompt they had already answered.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let devices = MediaDevice.devices(for: type)
        let missing = devices.filter { !$0.provisioned }.map(\.usageKey)
        mediaRequestedSinceBubbleStart = true
        switch MediaCapturePolicy.verdict(
            missingUsageKeys: missing, permissions: devices.map(\.permission)
        ) {
        case .deny:
            if missing.isEmpty {
                debug("media capture denied: the app has no permission for it")
            } else {
                debug(
                    "media capture denied: \(missing.joined(separator: ", ")) "
                        + "missing from the host app Info.plist"
                )
            }
            decisionHandler(.deny)
        case .grant:
            decisionHandler(.grant)
        case .askSystem:
            awaitingMediaPermission = true
            MediaDevice.requestAll(devices) { [weak self] granted in
                self?.awaitingMediaPermission = false
                decisionHandler(granted ? .grant : .deny)
            }
        }
    }
}

/// One capture device the page asked for, as the app is provisioned and
/// permitted for it.
private enum MediaDevice {
    case microphone
    case camera

    static func devices(for type: WKMediaCaptureType) -> [MediaDevice] {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        // A capture type this SDK build doesn't know is still capture —
        // require full A/V rather than guessing it safe.
        case .cameraAndMicrophone: return [.camera, .microphone]
        @unknown default: return [.camera, .microphone]
        }
    }

    var usageKey: String {
        switch self {
        case .microphone: return HostCapabilities.microphoneUsageKey
        case .camera: return HostCapabilities.cameraUsageKey
        }
    }

    var provisioned: Bool {
        switch self {
        case .microphone: return HostCapabilities.microphoneCaptureProvisioned
        case .camera: return HostCapabilities.cameraCaptureProvisioned
        }
    }

    var permission: MediaCapturePolicy.SystemPermission {
        switch self {
        case .microphone:
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }
        }
    }

    /// The system prompt for each device not yet answered, one after the
    /// other; `done` on the main thread with whether all were allowed.
    static func requestAll(_ devices: [MediaDevice], done: @escaping (Bool) -> Void) {
        guard let first = devices.first else { return MainThread.run { done(true) } }
        let rest = Array(devices.dropFirst())
        first.request { granted in
            guard granted else { return MainThread.run { done(false) } }
            requestAll(rest, done: done)
        }
    }

    private func request(_ answer: @escaping (Bool) -> Void) {
        switch self {
        case .microphone:
            AVAudioSession.sharedInstance().requestRecordPermission(answer)
        case .camera:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: answer)
        }
    }
}

extension WidgetEngine {

    /// Query strings can carry the one-time token — or, for attachment URLs,
    /// signed access credentials — and the widget URL's fragment carries the
    /// identity token: never log either (`WidgetURL.redactedForLog`).
    /// Internal (not private to this file): the bridge-action logs in
    /// WidgetEngine.swift use it too.
    func redact(_ url: URL?) -> String {
        guard let url else { return "" }
        return WidgetURL.redactedForLog(url.absoluteString)
    }
}
#endif
