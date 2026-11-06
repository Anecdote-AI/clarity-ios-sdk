#if canImport(UIKit)
import UIKit
import WebKit

/// A voice call collapsed to its bubble: what to bring back when it expands.
struct CollapsedVoiceCall {
    let window: VoiceBubbleWindow
    let mode: PresentationMode
    let fraction: Double
    /// Whether an html screen held the room around the chat (see
    /// `setRoomAroundChat`); the expanded sheet gets it back.
    let roomGiven: Bool
    /// The controller the sheet was presented from; weak — the host owns it.
    weak var presenter: UIViewController?
    /// The bubble is fading out and the sheet is on its way.
    var expanding = false
}

/// `WidgetEngine`'s voice-call half: the page reports its call
/// (`voiceCallStatus`), and the customer collapses it (`collapseVoiceCall`)
/// to give the screen back to the app while talking to the assistant.
///
/// Collapsing, the sheet fades out, the page turns into the call's bubble and
/// reports its size (`voiceBubbleSize`), then the WebView, the call still in
/// it, moves into the bubble's own window and the sheet goes. The widget is
/// still open: the host hears no `onWidgetDismissed` and the page stays
/// visible (`widgetVisible`). A tap on the bubble (`expandVoiceCall`) fades
/// it out and presents a container again with the same WebView, faded in.
extension WidgetEngine {

    func voiceCallStatus(state: String, label: String) {
        let wasCollapsed = voice.collapsed
        voice.status(state: state, label: label)
        // The call is over: the chat it happened in is what to see now.
        if wasCollapsed, !voice.collapsed {
            expandVoiceCall()
        }
    }

    /// The page's collapse arrow. Only a sheet that is fully on screen
    /// collapses: one still sliding in or out has nowhere to go from.
    func collapseVoiceCallRequested() {
        guard voice.callActive,
              let container = WidgetHolder.presentedContainer as? ClarityWidgetViewController,
              container.canCollapseToBubble
        else { return }
        voice.collapse()
        container.collapseToBubble()
    }

    /// The page draws the bubble (true) or the call (false), where the
    /// bubble is now (`bubbleSpotForPage`).
    func showBubbleInPage(_ shown: Bool) {
        if !shown { voice.bubbleHidden() }
        let spot = bubbleSpotForPage()
        if shown, collapsedCall == nil { pageBubbleOnLeft = spot.onLeft }
        sendMessageToWebView(
            OutboundMessage.voiceCallCollapsed(shown, corner: spot.corner, onLeft: spot.onLeft)
        )
    }

    /// The bubble's corner and the screen edge it is on, for the page: from the
    /// bubble's window, which knows where it put it, or, before there is one,
    /// the configured corner on the edge that window will put it.
    private func bubbleSpotForPage() -> VoiceBubbleSpot {
        if let window = collapsedCall?.window { return window.spotForPage() }
        return VoiceBubbleSpot.configured(
            config?.voiceBubblePosition ?? .bottomEnd, near: ActiveWindow.anyWindow()
        )
    }

    func voiceBubbleMeasured(width: Int, height: Int) {
        voice.bubbleMeasured(width: width, height: height)
        guard let size = voice.bubbleSize else { return }
        collapsedCall?.window.resize(CGSize(width: size.width, height: size.height))
        let waiting = bubbleSizeWaiter
        bubbleSizeWaiter = nil
        waiting?()
    }

