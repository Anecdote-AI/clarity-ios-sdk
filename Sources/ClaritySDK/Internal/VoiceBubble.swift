#if canImport(UIKit)
import UIKit
import WebKit

/// Where the page is told the bubble is: its corner, and the screen edge it is
/// against (the page's `side`, where it puts the aura).
struct VoiceBubbleSpot: Equatable {
    let corner: ClarityVoiceBubblePosition
    let onLeft: Bool

    /// Before there is a bubble to ask: the configured corner, on the edge a
    /// bubble's own view will put it. The bubble's window shares the scene of
    /// the app's windows, and so their direction (`effectiveUserInterfaceLayoutDirection`,
    /// which follows an app that turns its views round, where the app's
    /// language would not).
    static func configured(_ corner: ClarityVoiceBubblePosition, near view: UIView?) -> VoiceBubbleSpot {
        let rightToLeft = (view?.effectiveUserInterfaceLayoutDirection
            ?? UIApplication.shared.userInterfaceLayoutDirection) == .rightToLeft
        return VoiceBubbleSpot(
            corner: corner,
            onLeft: BubblePlacement.cornerOnLeft(start: corner.isStart, rightToLeft: rightToLeft)
        )
    }
}

extension ClarityVoiceBubblePosition {
    var isStart: Bool { self == .topStart || self == .bottomStart }
}

/// The collapsed voice call over the host app: the call's WebView itself, at
/// the size of the bubble the page draws in it (the call's real aura and what
/// it is doing). It starts in the configured corner; the customer can drag it
/// anywhere, and let go it sticks to the nearer side (`BubblePlacement`), above
/// the app's keyboard when it is up. A tap on the bubble reaches the page,
/// which asks to open the call again (`expandVoiceCall`).
///
/// Its own window, above the app's and never key: the app keeps its keyboard,
/// its focus and every touch outside the bubble. The iOS counterpart of
/// Android's `VoiceBubbleOverlay.kt`, which puts the WebView on the host
/// activity's own window; an app's windows are not the SDK's to add to here.
///
/// Main-thread confined by convention — see `MainThread`.
final class VoiceBubbleWindow: UIWindow {

    private let controller: VoiceBubbleController

    /// A drag moved the bubble to the other side: the page is to turn it round
    /// (`spotForPage`). Never once the bubble is on its way out (`fadeOut`, `close`).
    var onSideChanged: (() -> Void)? {
        get { controller.onSideChanged }
        set { controller.onSideChanged = newValue }
    }

    init(windowScene: UIWindowScene, position: ClarityVoiceBubblePosition) {
        controller = VoiceBubbleController(position: position)
        super.init(windowScene: windowScene)
        // Over the app's windows — its alerts and action sheets included, as
        // those are presented in the app's own window. The customer can drag
        // the bubble out of their way.
        windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        backgroundColor = .clear
        rootViewController = controller
        // Shown, never made key: the app's window keeps the keyboard and the
        // focus, and `TopViewController` keeps finding the app.
        isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// A tap on the bubble must not take the app's keyboard: the page inside
    /// focuses nothing, and this window never becomes key for it.
    override var canBecomeKey: Bool { false }

    /// Takes the call's WebView, straight from the sheet's window (one window
    /// to the other, never none), and fades the bubble in — or, for a call that
    /// starts collapsed, once the page has drawn the bubble (`resize`).
    /// `pageOnLeft`: the edge the page was told before this window was there
    /// to ask; one it turns out not to be on is corrected (`onSideChanged`).
    func hold(_ webView: WKWebView, size: CGSize, waitForSize: Bool = false, pageOnLeft: Bool? = nil) {
        controller.hold(webView, size: size, waitForSize: waitForSize, pageOnLeft: pageOnLeft)
    }

    /// Where the bubble is now, for the page, which from here draws it there.
    func spotForPage() -> VoiceBubbleSpot {
        controller.spotForPage()
    }

    /// The page never measured the bubble: it shows at the size it has.
    func showIfWaiting() {
        controller.revealIfWaiting()
    }

    /// The page measured the bubble again ("Speaking" is wider than "Listening").
    func resize(_ size: CGSize) {
        controller.resize(size)
    }

    /// Fades the bubble out; the WebView stays in this window, invisible, until
    /// the sheet takes it. A drag under way, or a bubble still flying to its
    /// side, ends where it is and reports no landing.
    func fadeOut(then done: @escaping () -> Void) {
        controller.fadeOut(then: done)
    }

    /// The sheet never came: the bubble shows again.
    func fadeBackIn() {
        controller.fadeBackIn()
    }

    /// The call is back in the sheet, or over: the WebView must have left by
    /// now, and nothing lands any more.
    func close() {
        controller.freeze()
        controller.restoreWebView()
        isHidden = true
        rootViewController = nil
    }

    /// Every touch but the bubble's goes through to the app — unless the page
    /// presented something over it (the microphone prompt).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if controller.presentedViewController != nil || hit.isDescendant(of: controller.holder) {
            return hit
        }
        return nil
    }
}

