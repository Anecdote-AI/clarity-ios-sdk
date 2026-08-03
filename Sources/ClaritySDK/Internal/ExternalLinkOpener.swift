#if canImport(UIKit)
import UIKit

/// Single exit point for "open this URL outside the widget". Production
/// behavior is UIApplication.open; the hosted e2e suite replaces the handler
/// through ClarityTestHooks — on iOS actually launching Safari would
/// BACKGROUND the host app mid-test (Android's ACTION_VIEW keeps the
/// instrumented process foreground, so its suite never needed this seam).
/// Main-thread confined by convention — see `MainThread`.
enum ExternalLinkOpener {

    static let defaultHandler: (URL) -> Void = { url in
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    static var handler: (URL) -> Void = defaultHandler

    static func open(_ url: URL) {
        handler(url)
    }
}
#endif
