#if canImport(UIKit)
import UIKit
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
        MainThread.run { [self] in
            // Only the engine's CURRENT WebView may drive the state machine:
            // a superseded or torn-down instance can still deliver queued
            // messages (most dangerously a late pageLoaded after a timeout,
            // which would flip a .failed engine back to .loaded).
            guard let source, source === webView else { return }
            if let parsed = BridgeMessage.parse(raw) {
                handle(parsed)
            } else {
                ClarityLog.log("Failed to parse message: \(raw)")
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
        // messages, articles…) opens in the external browser. Compared as a
        // full origin — a bare host match would keep a port or scheme change
        // inside the WebView and replace the live conversation with it.
        // Host-less URLs (about:blank, data:) and an unparseable baseUrl fall
        // through to .allow, as before.
        if let url = navigationAction.request.url,
           url.host != nil,
           let widgetBase = config.flatMap({ URL(string: $0.baseUrl) }),
           widgetBase.isWebLink, widgetBase.host != nil,
           !url.isSameOrigin(as: widgetBase) {
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

    /// getUserMedia gate: page code (current or future) requesting the
    /// camera/microphone in a host that lacks the matching usage description
    /// would TCC-kill the process exactly like the file-upload "Take Photo"
    /// path (see the airbag in `ClarityWidgetViewController.present`). Deny
    /// up front when unprovisioned — the page gets a catchable
    /// NotAllowedError; defer to the system prompt only when the host
    /// carries the keys.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let required: [(key: String, provisioned: Bool)]
        switch type {
        case .camera:
            required = [(HostCapabilities.cameraUsageKey, HostCapabilities.cameraCaptureProvisioned)]
        case .microphone:
            required = [(HostCapabilities.microphoneUsageKey, HostCapabilities.microphoneCaptureProvisioned)]
        case .cameraAndMicrophone:
            required = [
                (HostCapabilities.cameraUsageKey, HostCapabilities.cameraCaptureProvisioned),
                (HostCapabilities.microphoneUsageKey, HostCapabilities.microphoneCaptureProvisioned),
            ]
        @unknown default:
            // A capture type this SDK build doesn't know is still capture —
            // require full A/V provisioning rather than guessing it safe.
            required = [
                (HostCapabilities.cameraUsageKey, HostCapabilities.cameraCaptureProvisioned),
                (HostCapabilities.microphoneUsageKey, HostCapabilities.microphoneCaptureProvisioned),
            ]
        }
        let missing = required.filter { !$0.provisioned }.map(\.key)
        guard missing.isEmpty else {
            debug(
                "media capture denied: \(missing.joined(separator: ", ")) "
                    + "missing from the host app Info.plist"
            )
            decisionHandler(.deny)
            return
        }
        decisionHandler(.prompt)
    }
}

extension WidgetEngine {

    private static let redactedURLPrefixLength = 160

    /// Query strings can carry the one-time token — or, for attachment URLs,
    /// signed access credentials — never log them. Internal (not private to
    /// this file): the bridge-action logs in WidgetEngine.swift use it too.
    func redact(_ url: URL?) -> String {
        guard let url else { return "" }
        let absolute = url.absoluteString
        let cut = absolute.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return String((cut.first ?? "").prefix(Self.redactedURLPrefixLength))
    }
}
#endif
