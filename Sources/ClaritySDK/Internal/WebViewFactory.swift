#if canImport(UIKit)
import ObjectiveC
import UIKit
import WebKit

/// Builds `WKWebViewConfiguration`s for the widget (and the image preview) so
/// every WebView shares the DEFAULT website data store — the conversation
/// session must survive app launches (Android parity: the process-wide
/// CookieManager), and the preview must load session-authenticated attachment
/// URLs with the chat's cookies. The data store is the whole mechanism: it is
/// what owns cookies and their persistence.
///
/// (There is deliberately no shared `WKProcessPool`. It carried nothing here —
/// as of iOS 15, our deployment floor, WebKit ignores it outright: "Creating
/// and using multiple instances of WKProcessPool no longer has any effect.")
///
/// The default store is shared with the host app's own WebViews, which is why
/// `WebSessionCleaner` only ever wipes data scoped to the widget's domain.
/// (`WKWebsiteDataStore(forIdentifier:)` would isolate us completely but is
/// iOS 17+ — revisit when the deployment floor rises.)
/// Main-thread confined by convention — see `MainThread`.
enum WebViewFactory {

    /// Configuration for the widget WebView: shared data store, the bridge
    /// user script, inline media, no user-gesture requirement for playback.
    static func widgetConfiguration(handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = baseConfiguration()
        configuration.userContentController.addUserScript(ClarityBridgeScript.userScript())
        configuration.userContentController.addUserScript(ViewportLockScript.userScript())
        configuration.userContentController.add(
            WeakScriptMessageProxy(target: handler),
            name: ClarityBridgeScript.handlerName
        )
        return configuration
    }

    /// Configuration without the bridge — used by the image preview, which
    /// has its own tiny reporter script but must share cookies/session.
    static func baseConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    static func makeWidgetWebView(handler: WKScriptMessageHandler) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: widgetConfiguration(handler: handler))
        // Transparent background: no white flash while the page paints.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // The edge swipe walks the page's history: an html screen opened over
        // the chat stands in it as one entry (the page pushes it when the
        // screen opens and collapses the screen when it is popped), so the
        // gesture leaves the screen the way it would in Safari. The page never
        // navigates otherwise — links open externally — so with no screen
        // open the swipe has nothing to do (Android parity: the back button
        // calls `goBack()` first).
        webView.allowsBackForwardNavigationGestures = true
        // The page scrolls natively; no rubber-band bounce at the edges of
        // the widget chrome (Android parity: OVER_SCROLL_NEVER).
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // The page is app-layout (body overflow:hidden): every scrollable
        // surface is an inner container that WebKit drives through child
        // scroll views. The DOCUMENT scroll view only ever moves as a WebKit
        // keyboard artifact (reveal-scroll + keyboard content inset), which
        // drags the chat header off-screen while typing — so document
        // scrolling is disabled outright. Inner scrolling is unaffected.
        webView.scrollView.isScrollEnabled = false
        removeSystemInputAccessory(from: webView)
        return webView
    }

    /// WebKit attaches the ▲▼/Done form-assistant bar above the keyboard for
    /// every web input — visibly non-native inside an app-like chat widget.
    /// There is no public switch; the long-established technique swaps the
    /// content view's class for a runtime subclass whose
    /// `inputAccessoryView` is nil (public ObjC runtime API only, widely
    /// shipped by chat SDKs). Fully defensive: when the content view isn't
    /// found the bar simply stays — nothing else changes.
    private static func removeSystemInputAccessory(from webView: WKWebView) {
        guard let target = webView.scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }) else { return }
        let baseClass: AnyClass = type(of: target)
        let subclassName = "ClarityNoInputAccessory_" + String(describing: baseClass)
        if let existing = NSClassFromString(subclassName) {
            object_setClass(target, existing)
            return
        }
        guard let subclass = objc_allocateClassPair(baseClass, subclassName, 0),
              let method = class_getInstanceMethod(
                  UIView.self, #selector(getter: UIResponder.inputAccessoryView))
        else { return }
        let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        class_addMethod(
            subclass,
            #selector(getter: UIResponder.inputAccessoryView),
            imp_implementationWithBlock(block),
            method_getTypeEncoding(method)
        )
        objc_registerClassPair(subclass)
        object_setClass(target, subclass)
    }
}
#endif
