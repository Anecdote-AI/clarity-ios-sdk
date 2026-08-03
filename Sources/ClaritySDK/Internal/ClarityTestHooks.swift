#if canImport(UIKit)
import UIKit
import WebKit

/// Internal seams for the hosted e2e suite (reached via `@testable import`).
/// The iOS counterpart of the Android suite's access to `WebViewHolder`:
/// the ONLY place tests touch SDK internals — every product flow goes
/// through the public `Clarity` API.
enum ClarityTestHooks {

    /// The engine's live WebView — may still be loading (forensics on pages
    /// that never reached `pageLoaded`).
    static var warmWebView: WKWebView? { WidgetHolder.warmWebView }

    /// The WebView currently presented inside the widget container.
    static var presentedWebView: WKWebView? { WidgetHolder.presentedWebView }

    /// The native image preview currently presented, if any.
    static var presentedImagePreview: UIViewController? { WidgetHolder.presentedPreview }

    /// The widget container view controller currently presented, if any —
    /// the crash-safety suite presents picker doubles through it to pin the
    /// camera-capture airbag.
    static var presentedWidgetContainer: UIViewController? { WidgetHolder.presentedContainer }

    /// Replace how "open externally" URLs are handled; nil restores the
    /// production UIApplication.open. The e2e suite records the URL instead —
    /// actually launching Safari would background the host app mid-test.
    static func setExternalLinkHandler(_ handler: ((URL) -> Void)?) {
        ExternalLinkOpener.handler = handler ?? ExternalLinkOpener.defaultHandler
    }

    /// The robot's JS entry point: presented view first, warm view as the
    /// fallback (exactly WidgetRobot.kt's `webView ?: warmWebView` order).
    static func evaluateJavaScript(
        _ script: String,
        completion: @escaping (Result<Any?, Error>) -> Void
    ) {
        guard let webView = WidgetHolder.presentedWebView ?? WidgetHolder.warmWebView else {
            completion(.failure(NSError(
                domain: "ClarityTestHooks",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No widget WebView is live"]
            )))
            return
        }
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(value))
            }
        }
    }
}
#endif
