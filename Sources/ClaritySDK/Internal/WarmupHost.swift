#if canImport(UIKit)
import UIKit
import WebKit

/// Keeps a loading WebView attached to a window, entirely off-screen.
///
/// WebKit suspends `requestAnimationFrame` for a WKWebView that is not in any
/// window, and the live-chat page reports `pageLoaded` from inside a double
/// rAF after authentication (`App.tsx` native-mode effect) — so a fully
/// detached load would NEVER reach `pageLoaded`, and reveal gating (present
/// only after `pageLoaded`) would dead-lock every open. Android's detached
/// WebView keeps firing rAF, which is why the same page works there; this
/// host is the iOS-only counterpart.
///
/// The host view sits fully outside the window's bounds, swallows no touches
/// and is invisible to accessibility — WebKit's page-visibility check only
/// cares about window attachment, not geometry. The WebView is hosted while
/// a load is in flight and again for the pre-present reveal gate; once warm
/// and idle it goes back to windowless (the page's websocket delivery is
/// event-driven and does not need rAF), so no display work leaks into the
/// host app's steady state.
///
/// Main-thread confined by convention — see `MainThread`.
enum WarmupHost {

    private static var host: UIView?
    private static var windowObserver: NSObjectProtocol?

    /// Two window-heights above the top edge (one would put the host's
    /// bottom exactly AT the edge — a rounding error or transform away from
    /// leaking a visible line); the `max(…, 1)` floor keeps the offset
    /// non-zero even for a degenerate zero-height window at startup.
    private static let offscreenHeightMultiplier: CGFloat = 2

    /// Attach off-screen. Idempotent, and a no-op while the WebView is
    /// presented (already in a window). When the host app initialized the
    /// SDK before any window exists, the attach re-arms on the next window
    /// becoming key instead of silently dooming the load.
    static func attach(_ webView: WKWebView) {
        if tryAttach(webView) {
            stopWaitingForWindow()
            return
        }
        ClarityLog.log("warmup: no window yet — will attach when one appears")
        guard windowObserver == nil else { return }
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak webView] _ in
            guard let webView else {
                stopWaitingForWindow()
                return
            }
            if tryAttach(webView) { stopWaitingForWindow() }
        }
    }

    /// Return the WebView to windowless (no-op when it is not hosted here,
    /// e.g. presented). Always cancels a pending window-wait.
    static func detach(_ webView: WKWebView) {
        stopWaitingForWindow()
        if let host, webView.superview === host {
            webView.removeFromSuperview()
        }
        releaseIfEmpty()
    }

    /// Presentation reparents the WebView into the container's view — drop
    /// the then-empty host so nothing lingers in the host app's window.
    static func releaseIfEmpty() {
        guard let host, host.subviews.isEmpty else { return }
        host.removeFromSuperview()
        Self.host = nil
    }

    private static func tryAttach(_ webView: WKWebView) -> Bool {
        // Already in a window: presented, or hosted here by a previous call.
        if webView.window != nil { return true }
        guard let window = ActiveWindow.anyWindow() else { return false }

        let host = self.host ?? {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            self.host = view
            return view
        }()
        // Fully above the window's top edge: never composited on screen, yet
        // "in a window" — all WebKit needs to keep the page's rAF running.
        let bounds = window.bounds
        host.frame = bounds.offsetBy(
            dx: 0, dy: -Self.offscreenHeightMultiplier * max(bounds.height, 1)
        )
        if host.superview !== window {
            window.insertSubview(host, at: 0)
        }
        // Frame-managed here; the presented container re-enables Auto Layout.
        webView.translatesAutoresizingMaskIntoConstraints = true
        // Real viewport so the page lays out at presentation size, not 0×0.
        webView.frame = host.bounds
        host.addSubview(webView)
        ClarityLog.log("warmup: WebView attached off-screen for load")
        return true
    }

    private static func stopWaitingForWindow() {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        windowObserver = nil
    }
}
#endif
