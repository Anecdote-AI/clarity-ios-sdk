#if canImport(UIKit)
import UIKit
import WebKit

/// Shared handles between the widget engine, the presented container and the
/// hosted e2e suite. Port of Android's `WebViewHolder`.
///
/// `closeRequested` is deliberately shared, observable STATE rather than a
/// transient event: on Android, three separate bugs were traced to one-shot
/// close events (a close issued between a present and the container's
/// appearance was consumed by the outgoing surface and lost; a reveal-side
/// state flip cancelled an in-flight dismissal; a stale close insta-closed
/// the next show). The latch is set by every close source, cleared by a new
/// presentation (last command wins) and after a completed dismissal.
///
/// Main-thread confined by convention — see `MainThread`.
enum WidgetHolder {

    /// The controller's live WebView — may still be loading. Diagnostics and
    /// the e2e robot read it to inspect a page that never reached pageLoaded.
    static weak var warmWebView: WKWebView?

    /// The WebView currently presented inside the widget container, if any.
    static weak var presentedWebView: WKWebView?

    /// The container currently on screen (weak — UIKit owns presentation).
    static weak var presentedContainer: UIViewController?

    /// The native image preview currently on screen, if any (weak).
    static weak var presentedPreview: UIViewController?

    /// The global close latch. Observers fire on every transition to `true`.
    static var closeRequested = false {
        didSet {
            guard closeRequested, !oldValue else { return }
            closeObserver?()
        }
    }

    private static var closeObserver: (() -> Void)?

    /// The presented container registers a single observer for its lifetime;
    /// re-registration replaces the previous container's observer.
    static func setCloseObserver(_ observer: (() -> Void)?) {
        closeObserver = observer
    }
}
#endif
