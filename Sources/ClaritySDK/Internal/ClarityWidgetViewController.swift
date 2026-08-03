#if canImport(UIKit)
import UIKit
import WebKit

/// The presented widget container: hosts the shared warm WKWebView in either
/// a bottom sheet or a full-screen modal, drives dismissal off the global
/// close latch, and reports visibility to the engine.
///
/// The iOS counterpart of Android's `ClarityWidgetActivity` +
/// `ClarityWidgetScreen`: because the SDK owns the whole presentation object
/// graph here (no OS-owned Activity), the Android handoff machinery collapses
/// to a single `isModeSwitch` flag on dismissal.
final class ClarityWidgetViewController: UIViewController {

    private let webView: WKWebView
    private let mode: PresentationMode
    private let sheetHeightFraction: Double
    private let autoFocusInput: Bool
    private let showNativeCloseButton: Bool
    private unowned let engine: WidgetEngine

    /// Suppresses Dismissed/hidden reporting while swapping containers.
    private var isModeSwitch = false
    private var modeSwitchCompletion: (() -> Void)?
    private var didAppearOnce = false
    private var keyboardObservers: [NSObjectProtocol] = []
    private var offsetObservation: NSKeyValueObservation?
    private var webViewBottomConstraint: NSLayoutConstraint?
    private var headerSwipeRecognizer: UIPanGestureRecognizer?

    init(
        webView: WKWebView,
        mode: PresentationMode,
        sheetHeightFraction: Double,
        autoFocusInput: Bool,
        showNativeCloseButton: Bool,
        engine: WidgetEngine
    ) {
        self.webView = webView
        self.mode = mode
        self.sheetHeightFraction = sheetHeightFraction
        self.autoFocusInput = autoFocusInput
        self.showNativeCloseButton = showNativeCloseButton
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
        configurePresentationStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configurePresentationStyle() {
        switch mode {
        case .fullScreen:
            modalPresentationStyle = .fullScreen
        case .bottomSheet:
            modalPresentationStyle = .pageSheet
            if let sheet = sheetPresentationController {
                configureSheet(sheet)
            }
        }
        presentationController?.delegate = self
    }

    private func configureSheet(_ sheet: UISheetPresentationController) {
        if #available(iOS 16.0, *) {
            let fraction = sheetHeightFraction
            sheet.detents = [
                .custom(identifier: .init("clarity-fraction")) { context in
                    context.maximumDetentValue * fraction
                }
            ]
        } else {
            // iOS 15: approximate with system detents — a custom pan-gesture
            // sheet would reimplement keyboard avoidance, scrim and
            // interactive dismissal for a shrinking OS cohort. Documented in
            // the README.
            sheet.detents = sheetHeightFraction <= Self.mediumDetentFractionCap
                ? [.medium()] : [.large()]
        }
        sheet.preferredCornerRadius = Self.sheetCornerRadius
        sheet.prefersGrabberVisible = false
        // iOS 26 renders sheets floating with small side insets at rest, yet
        // snaps them edge-attached (full width) when the keyboard rises — the
        // inset is a preference, not a layout necessity. These are the
        // documented levers closest to "always edge-attached"; if a future
        // iOS still floats at rest, the remaining option is a custom
        // presentation (TODO.md).
        if #available(iOS 18.0, *) {
            sheet.prefersPageSizing = true
        }
        sheet.prefersEdgeAttachedInCompactHeight = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        mountWebView()
        observeKeyboard()

        if mode == .fullScreen {
            installHeaderSwipeToClose()
        }

        if showNativeCloseButton {
            addCloseButton()
        }