/// The bubble window's root: the WebView's holder, placed and dragged. The
/// status bar and the rotations stay the app's: a window above the app's with
/// a root view controller would otherwise decide them for as long as the
/// bubble is up.
private final class VoiceBubbleController: UIViewController {

    let holder = UIView()
    var onSideChanged: (() -> Void)?
    private(set) var position: ClarityVoiceBubblePosition
    private var size = CGSize.zero
    private var keyboardOverlap: CGFloat = 0
    private var keyboardObservers: [NSObjectProtocol] = []
    private weak var webView: WKWebView?
    private var webViewLook: (opaque: Bool, background: UIColor?, scrollBackground: UIColor?, scrolls: Bool)?
    /// Where the customer left it; nil until it is first laid out.
    private var chosen: BubblePlacement?
    /// The screen edge the page draws its aura on, once it was told one; it
    /// hears of a new one on landing.
    private var pageOnLeft: Bool?
    private var dragStart: BubblePlacement?
    private var waitingForSize = false
    private let pan = UIPanGestureRecognizer()
    /// On its way out: a drag or a flight that ends now lands nowhere, or the
    /// page would draw the bubble again inside the sheet that replaced it.
    private var frozen = false

    init(position: ClarityVoiceBubblePosition) {
        self.position = position
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        holder.alpha = 0
        view.addSubview(holder)
        // A drag moves the bubble; a tap still reaches the page.
        pan.addTarget(self, action: #selector(dragged(_:)))
        holder.addGestureRecognizer(pan)
        observeKeyboard()
        // A keyboard already open when the bubble came up.
        if let frame = KeyboardWatch.frame { keyboardOverlap = dockedOverlap(of: frame) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if dragStart == nil { layoutHolder() }
    }

    func hold(_ webView: WKWebView, size: CGSize, waitForSize: Bool, pageOnLeft: Bool?) {
        loadViewIfNeeded()
        self.webView = webView
        self.size = size
        self.pageOnLeft = pageOnLeft
        waitingForSize = waitForSize
        // The page shows the app through everything but the bubble, and does
        // not scroll under a finger that drags it.
        applyBubbleLook(to: webView)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        holder.addSubview(webView)
        layoutHolder()
        webView.frame = holder.bounds
        // A call that starts collapsed stays hidden until the page has drawn
        // the bubble; a page that never does leaves it so, and the engine
        // opens the chat instead.
        if !waitForSize {
            UIView.animate(withDuration: Self.fade) { self.holder.alpha = 1 }
        }
    }

    private func applyBubbleLook(to webView: WKWebView) {
        if webViewLook == nil {
            webViewLook = (
                webView.isOpaque, webView.backgroundColor, webView.scrollView.backgroundColor,
                webView.scrollView.isScrollEnabled
            )
        }
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
    }

    func fadeBackIn() {
        frozen = false
        if let webView { applyBubbleLook(to: webView) }
        // Against its side again, if it stopped in flight.
        layoutHolder()
        UIView.animate(withDuration: Self.fade) { self.holder.alpha = 1 }
    }

    /// Where it is now, and the edge it is against: where it was placed, or,
    /// before its first layout, where its corner will put it. The page draws
    /// it so from here.
    func spotForPage() -> VoiceBubbleSpot {
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let onLeft = chosen.map { $0.onStartSide != rightToLeft }
            ?? BubblePlacement.cornerOnLeft(start: position.isStart, rightToLeft: rightToLeft)
        pageOnLeft = onLeft
        return VoiceBubbleSpot(corner: position, onLeft: onLeft)
    }

    /// Nothing lands from here on. A drag under the finger is cancelled, and a
    /// bubble still flying stops where it is (the fade hides it), its
    /// completion reporting no landing.
    func freeze() {
        frozen = true
        waitingForSize = false
        dragStart = nil
        pan.isEnabled = false
        pan.isEnabled = true
        if let flying = holder.layer.presentation()?.frame, holder.layer.animationKeys() != nil {
            holder.layer.removeAllAnimations()
            holder.frame = flying
        }
    }

    func resize(_ size: CGSize) {
        if size != self.size {
            self.size = size
            layoutHolder()
        }
        revealIfWaiting()
    }

    func fadeOut(then done: @escaping () -> Void) {
        waitingForSize = false
        freeze()
        UIView.animate(withDuration: Self.fade, animations: { self.holder.alpha = 0 }) { _ in
            self.restoreWebView()
            done()
        }
    }

    /// The sheet shows the WebView as it was before the bubble.
    func restoreWebView() {
        guard let webView, let look = webViewLook else { return }
        webViewLook = nil
        webView.isOpaque = look.opaque
        webView.backgroundColor = look.background
        webView.scrollView.backgroundColor = look.scrollBackground
        webView.scrollView.isScrollEnabled = look.scrolls
    }

    func revealIfWaiting() {
        guard waitingForSize else { return }
        waitingForSize = false
        UIView.animate(withDuration: Self.fade) { self.holder.alpha = 1 }
    }

    /// The free area: the window, less the system bars and the keyboard.
    private var area: BubblePlacement.Area {
        let insets = view.safeAreaInsets
        return BubblePlacement.Area(
            width: view.bounds.width, height: view.bounds.height,
            barTop: insets.top, barBottom: insets.bottom,
            barLeft: insets.left, barRight: insets.right,
            keyboard: keyboardOverlap, margin: Self.margin,
            rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
    }

    /// Where it was left (against its side, clear of the keyboard), or its corner.
    private func layoutHolder() {
        let area = area
        guard area.width > 0, area.height > 0 else { return }
        let top = position == .topStart || position == .topEnd
        let start = position == .topStart || position == .bottomStart
        let first = self.chosen == nil
        let chosen = chosen ?? BubblePlacement.corner(
            area, width: size.width, height: size.height, top: top, start: start
        )
        self.chosen = chosen
        let placed = chosen.stuckToSide(area, width: size.width, height: size.height)
        holder.frame = CGRect(x: placed.left, y: placed.top, width: size.width, height: size.height)
        // Told an edge before this window was there to ask, the page turns
        // the bubble round if its corner is on the other one.
        if first, let told = pageOnLeft, told != chosen.onLeft(in: area), !frozen {
            onSideChanged?()
        }
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        // On its way out (`freeze`): the bubble moves no more, and what the
        // cancelled drag would drop lands nowhere.
        guard !frozen else {
            dragStart = nil
            return
        }
        let area = area
        switch pan.state {
        case .began:
            // One still flying from the last drop stops where it is.
            if let flying = holder.layer.presentation()?.frame, holder.layer.animationKeys() != nil {
                holder.layer.removeAllAnimations()
                holder.frame = flying
            }
            dragStart = BubblePlacement(
                left: holder.frame.minX, top: holder.frame.minY,
                onStartSide: chosen?.onStartSide ?? false
            )
        case .changed:
            guard let start = dragStart else { return }
            let move = pan.translation(in: view)
            let moved = start.moved(by: move.x, move.y, in: area, width: size.width, height: size.height)
            holder.frame.origin = CGPoint(x: moved.left, y: moved.top)
        case .ended, .cancelled, .failed:
            // Cancelled because its view left the window: no drop, and
            // nothing to tell the page.
            guard dragStart != nil, holder.window != nil else {
                dragStart = nil
                return
            }
            dragStart = nil
            let placed = BubblePlacement.dropped(
                area, left: holder.frame.minX, top: holder.frame.minY,
                width: size.width, height: size.height
            )
            chosen = placed
            let topHalf = placed.top + Double(size.height) / 2 < area.height / 2
            position = topHalf
                ? (placed.onStartSide ? .topStart : .topEnd)
                : (placed.onStartSide ? .bottomStart : .bottomEnd)
            let onLeft = placed.onLeft(in: area)
            // A spring that carries the throw: the bubble leaves the finger at
            // the speed it was moving towards its side, and settles without a
            // bounce.
            let target = CGPoint(x: placed.left, y: placed.top)
            let distance = hypot(target.x - holder.frame.minX, target.y - holder.frame.minY)
            let velocity = pan.velocity(in: view)
            let throwVelocity = BubblePlacement.throwVelocity(
                velocityX: velocity.x, velocityY: velocity.y,
                toX: target.x - holder.frame.minX, target.y - holder.frame.minY, max: Self.maxThrow
            )
            let landed = { [weak self] in
                // The page puts the aura on the side the bubble sticks to,
                // once it is there: moved in flight, the aura would jump
                // inside a moving bubble. One on its way out lands nowhere.
                guard let self, !self.frozen, onLeft != self.pageOnLeft else { return }
                self.onSideChanged?()
            }
            // Already there: the drag held it against the edge. Nothing
            // flies, and nothing waits for a flight.
            guard distance >= 1 else {
                holder.frame.origin = target
                landed()
                return
            }
            UIView.animate(
                withDuration: Self.snap, delay: 0,
                usingSpringWithDamping: Self.snapDamping,
                initialSpringVelocity: throwVelocity,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.holder.frame.origin = target
            } completion: { finished in
                if finished { landed() }
            }
        default:
            break
        }
    }

    private func observeKeyboard() {
        let center = NotificationCenter.default
        let change: (Notification) -> Void = { [weak self] note in
            self?.keyboardChanged(note)
        }
        keyboardObservers = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil, queue: .main, using: change
            ),
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil, queue: .main, using: change
            ),
        ]
    }

