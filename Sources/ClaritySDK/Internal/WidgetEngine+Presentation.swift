#if canImport(UIKit)
import UIKit
import WebKit

/// `WidgetEngine`'s presentation half: turning a loaded page into an on-screen
/// container, and taking the container's lifecycle callbacks back.
///
/// The reveal gating, the mode-switch recursion, the busy-presenter retry and
/// the onWidgetShown-in-containerDidAppear ordering are all behavioral
/// contracts the e2e suite asserts on — change shape here freely, but not
/// observable order or the debug strings.
extension WidgetEngine {

    private static let presentRetryDelay: TimeInterval = 0.3
    private static let revealGateTimeout: TimeInterval = 1.0
    private static let minSheetHeightFraction: Double = 0.3
    private static let maxSheetHeightFraction: Double = 1.0

    func presentContainer(
        mode: PresentationMode,
        sheetHeightFraction: Double?,
        presenter: UIViewController? = nil
    ) {
        guard let config, let webView else { return }
        // A new presentation supersedes any not-yet-consumed close (last
        // command wins) — without this a stale latch would instantly close
        // the widget the host just asked to show.
        WidgetHolder.closeRequested = false
        // NaN survives min/max untouched (every comparison against it is
        // false), so a NaN reaching us through the public sheetHeightFraction
        // would flow into the custom detent resolver and make UIKit fail the
        // presentation instead of clamping. ±inf clamps correctly.
        let requested = sheetHeightFraction ?? config.sheetHeightFraction
        let fraction = requested.isNaN
            ? ClarityConfig.defaultSheetHeightFraction
            : min(
                max(requested, Self.minSheetHeightFraction),
                Self.maxSheetHeightFraction
            )
        let request = PresentRequest(
            mode: mode, fraction: fraction, config: config, webView: webView,
            presenter: presenter
        )
        debug("present: \(mode.rawValue)")

        let generation = loadGeneration
        let present = { [weak self] in
            guard let self else { return }
            // The reveal gate can outlive a reset (identity switch,
            // updateConfig, renderer recovery) — and the reset CLEARS the
            // close latch, so the latch alone cannot veto.
            guard !WidgetHolder.closeRequested,
                  self.isStillCurrent(generation: generation, webView: request.webView)
            else {
                // Whatever aborted the present will not detach for us — do
                // not leave the instance parked in the warmup host.
                WarmupHost.detach(request.webView)
                return
            }
            self.issuePresent(request)
        }

        // Show-from-warm arrives with a windowless WebView (detached after
        // preload) — the reveal gate's rAF pair needs a window too.
        WarmupHost.attach(webView)

        // Two-stage reveal: pageLoaded said the page is authenticated and
        // painted (double-rAF on the page side), but give the compositor one
        // more frame pair so the present animation slides in real pixels.
        // Capped — a throttled rAF in a windowless WebView must not stall the
        // presentation.
        RevealGate.awaitFirstFrame(of: webView, timeout: Self.revealGateTimeout) {
            MainThread.run(present)
        }
        // onWidgetShown deliberately fires in containerDidAppear, NOT here:
        // firing at present initiation raced the unread reset (host could
        // observe Shown while unreadCount was still stale) and lied when the
        // presentation was subsequently dropped (busy presenter, latched
        // close). Android carries the same latent race — TODO there.
    }

    /// Everything one presentation needs, threaded as a single value through
    /// the mode-switch recursion and the busy-presenter retry.
    private struct PresentRequest {
        let mode: PresentationMode
        let fraction: Double
        let config: ClarityConfig
        let webView: WKWebView
        /// Host-pinned presenter (`show(from:)`); weak — the host owns it.
        weak var presenter: UIViewController?

        /// The pinned presenter while it is still alive, else the automatic
        /// top-view-controller walk. Resolved at use time, not capture time:
        /// the walk must see the hierarchy as it stands when the (possibly
        /// deferred or retried) presentation actually happens.
        var resolvedPresenter: UIViewController? {
            presenter ?? TopViewController.find()
        }
    }

    /// True while the load that captured this generation/WebView pair is
    /// still the engine's current one. Deferred presentation work (the reveal
    /// gate, the mode-switch dismissal, the busy retry) can outlive a reset —
    /// presenting anyway would mount a torn-down WebView, or the previous
    /// user's still-rendered conversation.
    private func isStillCurrent(generation: Int, webView: WKWebView) -> Bool {
        generation == loadGeneration && webView === self.webView
    }

