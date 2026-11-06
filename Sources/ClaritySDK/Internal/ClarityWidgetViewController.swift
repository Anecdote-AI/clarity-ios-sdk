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
    private var closeButtonSideConstraint: NSLayoutConstraint?
    private let language: String?
    /// Mount the WebView only once this container's view is in a window: it
    /// comes from a voice call's bubble, where the call runs in it.
    private let mountsWebViewInWindow: Bool
    private var webViewMounted = false
    private unowned let engine: WidgetEngine

    /// Suppresses Dismissed/hidden reporting while swapping containers.
    private var isModeSwitch = false
    /// Suppresses it too: the sheet is going, the voice call stays (as a bubble).
    private var isCollapsingToBubble = false
    /// A still of the call, left in a full-screen container whose WebView went
    /// to the bubble, so the screen does not slide away blank.
    private var collapseStill: UIView?
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
        language: String?,
        mountsWebViewInWindow: Bool = false,
        engine: WidgetEngine
    ) {
        self.webView = webView
        self.mode = mode
        self.sheetHeightFraction = sheetHeightFraction
        self.autoFocusInput = autoFocusInput
        self.showNativeCloseButton = showNativeCloseButton
        self.language = language
        self.mountsWebViewInWindow = mountsWebViewInWindow
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
        sheet.detents = [fractionDetent]
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

    /// The sheet as the app sized it: [sheetHeightFraction] of the largest
    /// sheet. iOS 15 has no custom detents and approximates with the system
    /// ones — a custom pan-gesture sheet would reimplement keyboard
    /// avoidance, scrim and interactive dismissal for a shrinking OS cohort.
    /// Documented in the README.
    private var fractionDetent: UISheetPresentationController.Detent {
        if #available(iOS 16.0, *) {
            let fraction = sheetHeightFraction
            return .custom(identifier: Self.fractionDetentIdentifier) { context in
                context.maximumDetentValue * fraction
            }
        }
        return sheetHeightFraction <= Self.mediumDetentFractionCap ? .medium() : .large()
    }

    // MARK: - The room around the chat window

    /// The page asked for the room around the chat window, or gave it back:
    /// an html screen that takes the whole device raises the sheet to its
    /// largest detent — the top of the screen, as far as a sheet goes on
    /// iOS (the status bar stays, the dimmed host app behind it) — and lets
    /// it drop back to the app's fraction when the screen collapses. In
    /// place, the WebView attached throughout: replacing the container, the
    /// way `show(mode:)` switches modes, took the widget off the screen for
    /// the length of a presentation. A full-screen container has nothing
    /// more to give, and does nothing.
    func setRoomAroundChat(given: Bool) {
        roomGiven = given
        // While the chat is stepped aside for a tool, the strip owns the
        // detents; the chat comes back at the size asked for meanwhile.
        guard mode == .bottomSheet, reveal == nil, !revealStarting,
              let sheet = sheetPresentationController else { return }
        let detent: UISheetPresentationController.Detent = given ? .large() : fractionDetent
        sheet.animateChanges {
            sheet.detents = [detent]
            sheet.selectedDetentIdentifier = nil
        }
    }

    // MARK: - Stepping aside for an in-app tool (`ClarityToolReveal`)

    private struct Reveal {
        let style: ClarityToolReveal.Style
        let cover: UIView
        let label: UILabel
        let detents: [UISheetPresentationController.Detent]
    }

    private var reveal: Reveal?
    private var revealStarting = false
    /// Bumped by every reveal start and by an end that came before it took
    /// effect, so a late page answer cannot drop the sheet to a strip that
    /// nothing would bring back.
    private var revealToken = 0
    private var roomGiven = false
    /// The page's colour arrives from JavaScript; past this the strip uses
    /// the system background rather than keep the chat in place.
    private static let pageColorWait: TimeInterval = 0.3
    private static let stripDetentIdentifier =
        UISheetPresentationController.Detent.Identifier("clarity-reveal-strip")
    private static let stripHeight: CGFloat = 110
    private static let revealCoverFade: TimeInterval = 0.25
    private static let revealSheetMove: TimeInterval = 0.4

    override func loadView() {
        let root = WindowReportingView()
        if mountsWebViewInWindow {
            root.onMovedToWindow = { [weak self] in self?.mountWebView() }
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // From the bubble, the WebView moves the moment the sheet's view
        // enters a window: from one window to the other, never none. Before
        // the first frame of the presentation, so the sheet never slides in
        // empty.
        if !mountsWebViewInWindow {
            mountWebView()
        }
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
        guard !webViewMounted else { return }
        webViewMounted = true
        // Reclaim from any previous hierarchy first — "already has a parent"
        // must never crash a presentation (Android parity). A mount from the
        // bubble moves it straight across instead (see `mountsWebViewInWindow`).
        if !mountsWebViewInWindow {
            webView.removeFromSuperview()
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        // Under everything: a mount from the bubble comes after the ✕.
        view.insertSubview(webView, at: 0)

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
        let button = CloseButton.make(
            target: self,
            action: #selector(closeTapped),
            accessibilityLabel: NativeStrings.text(.close, language: language)
        )
        view.addSubview(button)
        NSLayoutConstraint.activate(CloseButton.sizeAndTopConstraints(for: button, in: view))
        let hostIsRightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        placeCloseButton(
            button,
            side: CloseButtonSide.forPage(htmlDir: nil, hostIsRightToLeft: hostIsRightToLeft)
        )
        // The page is loaded before the container exists (pageLoaded gates the
        // presentation), so its direction is already set: put the ✕ where the
        // page's own close button is.
        webView.evaluateJavaScript("document.documentElement.dir") { [weak self, weak button] value, _ in
            guard let self, let button else { return }
            self.placeCloseButton(
                button,
                side: CloseButtonSide.forPage(
                    htmlDir: value as? String, hostIsRightToLeft: hostIsRightToLeft
                )
            )
        }
    }

    private func placeCloseButton(_ button: UIButton, side: CloseButtonSide) {
        closeButtonSideConstraint?.isActive = false
        let constraint = CloseButton.sideConstraint(for: button, in: view, side: side)
        constraint.isActive = true
        closeButtonSideConstraint = constraint
    }

    @objc private func closeTapped() {
        WidgetHolder.closeRequested = true
    }

    // MARK: - Header swipe-to-close (full screen)

    private static let mediumDetentFractionCap: Double = 0.55
    private static let fractionDetentIdentifier =
        UISheetPresentationController.Detent.Identifier("clarity-fraction")
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // From the bubble, presented without the slide: the sheet and its
        // dimming fade in, as they faded out.
        if mountsWebViewInWindow, mode == .bottomSheet, !didAppearOnce {
            presentationController?.containerView?.alpha = 0
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAppearOnce else { return }
        didAppearOnce = true
        if mountsWebViewInWindow, mode == .bottomSheet,
           let fading = presentationController?.containerView {
            UIView.animate(withDuration: WidgetVoice.collapseFade) { fading.alpha = 1 }
        }
        engine.containerDidAppear(self)
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
    ///
    /// The widget now lands on Home, which has no composer: the customer
    /// reaches it only after tapping into a conversation. So when there is no
    /// composer yet, watch the page and focus it the moment one appears —
    /// once per opening, and never after the widget closes.
    private func focusChatInput() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusInputDelay) { [weak self] in
            guard let self, WidgetHolder.presentedContainer === self else { return }
            self.webView.becomeFirstResponder()
            self.webView.evaluateJavaScript(Self.focusComposerScript, completionHandler: nil)
        }
    }

    private func stopFocusingChatInput() {
        webView.evaluateJavaScript(Self.stopFocusingComposerScript, completionHandler: nil)
    }

    private static let focusComposerScript = """
        (function () {
          try {
            var previous = window.__clarityAutoFocusObserver;
            if (previous) { previous.disconnect(); }
            window.__clarityAutoFocusObserver = null;
            var focus = function () {
              var composer = document.querySelector('textarea');
              if (!composer) { return false; }
              composer.focus();
              return true;
            };
            if (focus()) { return; }
            var observer = new MutationObserver(function () {
              if (focus()) {
                observer.disconnect();
                window.__clarityAutoFocusObserver = null;
              }
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
            window.__clarityAutoFocusObserver = observer;
          } catch (e) {}
        })()
        """

    private static let stopFocusingComposerScript = """
        (function () {
          try {
            var observer = window.__clarityAutoFocusObserver;
            if (observer) { observer.disconnect(); }
            window.__clarityAutoFocusObserver = null;
          } catch (e) {}
        })()
        """

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

    // MARK: - Collapsing a voice call to its bubble

    /// Only a sheet that is fully on screen, with nothing over it, collapses
    /// (a `dismiss` with an image preview up would close only the preview).
    var canCollapseToBubble: Bool {
        !isModeSwitch && !isCollapsingToBubble && presentingViewController != nil
            && presentedViewController == nil
            && !isBeingPresented && !isBeingDismissed && webViewMounted
            && view.window?.windowScene != nil
    }

    /// The customer collapsed the call, or a tool is about to show something
    /// during one: the sheet fades out in place (as a reveal's fade does), the
    /// page turns into the call's bubble and measures it, then the WebView,
    /// the call still in it, moves to the bubble's window and the sheet goes
    /// without a further animation. `ready` (a reveal's) runs once the sheet is
    /// out of sight, so the tool shows its screen to the customer.
    func collapseToBubble(then ready: (() -> Void)? = nil) {
        guard canCollapseToBubble, let scene = view.window?.windowScene else {
            ready?()
            return
        }
        isCollapsingToBubble = true
        // The keyboard goes with the sheet.
        webView.evaluateJavaScript(Self.blurScript, completionHandler: nil)
        view.endEditing(true)
        // Full screen: UIKit took the app's view away underneath, so a fade
        // would go through black. The call moves to the bubble at once (hidden
        // until the page has drawn it), and the screen slides away as it
        // closes, showing a still of the call the WebView left it with.
        if mode == .fullScreen {
            if let still = webView.snapshotView(afterScreenUpdates: false) {
                still.frame = webView.frame
                view.insertSubview(still, belowSubview: webView)
                collapseStill = still
            }
            engine.showBubbleInPage(true)
            handOffToBubble(scene: scene, animated: true, waitForSize: true, then: ready)
            return
        }
        let fading: UIView = presentationController?.containerView ?? view
        presentationController?.presentedView?.isUserInteractionEnabled = false
        UIView.animate(withDuration: WidgetVoice.collapseFade, animations: {
            fading.alpha = 0
        }) { [weak self] _ in
            guard let self else {
                ready?()
                return
            }
            // The call ended, a card came, or the page reloaded while the
            // sheet faded: there is no call to collapse any more, and the
            // sheet comes back as it is.
            guard self.engine.voice.collapsed else {
                self.cancelCollapse(then: ready)
                return
            }
            self.engine.showBubbleInPage(true)
            self.engine.awaitBubbleSize { [weak self] in
                guard let self else {
                    ready?()
                    return
                }
                self.handOffToBubble(scene: scene, animated: false, waitForSize: false, then: ready)
            }
        }
    }

    /// The WebView goes to the bubble's window and the sheet goes. A tool that
    /// waits (`ready`, a reveal's) runs only once the sheet is gone: whatever
    /// it presents is then presented from the app, not from this sheet, and
    /// this dismissal cannot take it away.
    private func handOffToBubble(
        scene: UIWindowScene, animated: Bool, waitForSize: Bool, then ready: (() -> Void)?
    ) {
        // Closed meanwhile, something presented over the sheet (that a
        // dismissal would close too), or no call left to collapse (it ended,
        // a card came, the page reloaded while it measured the bubble):
        // the collapse is off, and the call is drawn in the sheet again.
        guard !isBeingDismissed, presentingViewController != nil, presentedViewController == nil,
              engine.voice.collapsed
        else {
            engine.showBubbleInPage(false)
            cancelCollapse(then: ready)
            return
        }
        engine.voiceCallWillCollapse(
            webView: webView,
            scene: scene,
            mode: mode,
            fraction: sheetHeightFraction,
            roomGiven: roomGiven,
            presenter: presentingViewController,
            waitForSize: waitForSize
        )
        dismissAndComplete(animated: animated, then: ready)
    }

    private func cancelCollapse(then ready: (() -> Void)?) {
        isCollapsingToBubble = false
        collapseStill?.removeFromSuperview()
        collapseStill = nil
        presentationController?.containerView?.alpha = 1
        presentationController?.presentedView?.isUserInteractionEnabled = true
        engine.voice.expand()
        ready?()
    }

    /// The tail every dismissal path shares; the paths keep their distinct
    /// guards and detach behavior above.
    private func dismissAndComplete(animated: Bool, then done: (() -> Void)? = nil) {
        dismiss(animated: animated) { [weak self] in
            self?.completeDismissal()
            done?()
        }
    }

    private func completeDismissal() {
        WidgetHolder.setCloseObserver(nil)
        // A loader floating over the app must not outlive the chat.
        reveal?.cover.removeFromSuperview()
        reveal = nil
        // A composer that appears while the widget is closed must not take
        // focus: the watch is for this opening only.
        if autoFocusInput {
            stopFocusingChatInput()
        }
        // Detach but never destroy: the WebView stays warm in the engine so
        // reopening is instant and the page's websocket keeps delivering.
        // Only from here: collapsed, it is in the bubble's window by now.
        if webView.superview === view {
            webView.removeFromSuperview()
        }
        let wasModeSwitch = isModeSwitch
        engine.containerDidDismiss(
            isModeSwitch: wasModeSwitch, collapsedToBubble: isCollapsingToBubble
        )
        if wasModeSwitch {
            let completion = modeSwitchCompletion
            modeSwitchCompletion = nil
            completion?()
        }
    }
}