    /// Runs once the page measured the bubble, or after a short wait: a page
    /// that never measures it still gets a bubble, at a default size.
    func awaitBubbleSize(then done: @escaping () -> Void) {
        if voice.bubbleSize != nil { return done() }
        var fired = false
        let once = {
            guard !fired else { return }
            fired = true
            done()
        }
        bubbleSizeWaiter = once
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bubbleSizeWait) { [weak self] in
            self?.bubbleSizeWaiter = nil
            once()
        }
    }

    /// The container is leaving for the bubble, its WebView with it; called
    /// once the page is the bubble, before the sheet's dismissal.
    func voiceCallWillCollapse(
        webView: WKWebView,
        scene: UIWindowScene,
        mode: PresentationMode,
        fraction: Double,
        roomGiven: Bool,
        presenter: UIViewController?,
        waitForSize: Bool = false
    ) {
        let window = makeBubbleWindow(scene: scene)
        let size = voice.bubbleSize.map { CGSize(width: $0.width, height: $0.height) }
            ?? Self.defaultBubbleSize
        // The call first, so the window it holds is this call's when it
        // corrects the side the page was told.
        collapsedCall = CollapsedVoiceCall(
            window: window, mode: mode, fraction: fraction, roomGiven: roomGiven,
            presenter: presenter
        )
        window.hold(webView, size: size, waitForSize: waitForSize, pageOnLeft: pageBubbleOnLeft)
        pageBubbleOnLeft = nil
        // A page that never measures the bubble still shows one, at the size
        // it has, as the sheet's collapse does after the same wait
        // (`awaitBubbleSize`): the call is live in it.
        if waitForSize {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bubbleSizeWait) { [weak window] in
                window?.showIfWaiting()
            }
        }
        debug("voice: collapsed to the bubble")
    }

    private func makeBubbleWindow(scene: UIWindowScene) -> VoiceBubbleWindow {
        let window = VoiceBubbleWindow(
            windowScene: scene, position: config?.voiceBubblePosition ?? .bottomEnd
        )
        // A drag moved the bubble to the other side: the page turns it round.
        // Only while this is the call's bubble and it stays one: a landing
        // after the call opened again, or the window closed, would put the
        // page back into the bubble inside the sheet.
        window.onSideChanged = { [weak self, weak window] in
            guard let self, let window, let call = self.collapsedCall, call.window === window,
                  !call.expanding
            else { return }
            self.showBubbleInPage(true)
        }
        return window
    }

    /// The voice assistant straight away, in a conversation of the customer's:
    /// in the sheet, or collapsed to the bubble from the start (which needs a
    /// window scene of the app's to stand in).
    func startVoiceCall(_ presentation: ClarityVoicePresentation) {
        // A collapsed call is the voice assistant on screen already.
        if collapsedCall != nil {
            if presentation == .sheet { expandVoiceCall() }
            return
        }
        guard let config else { return }
        let inBubble = presentation == .bubble
            && WidgetHolder.presentedContainer == nil
            && ActiveWindow.anyWindow()?.windowScene != nil
        guard inBubble else {
            if state == .loaded {
                sendMessageToWebView(startVoiceCallMessage(collapsed: false))
            } else {
                pendingVoiceStart = .sheet
            }
            if WidgetHolder.presentedContainer == nil {
                show(mode: config.presentationMode, sheetHeightFraction: nil, keepingVoiceStart: true)
            }
            return
        }
        // The last command wins: a chat asked for while loading is off.
        clearPendingShow()
        switch state {
        case .loaded:
            startInBubble()
        case .loading:
            pendingVoiceStart = .bubble
        case .idle, .failed:
            pendingVoiceStart = .bubble
            startLoading()
        }
    }

    func startVoiceCallMessage(collapsed: Bool) -> String {
        let spot = bubbleSpotForPage()
        return OutboundMessage.startVoiceCall(collapsed: collapsed, corner: spot.corner, onLeft: spot.onLeft)
    }

    /// The call starts collapsed: the WebView goes straight into the bubble's
    /// window, hidden until the page has drawn the bubble, and the page opens a
    /// conversation and the call in it. The widget is open, as the bubble.
    func startInBubble() {
        guard let config, let webView, let scene = ActiveWindow.anyWindow()?.windowScene else { return }
        debug("voice: starting in the bubble")
        voice.startCollapsed()
        let window = makeBubbleWindow(scene: scene)
        window.hold(webView, size: Self.defaultBubbleSize, waitForSize: true)
        collapsedCall = CollapsedVoiceCall(
            window: window, mode: config.presentationMode,
            fraction: config.sheetHeightFraction, roomGiven: false, presenter: nil
        )
        // A close latched before (the app dismissing defensively) is not this
        // widget's: left set, it would make every later dismiss() silent.
        WidgetHolder.closeRequested = false
        WidgetHolder.setCloseObserver { [weak self] in self?.closeCollapsedVoiceCall() }
        sendMessageToWebView(startVoiceCallMessage(collapsed: true))
        setWidgetVisible(true)
        notify { $0.onWidgetShown() }
        // A page that never starts the call (one that predates this, or a
        // conversation that cannot take one) must not leave an empty bubble:
        // the chat opens instead. Keyed on this start's bubble, not only on the
        // page: a start that ended at once, and a second one within the wait,
        // must not have the first one's timer open the chat on the second.
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bubbleStartWait) { [weak self, weak window] in
            guard let self, let window, generation == self.loadGeneration,
                  self.collapsedCall?.window === window,
                  self.voice.collapsed, !self.voice.callActive
            else { return }
            self.debug("voice: no call came in the bubble, opening the chat")
            self.voice.expand()
            self.expandVoiceCall()
        }
    }

    /// The collapsing sheet is gone. From here a close (the host's
    /// `dismiss()`) closes the bubble, and a call that ended meanwhile opens
    /// the chat.
    func voiceCallDidCollapse() {
        WidgetHolder.setCloseObserver { [weak self] in self?.closeCollapsedVoiceCall() }
        if WidgetHolder.closeRequested {
            closeCollapsedVoiceCall()
        } else if !voice.collapsed {
            expandVoiceCall()
        }
    }

    /// A tap on the bubble, a card the call must show, the host's `show()`, or
    /// the call ending. The bubble fades out, the page shows the call again,
    /// and the sheet fades in; the page is painted (it was on screen a moment
    /// ago), so no first-frame wait. A second request while the sheet is on its
    /// way does nothing.
    func expandVoiceCall() {
        guard let call = collapsedCall, WidgetHolder.presentedContainer == nil else {
            // Still collapsing (a card came while the sheet faded out, or
            // while it leaves): the collapse stops where it is, or the call
            // opens again as soon as the bubble is up (`voiceCallDidCollapse`).
            if voice.collapsed { voice.expand() }
            return
        }
        guard !call.expanding, state == .loaded else { return }
        debug("voice: expanding the call")
        collapsedCall?.expanding = true
        call.window.fadeOut { [weak self] in
            guard let self, self.collapsedCall?.window === call.window else { return }
            self.showBubbleInPage(false)
            // The pinned presenter only while it can still present: the app
            // went on being used meanwhile, and may have covered it.
            let presenter = call.presenter.flatMap {
                $0.viewIfLoaded?.window != nil && $0.presentedViewController == nil ? $0 : nil
            }
            self.presentContainer(
                mode: call.mode, sheetHeightFraction: call.fraction, presenter: presenter,
                awaitsFirstFrame: false
            )
            // A presentation UIKit dropped (the app mid-transition, no
            // controller to present from) must not leave the bubble invisible
            // with the call live: it comes back, and the next tap tries again.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandWait) { [weak self] in
                guard let self, let current = self.collapsedCall, current.window === call.window,
                      current.expanding, WidgetHolder.presentedContainer == nil
                else { return }
                self.debug("voice: the sheet never came, back to the bubble")
                self.collapsedCall?.expanding = false
                // Where the customer left it, which may be the other side
                // from the configured corner.
                self.showBubbleInPage(true)
                current.window.fadeBackIn()
            }
        }
    }

    /// The page that held a collapsed call reloaded: no call survives it, and
    /// the chat comes back in the sheet. The widget never closed, so the host
    /// hears no second `onWidgetShown` (`containerDidAppear`).
    ///
    /// A container still on screen is either the sheet collapsing (it has
    /// handed the WebView over and is on its way out) or the call's sheet
    /// coming back: the first opens the chat again once it is gone
    /// (`voiceCallDidCollapse`, the reset left the call uncollapsed), the
    /// second takes the WebView as it is (`finishVoiceExpand`).
    func reopenAfterLostCall() {
        guard let call = collapsedCall, WidgetHolder.presentedContainer == nil else { return }
        collapsedCall = nil
        WidgetHolder.setCloseObserver(nil)
        call.window.close()
        webView?.removeFromSuperview()
        reopeningAfterLostCall = true
        presentContainer(mode: call.mode, sheetHeightFraction: call.fraction, presenter: nil)
    }

    /// The expanded container is on screen, the WebView in it: the bubble
    /// goes. False when this was no expansion.
    func finishVoiceExpand(into container: ClarityWidgetViewController) -> Bool {
        guard let call = collapsedCall else { return false }
        collapsedCall = nil
        voice.expand()
        call.window.close()
        if call.roomGiven {
            container.setRoomAroundChat(given: true)
        }
        return true
    }

    /// The host closed the widget while it was a bubble: a real close, as if
    /// the sheet had been up. The WebView goes windowless and warm, like
    /// after any close.
    private func closeCollapsedVoiceCall() {
        guard let call = collapsedCall, WidgetHolder.presentedContainer == nil else { return }
        collapsedCall = nil
        WidgetHolder.setCloseObserver(nil)
        // No screen is left to show the call on: it ends with the widget.
        // (Closing the sheet during a call keeps it, as before.)
        sendMessageToWebView(OutboundMessage.endVoiceCall())
        call.window.close()
        if webView?.window === call.window {
            webView?.removeFromSuperview()
        }
        showBubbleInPage(false)
        debug("voice: closed while collapsed")
        widgetDidClose()
    }

    /// The WebView is being destroyed (reset, failed load): its call is over,
    /// and a bubble for it would open nothing. Reported as a close, like the
    /// force-closed container of a reset.
    func endVoiceCall(tearingDown dying: WKWebView) {
        voice.reset()
        bubbleSizeWaiter = nil
        guard let call = collapsedCall else { return }
        collapsedCall = nil
        WidgetHolder.setCloseObserver(nil)
        call.window.close()
        dying.removeFromSuperview()
        widgetDidClose()
    }

    /// A page that never measures its bubble still gets one.
    private static let defaultBubbleSize = CGSize(width: 180, height: 84)
    private static let bubbleSizeWait: TimeInterval = 1
    /// How long a call asked for in the bubble may take to start before the chat opens instead.
    private static let bubbleStartWait: TimeInterval = 8
    /// How long an expansion may take to put the sheet on screen.
    private static let expandWait: TimeInterval = 2
}
#endif