    private func issuePresent(_ request: PresentRequest) {
        // Mode switch: a container is already up — replace it without
        // reporting Dismissed/hidden (the widget conceptually stays open).
        if let current = WidgetHolder.presentedContainer as? ClarityWidgetViewController {
            let generation = loadGeneration
            current.dismissForModeSwitch { [weak self] in
                // The animated dismissal takes real time — a reset (identity
                // switch, resetSession, updateConfig) landing inside it
                // invalidates this presentation.
                guard let self,
                      self.isStillCurrent(generation: generation, webView: request.webView)
                else { return }
                self.issuePresent(request)
            }
            return
        }

        guard let presenter = request.resolvedPresenter else {
            debug("present: no view controller to present from")
            return
        }
        // The presenter can be mid-transition (fast close→reopen). Retry once
        // shortly after instead of letting UIKit drop the presentation — the
        // iOS analog of Android's presentation watchdog.
        guard !presenter.isMidTransition else {
            scheduleBusyRetry(request)
            return
        }

        mountAndPresent(from: presenter, request)
    }

    /// The single delayed retry for a mid-transition presenter. The retry
    /// revalidates the full currency contract before presenting: holder and
    /// latch (a close or another presentation may have won meanwhile), the
    /// engine state, and the captured load still being current.
    private func scheduleBusyRetry(_ request: PresentRequest) {
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentRetryDelay) { [weak self] in
            guard let self, WidgetHolder.presentedContainer == nil,
                  !WidgetHolder.closeRequested, self.state == .loaded,
                  self.isStillCurrent(generation: generation, webView: request.webView)
            else { return }
            self.debug("present: presenter busy — retrying \(request.mode.rawValue)")
            guard let retryPresenter = request.resolvedPresenter else { return }
            // Still mid-transition (a slow dismissal, or the pinned
            // presenter presented something else): presenting now would
            // be rejected by UIKit AFTER mountAndPresent already claimed
            // WidgetHolder — a phantom "presented" widget. Drop instead.
            guard !retryPresenter.isMidTransition else {
                self.debug("present: presenter still busy — dropping the request")
                return
            }
            self.mountAndPresent(from: retryPresenter, request)
        }
    }

    private func mountAndPresent(from presenter: UIViewController, _ request: PresentRequest) {
        let container = ClarityWidgetViewController(
            webView: request.webView,
            mode: request.mode,
            sheetHeightFraction: request.fraction,
            autoFocusInput: request.config.autoFocusInput,
            showNativeCloseButton: request.config.showNativeCloseButton,
            engine: self
        )
        WidgetHolder.presentedWebView = request.webView
        WidgetHolder.presentedContainer = container
        presenter.present(container, animated: true)
    }

    /// Called by the container when a dismissal fully completed. The
    /// container calls on main (UIKit lifecycle), so the hop runs inline —
    /// kept, like in `containerDidAppear`, because these two are entry
    /// points from OUTSIDE the Clarity funnel and the wrapper is what makes
    /// the engine's main-confinement contract hold by construction rather
    /// than by every future caller remembering it.
    func containerDidDismiss(isModeSwitch: Bool) {
        MainThread.run { [self] in
            WidgetHolder.presentedWebView = nil
            WidgetHolder.presentedContainer = nil
            guard !isModeSwitch else { return }
            WidgetHolder.closeRequested = false
            setWidgetVisible(false)
            notify { $0.onWidgetDismissed() }
        }
    }

    /// Called by the container once it is on screen. Ordering is the
    /// contract: the visibility flip resets unread + cancels the
    /// notification FIRST, so by the time the host receives onWidgetShown,
    /// `unreadCount` is already 0 — never a stale value mid-transition.
    /// Wrapped for the same reason as `containerDidDismiss` (inline no-op
    /// hop; the container calls on main).
    func containerDidAppear() {
        MainThread.run { [self] in
            // Presentation reparented the WebView into the container; drop
            // the now-empty off-screen host.
            WarmupHost.releaseIfEmpty()
            setWidgetVisible(true)
            notify { $0.onWidgetShown() }
        }
    }
}

private extension UIViewController {
    /// UIKit silently drops a presentation issued while the presenter is
    /// still transitioning or already has a modal up — the exact situations
    /// the busy-presenter retry exists to wait out.
    var isMidTransition: Bool {
        isBeingDismissed || isBeingPresented || presentedViewController != nil
    }
}
#endif