// MARK: - Stepping aside for an in-app tool

extension ClarityWidgetViewController: InAppRevealSurface {

    /// Strip: a loader first covers the chat while the sheet stays put (so
    /// nothing shifts on screen), then the sheet drops to a strip and the app
    /// behind is undimmed. Fade: the sheet fades out in place and the loader
    /// floats over the app. A full-screen chat has no app behind it to show.
    func beginReveal(
        style: ClarityToolReveal.Style,
        message: String,
        origin: InAppRevealOrigin,
        ready: @escaping () -> Void
    ) -> Bool {
        // Collapsed to the call's bubble there is no sheet to move: the tool
        // runs and the app shows what it did, the bubble stays put.
        guard mode == .bottomSheet, reveal == nil, revealStarting == false,
              !engine.voice.collapsed, !isCollapsingToBubble,
              sheetPresentationController != nil, view.window != nil
        else { return false }
        // In a call a tool's reveal collapses the sheet to the bubble rather
        // than stepping it aside, and it stays collapsed: two animations at
        // once, or the sheet coming back over the app, is what this avoids.
        // The app's own step-aside steps aside: the app brings the chat back.
        if canCollapseToBubble, engine.voice.revealStarting(origin: origin) {
            collapseToBubble(then: ready)
            return true
        }
        revealStarting = true
        revealToken += 1
        let token = revealToken
        // Stepping aside, the chat drops the keyboard: it would cover the
        // strip and the very screen the customer is meant to see.
        webView.evaluateJavaScript(Self.blurScript, completionHandler: nil)
        view.endEditing(true)
        // The strip covers the chat in the colour the page shows, so stepping
        // aside never flashes a different colour over the chat. Whichever
        // comes first — the colour or the wait — starts the step-aside.
        let start: (UIColor) -> Void = { [weak self] pageColor in
            guard let self, self.revealStarting, token == self.revealToken else { return }
            self.revealStarting = false
            self.stepAside(style: style, message: message, pageColor: pageColor, ready: ready)
        }
        webView.evaluateJavaScript(Self.pageColorScript) { value, _ in
            start((value as? String).flatMap(Self.color(css:)) ?? .systemBackground)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageColorWait) {
            start(.systemBackground)
        }
        return true
    }