    private func keyboardChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        keyboardOverlap = hiding ? 0 : dockedOverlap(of: frame)
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) { self.layoutHolder() }
    }

    /// How far a keyboard docked at the bottom reaches up; a floating or
    /// undocked one (iPad) is no bottom edge to rise above.
    private func dockedOverlap(of screenFrame: CGRect) -> CGFloat {
        let local = view.convert(screenFrame, from: nil)
        let docked = local.maxY >= view.bounds.maxY - 1 && local.width >= view.bounds.width - 1
        return docked ? max(0, view.bounds.maxY - local.minY) : 0
    }

    /// The app's own controller for status-bar questions, as UIKit would ask it.
    private var app: UIViewController? {
        guard var top = TopViewController.find() else { return nil }
        while let child = top.childForStatusBarStyle ?? top.childForStatusBarHidden, child !== top {
            top = child
        }
        return top
    }

    override var prefersStatusBarHidden: Bool { app?.prefersStatusBarHidden ?? false }
    override var preferredStatusBarStyle: UIStatusBarStyle { app?.preferredStatusBarStyle ?? .default }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        TopViewController.find()?.supportedInterfaceOrientations ?? .all
    }

    private static let margin: Double = 6
    private static let fade: TimeInterval = 0.2
    private static let snap: TimeInterval = 0.55
    private static let snapDamping: CGFloat = 0.86
    /// The fastest throw the spring carries, in bubble-distances a second.
    private static let maxThrow: CGFloat = 8
}

/// Where the app's keyboard is, from the SDK's start on: a bubble that comes
/// up while the keyboard is already open learns it here, as the change
/// notifications came before the bubble was there to hear them.
enum KeyboardWatch {
    /// The keyboard's frame on screen while it is shown, else nil.
    private(set) static var frame: CGRect?
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
            ) { note in
                frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { _ in
                frame = nil
            },
        ]
    }
}
#endif
