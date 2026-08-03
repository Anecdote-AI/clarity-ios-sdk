#if canImport(UIKit)
import Foundation
import WebKit

/// Stage 2 of the two-stage reveal (iOS analog of Android's
/// `postVisualStateCallback` gate): after the page's `pageLoaded` claim,
/// wait one requestAnimationFrame pair so presentation slides in painted
/// pixels — bounded, because rAF can be throttled for a windowless WebView.
/// The completion always fires exactly once, on the main thread.
enum RevealGate {

    static func awaitFirstFrame(
        of webView: WKWebView,
        timeout: TimeInterval,
        completion: @escaping () -> Void
    ) {
        var completed = false
        let complete = {
            guard !completed else { return }
            completed = true
            completion()
        }

        let cap = DebouncedWork()
        cap.schedule(after: timeout) { complete() }

        let js = "new Promise(function (resolve) {"
            + " requestAnimationFrame(function () {"
            + " requestAnimationFrame(function () { resolve(true); });"
            + " });"
            + " })"
        webView.callAsyncJavaScript(
            "return await \(js);",
            arguments: [:],
            in: nil,
            in: .page
        ) { _ in
            DispatchQueue.main.async {
                cap.cancel()
                complete()
            }
        }
    }
}
#endif