    private func stepAside(
        style: ClarityToolReveal.Style,
        message: String,
        pageColor: UIColor,
        ready: @escaping () -> Void
    ) {
        guard let sheet = sheetPresentationController, let window = view.window else { return ready() }
        let label = UILabel()
        let cover = Self.loaderView(
            label: label,
            message: message,
            floating: style == .fade,
            background: style == .fade ? .secondarySystemBackground : pageColor
        )
        cover.alpha = 0
        reveal = Reveal(style: style, cover: cover, label: label, detents: sheet.detents)
        switch style {
        case .strip:
            view.addSubview(cover)
            NSLayoutConstraint.activate([
                cover.topAnchor.constraint(equalTo: view.topAnchor),
                cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            view.layoutIfNeeded()
            UIView.animate(withDuration: Self.revealCoverFade, animations: { cover.alpha = 1 }) { _ in
                sheet.animateChanges {
                    sheet.detents = [Self.stripDetent]
                    sheet.largestUndimmedDetentIdentifier = Self.stripDetentIdentifier
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealSheetMove, execute: ready)
            }
        case .fade:
            window.addSubview(cover)
            NSLayoutConstraint.activate([
                cover.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                cover.bottomAnchor.constraint(
                    equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            ])
            window.layoutIfNeeded()
            sheet.animateChanges {
                sheet.largestUndimmedDetentIdentifier = undimmedIdentifier
            }
            // An invisible sheet must not take the taps meant for the app.
            presentationController?.presentedView?.isUserInteractionEnabled = false
            UIView.animate(withDuration: Self.revealSheetMove, animations: {
                self.view.alpha = 0
                cover.alpha = 1
            }) { _ in ready() }
        }
    }

    /// The background the page shows beside its content: from a point at the
    /// chat's left edge, up the ancestors to the first opaque background.
    private static let pageColorScript = """
        (function () {
          try {
            var el = document.elementFromPoint(2, Math.round(window.innerHeight / 2));
            while (el) {
              var c = getComputedStyle(el).backgroundColor;
              if (c && c !== 'transparent' && !/rgba\\([^)]*,\\s*0\\)$/.test(c)) { return c; }
              el = el.parentElement;
            }
          } catch (e) {}
          return '';
        })()
        """

    private static let blurScript =
        "(function(){try{var e=document.activeElement;if(e&&e.blur){e.blur();}}catch(x){}})()"

    /// `rgb(r, g, b)` or `rgba(r, g, b, a)` as the page reports it.
    static func color(css: String) -> UIColor? {
        let numbers = css
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap(Double.init)
        guard numbers.count >= 3 else { return nil }
        return UIColor(
            red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255,
            alpha: numbers.count > 3 ? numbers[3] : 1
        )
    }

    func updateReveal(message: String) {
        reveal?.label.text = message
    }

    /// The way back, in the reverse order.
    func endReveal() {
        guard let current = reveal else {
            // Ended before the step-aside took effect: call it off.
            if revealStarting {
                revealStarting = false
                revealToken += 1
            }
            return
        }
        reveal = nil
        let sheet = sheetPresentationController
        switch current.style {
        case .strip:
            sheet?.animateChanges {
                sheet?.detents = [roomGiven ? .large() : fractionDetent]
                sheet?.largestUndimmedDetentIdentifier = nil
                sheet?.selectedDetentIdentifier = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealSheetMove) {
                UIView.animate(withDuration: Self.revealCoverFade, animations: {
                    current.cover.alpha = 0
                }) { _ in current.cover.removeFromSuperview() }
            }
        case .fade:
            presentationController?.presentedView?.isUserInteractionEnabled = true
            sheet?.animateChanges { sheet?.largestUndimmedDetentIdentifier = nil }
            UIView.animate(withDuration: Self.revealSheetMove, animations: {
                self.view.alpha = 1
                current.cover.alpha = 0
            }) { _ in current.cover.removeFromSuperview() }
        }
    }

    /// The sheet's own detent, so a faded sheet leaves the app undimmed: the
    /// custom fraction detent on iOS 16+, the system one it maps to on iOS 15.
    private var undimmedIdentifier: UISheetPresentationController.Detent.Identifier {
        if #available(iOS 16.0, *) {
            return Self.fractionDetentIdentifier
        }
        return sheetHeightFraction <= Self.mediumDetentFractionCap ? .medium : .large
    }

    /// Dark text on a light background, light on a dark one.
    private static func ink(on background: UIColor) -> UIColor {
        UIColor { traits in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            background.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return luminance > 0.5 ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.95, alpha: 1)
        }
    }

    private static var stripDetent: UISheetPresentationController.Detent {
        if #available(iOS 16.0, *) {
            return .custom(identifier: stripDetentIdentifier) { _ in stripHeight }
        }
        return .medium()
    }

    /// A spinner and the message: covering the whole chat for the strip, a
    /// floating pill for the fade.
    private static func loaderView(
        label: UILabel,
        message: String,
        floating: Bool,
        background: UIColor
    ) -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.backgroundColor = background
        let ink = Self.ink(on: background)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = ink
        spinner.startAnimating()
        label.text = message
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = ink
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        if floating {
            box.layer.cornerRadius = 22
            box.layer.shadowColor = UIColor.black.cgColor
            box.layer.shadowOpacity = 0.18
            box.layer.shadowRadius = 12
            box.layer.shadowOffset = CGSize(width: 0, height: 4)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
                row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
                row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
                row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            ])
        } else {
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                row.topAnchor.constraint(equalTo: box.topAnchor, constant: 34),
                row.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 16),
            ])
        }
        return box
    }
}

// MARK: - Window attachment

/// The container's root view; reports entering a window (see
/// `mountsWebViewInWindow`).
private final class WindowReportingView: UIView {
    var onMovedToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMovedToWindow?() }
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
