#if canImport(UIKit)
import Foundation
import WebKit

/// The JS bridge between the widget page and the SDK.
///
/// Page → native: the page calls `window.ClarityBridge.postMessage(json)`.
/// `window.ClarityBridge` is a page-world shim injected at document start —
/// a plain page-owned object forwarding to the real WebKit message handler.
/// The shim exists because the page also assigns `ClarityBridge.onMessage`
/// for the native→page direction, and expando properties on the WebKit-native
/// `webkit.messageHandlers.clarityBridge` proxy are not reliable (wrapper
/// lifetime/extensibility are not contractual). With the shim, the page's
/// resolver `window.ClarityBridge ?? webkit.messageHandlers.clarityBridge`
/// finds our object first — byte-identical behavior to the Android SDK.
enum ClarityBridgeScript {

    /// WKUserContentController message-handler name. Must be exactly this —
    /// the page's fallback resolver looks up `webkit.messageHandlers.clarityBridge`.
    static let handlerName = "clarityBridge"

    /// Injected at .atDocumentStart, main frame only.
    static let source = """
    window.ClarityBridge = {
        postMessage: function (m) {
            window.webkit.messageHandlers.\(handlerName).postMessage(m);
        }
    };
    """

    static func userScript() -> WKUserScript {
        mainFrameScript(source, at: .atDocumentStart)
    }
}

/// Both SDK scripts target the main frame only; injection time is the only knob.
private func mainFrameScript(
    _ source: String,
    at injectionTime: WKUserScriptInjectionTime
) -> WKUserScript {
    WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: true)
}

/// Pins the page's viewport scale to 1. WebKit auto-zooms the whole page
/// when a focused form control's font-size computes below 16px, leaving the
/// widget scaled and scrollable in both axes. The page fixes its inputs on
/// touch devices (live-chat `global.scss`), but the SDK must stay correct
/// against already-deployed page versions — so the viewport is locked
/// host-side too. `.atDocumentEnd` so it wins over the page's own meta;
/// WebKit honors dynamic viewport-meta changes.
enum ViewportLockScript {

    static let source = """
    (function () {
        try {
            var meta = document.querySelector('meta[name="viewport"]');
            if (!meta) {
                meta = document.createElement('meta');
                meta.setAttribute('name', 'viewport');
                (document.head || document.documentElement).appendChild(meta);
            }
            meta.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover');
        } catch (e) {}
    })();
    """

    static func userScript() -> WKUserScript {
        mainFrameScript(source, at: .atDocumentEnd)
    }
}

/// `WKUserContentController` retains its message handlers; registering the
/// engine directly would create a webView → controller → webView cycle that
/// leaks the warm WebView on reset. The proxy holds the engine weakly and is
/// itself removed in `resetWebView`.
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
#endif