        // The container's whole lifetime is driven by the latch: host
        // dismiss(), the page ✕, the native ✕ and drag-dismiss all set it,
        // and this single observer performs the actual dismissal.
        WidgetHolder.setCloseObserver { [weak self] in
            self?.performLatchedClose()
        }
        // A close could have latched between init and viewDidLoad.
        if WidgetHolder.closeRequested {
            performLatchedClose()
        }
    }

    private func mountWebView() {
        // Reclaim from any previous hierarchy first — "already has a parent"
        // must never crash a presentation (Android parity).
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        // Full-screen respects the top safe area; the sheet is edge-to-edge
        // inside its own chrome.
        let topAnchor = mode == .fullScreen
            ? view.safeAreaLayoutGuide.topAnchor
            : view.topAnchor
        // Bottom is edge-to-edge (the page pads the home-indicator area
        // itself via viewport-fit=cover + env(safe-area-inset-bottom) — a
        // native gap under the composer reads as broken chrome); the
        // keyboard observers below shrink the WebView by the actual overlap,
        // Android `adjustResize` parity: the page relayouts with the
        // composer above the keyboard instead of WebKit inset-scrolling a
        // fixed-size page. (keyboardLayoutGuide is unsuitable: its
        // keyboard-hidden position is the safe-area bottom, which left a
        // permanent gap under the widget.)
        let bottomConstraint = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        webViewBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ])
    }

    private func addCloseButton() {
        let button = CloseButton.make(target: self, action: #selector(closeTapped))
        view.addSubview(button)
        NSLayoutConstraint.activate(CloseButton.layoutConstraints(for: button, in: view))
    }

    @objc private func closeTapped() {
        WidgetHolder.closeRequested = true
    }

    // MARK: - Header swipe-to-close (full screen)

    private static let mediumDetentFractionCap: Double = 0.55
    private static let sheetCornerRadius: CGFloat = 24
    private static let focusInputDelay: TimeInterval = 0.25
    private static let fallbackKeyboardAnimationDuration: Double = 0.25
    /// 7 is the undocumented private curve UIKit actually puts in keyboard
    /// notifications (not a public UIView.AnimationCurve case) — matching it
    /// keeps the fallback resize in step with the keyboard's own animation.
    private static let fallbackKeyboardAnimationCurve: UInt = 7
    /// UIView.AnimationOptions packs the animation curve into bits 16+.
    private static let animationCurveOptionShift: UInt = 16
    private static let headerSwipeZoneHeight: CGFloat = 80
    private static let headerSwipeMinTranslation: CGFloat = 100
    private static let headerSwipeMinVelocity: CGFloat = 800

    /// Full-screen counterpart of the sheet's drag-to-dismiss: a downward
    /// swipe that STARTS on the chat header closes the widget. Scoped hard
    /// so it can't disturb anything else: begins only inside the header
    /// zone, only for predominantly-downward pans, recognizes simultaneously
    /// with (and never cancels) the WebView's own gestures — list scrolling,
    /// composer and taps are untouched. No live drag tracking: a .fullScreen
    /// presentation removes the app behind it, so following the finger would
    /// reveal a black void (an interactive version needs .overFullScreen +
    /// a custom transition — TODO polish).
    private func installHeaderSwipeToClose() {
        let recognizer = UIPanGestureRecognizer(
            target: self, action: #selector(handleHeaderSwipe(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        headerSwipeRecognizer = recognizer
    }

    @objc private func handleHeaderSwipe(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: view).y
        let velocity = recognizer.velocity(in: view).y
        if translation > Self.headerSwipeMinTranslation
            || velocity > Self.headerSwipeMinVelocity {
            WidgetHolder.closeRequested = true
        }
    }

    // MARK: - Keyboard artifacts

    /// WebKit reacts to the keyboard on its own: a reveal-the-focused-element
    /// scroll plus a keyboard content inset on the document scroll view, both
    /// computed against the pre-resize frame. Combined with the
    /// bottom-constraint resize below they only displace the page (header
    /// rides off-screen). The document never scrolls legitimately (app-layout page,
    /// scrolling disabled in WebViewFactory), so both are zeroed after every
    /// keyboard transition; the async second pass runs after WebKit applies
    /// its own values.
    private func observeKeyboard() {
        // Instant enforcement: WebKit writes its reveal-scroll offset DURING
        // the keyboard animation — undoing it only afterwards (the first
        // shipped version reset at keyboardDidShow) plays out on screen as
        // content shifting up and snapping back. KVO pins the document at
        // zero in the same runloop tick, so the shift never renders. The
        // guard makes the reset re-entrancy-safe: our own zeroing re-fires
        // the observation with .zero and exits.
        offsetObservation = webView.scrollView.observe(
            \.contentOffset, options: [.new]
        ) { scrollView, change in
            guard let offset = change.newValue, offset != .zero else { return }
            scrollView.setContentOffset(.zero, animated: false)
        }
        // Will* notifications drive the resize (alongside the keyboard's own
        // animation); Did* notifications double as belt-and-braces cleanup
        // for the content inset (not KVO-contractual on UIScrollView; with
        // the offset pinned at zero a bottom inset never moves content).
        let willNames: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillHideNotification,
        ]
        let didNames: [Notification.Name] = [
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ]
        keyboardObservers = Self.observers(for: willNames) { [weak self] name, note in
            self?.updateKeyboardOverlap(note, hiding: name == UIResponder.keyboardWillHideNotification)
            self?.resetDocumentScroll()
        } + Self.observers(for: didNames) { [weak self] _, _ in
            self?.resetDocumentScroll()
            DispatchQueue.main.async { self?.resetDocumentScroll() }
        }
    }

    /// One registration shape for both observer groups — only the handler
    /// body differs between the will* and did* arms.
    private static func observers(
        for names: [Notification.Name],
        _ handler: @escaping (Notification.Name, Notification) -> Void
    ) -> [NSObjectProtocol] {
        names.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in handler(name, note) }
        }
    }

    /// Android `adjustResize` by hand: shrink the WebView by the keyboard's
    /// actual overlap with this view, animated alongside the keyboard.
    private func updateKeyboardOverlap(_ note: Notification, hiding: Bool) {
        guard let constraint = webViewBottomConstraint else { return }
        var overlap: CGFloat = 0
        if !hiding,
           let endValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            let endFrame = view.convert(endValue.cgRectValue, from: nil)
            // Only a DOCKED keyboard obstructs the widget: it pins to the
            // view's bottom edge and spans its width, and then the
            // intersection height equals the old bottom-bar arithmetic. An
            // iPad floating/undocked/split keyboard overlays like a palette
            // — treating its minY as a bottom obstruction shrank the widget
            // to the space above a keyboard that wasn't in the way.
            let intersection = view.bounds.intersection(endFrame)
            let isDocked = !intersection.isNull
                && abs(intersection.maxY - view.bounds.maxY) < 1
                && intersection.width >= view.bounds.width - 1
            overlap = isDocked ? intersection.height : 0
        }
        guard constraint.constant != -overlap else { return }
        constraint.constant = -overlap
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? Self.fallbackKeyboardAnimationDuration
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? Self.fallbackKeyboardAnimationCurve
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curveRaw << Self.animationCurveOptionShift),
            animations: { self.view.layoutIfNeeded() }
        )
    }

    private func resetDocumentScroll() {
        let scrollView = webView.scrollView
        if scrollView.contentInset != .zero {
            scrollView.contentInset = .zero
        }
        if scrollView.contentOffset != .zero {
            scrollView.setContentOffset(.zero, animated: false)
        }
    }

    deinit {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        offsetObservation?.invalidate()
    }

    // MARK: - Camera-capture airbag

    /// WebKit presents its file-upload pickers through the view controller
    /// hosting the WKWebView — this one. The menu's "Take Photo" option
    /// becomes a `UIImagePickerController` with a `.camera` source running in
    /// the HOST app's process; without `NSCameraUsageDescription` in the host
    /// Info.plist, iOS kills the app the moment the camera UI spins up (a TCC
    /// kill — not catchable in-process). The page cannot remove that menu
    /// item (WebKit owns the file-input menu), so the last line of defense is
    /// here: refuse to present a camera picker the host is not provisioned
    /// for. Cancelling through the picker's own delegate (WebKit) resolves
    /// the file input as "cancelled" instead of leaving it waiting; the
    /// keyless-safe sources (Photo Library, Choose File — both out-of-process
    /// pickers) pass through untouched, as does everything else the SDK
    /// presents (image preview).
    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        if let picker = viewControllerToPresent as? UIImagePickerController,
           picker.sourceType == .camera,
           !HostCapabilities.cameraCaptureProvisioned {
            engine.debug(
                "camera capture blocked: \(HostCapabilities.cameraUsageKey) "
                    + "missing from the host app Info.plist"
            )
            picker.delegate?.imagePickerControllerDidCancel?(picker)
            completion?()
            return
        }
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAppearOnce else { return }
        didAppearOnce = true
        engine.containerDidAppear()
        if autoFocusInput {
            focusChatInput()
        }
        // A close latched during the presentation transition wins.
        if WidgetHolder.closeRequested {
            performLatchedClose()
        }
    }

    /// Best-effort composer focus after reveal. Programmatic keyboard raise
    /// from JS focus is restricted by WebKit; combined with
    /// becomeFirstResponder this works on current simulators — verified by
    /// the rigor e2e; downgraded to focus-only where the OS refuses.
    private func focusChatInput() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusInputDelay) { [weak self] in
            guard let self, WidgetHolder.presentedContainer === self else { return }
            self.webView.becomeFirstResponder()
            self.webView.evaluateJavaScript(
                "try { var el = document.querySelector('textarea,[contenteditable=\"true\"],input[type=\"text\"]');"
                    + " if (el) el.focus(); } catch (e) {}",
                completionHandler: nil
            )
        }
    }

    // MARK: - Dismissal paths

    private func performLatchedClose() {
        guard !isModeSwitch else { return }
        guard presentingViewController != nil, !isBeingDismissed else { return }
        dismissAndComplete(animated: true)
    }

    /// Unanimated replacement during show(mode:) with a different mode — the
    /// widget conceptually stays open, so no Dismissed/hidden reporting.
    func dismissForModeSwitch(_ completion: @escaping () -> Void) {
        isModeSwitch = true
        modeSwitchCompletion = completion
        webView.removeFromSuperview()
        dismissAndComplete(animated: false)
    }

    /// What the renderer-crash recovery must re-present after the reset
    /// force-closes this container: the mode and sheet height the user was
    /// actually looking at.
    var presentationModeForRecovery: PresentationMode { mode }
    var sheetHeightFractionForRecovery: Double { sheetHeightFraction }

    /// The engine is resetting while we are presented (identity switch,
    /// updateConfig, renderer recovery) — close without reporting through the
    /// normal latch path twice.
    func forceCloseForReset() {
        webView.removeFromSuperview()
        guard presentingViewController != nil, !isBeingDismissed else { return }
        dismissAndComplete(animated: false)
    }

    /// The tail every dismissal path shares; the paths keep their distinct
    /// guards and detach behavior above.
    private func dismissAndComplete(animated: Bool) {
        dismiss(animated: animated) { [weak self] in
            self?.completeDismissal()
        }
    }

    private func completeDismissal() {
        WidgetHolder.setCloseObserver(nil)
        // Detach but never destroy: the WebView stays warm in the engine so
        // reopening is instant and the page's websocket keeps delivering.
        webView.removeFromSuperview()
        let wasModeSwitch = isModeSwitch
        engine.containerDidDismiss(isModeSwitch: wasModeSwitch)
        if wasModeSwitch {
            let completion = modeSwitchCompletion
            modeSwitchCompletion = nil
            completion?()
        }
    }
}

// MARK: - Header-swipe gating

extension ClarityWidgetViewController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === headerSwipeRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let location = pan.location(in: view)
        let zoneTop = view.safeAreaInsets.top
        guard location.y >= zoneTop,
              location.y <= zoneTop + Self.headerSwipeZoneHeight else {
            return false
        }
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === headerSwipeRecognizer
    }
}

// MARK: - Drag-to-dismiss

extension ClarityWidgetViewController: UIAdaptivePresentationControllerDelegate {

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        // Route the interactive dismissal through the same latch so the page
        // and the host learn about it exactly like every other close source.
        // The observer's dismiss() is a no-op mid-interactive-dismissal; the
        // completion below finishes the job.
        WidgetHolder.closeRequested = true
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        completeDismissal()
    }
}
#endif
