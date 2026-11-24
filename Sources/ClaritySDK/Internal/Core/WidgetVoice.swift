import Foundation

/// A voice call open in the widget's page, as the page reports it
/// (`voiceCallStatus`), and whether it is collapsed to its bubble.
///
/// Collapsed, the sheet fades out and the page shows only the call's bubble
/// (its own aura, small, and the status) at the size it reports for it
/// (`voiceBubbleSize`). The sheet goes and the WebView, and with it the call,
/// moves into a small window of its own over the host app
/// (`WidgetEngine+VoiceCall`): the app keeps its keyboard and every touch
/// outside the bubble. A tool's reveal during a call collapses instead of
/// stepping aside: the customer is talking, not typing, so a sheet coming back
/// between two of the app's screens only hid what the assistant had just
/// shown. The app's own `Clarity.stepAside` still steps aside: the app brings
/// the chat back itself, and is told both ways.
///
/// Port of the Android SDK's `WidgetVoice.kt`. Main thread only.
struct WidgetVoice: Equatable {

    static let ended = "ended"

    /// How long the sheet takes to fade out before a tool shows its screen:
    /// as long as a reveal's fade, which this stands in for during a call.
    static let collapseFade: TimeInterval = 0.4

    /// The bubble's size in CSS points, as the page measured it.
    struct BubbleSize: Equatable {
        let width: Int
        let height: Int
    }

    /// A call is open in the page and not over.
    private(set) var callActive = false

    /// The page's state: starting, listening, thinking or speaking.
    private(set) var state = ""

    /// The page's words for what the assistant is doing, in the chat's language.
    private(set) var label = ""

    private(set) var collapsed = false

    /// Once the page measured the bubble; cleared when it shows the call again.
    private(set) var bubbleSize: BubbleSize?

    /// When the host app last ended the call itself (`endedByHost`), until the
    /// page agrees it is over or a new call is asked for.
    private(set) var hostEndedAt: Date?

    /// How long after the host ended the call a status from the page saying
    /// it is still on is one already on its way, not a new call. The page
    /// reports every change of what the assistant is doing, so one is often
    /// in flight when the host ends the call: taken at its word it put the
    /// call back on with nothing on screen, and the host heard `started` and
    /// a second `ended` later, when the page went away (`resetSession`).
    static let hostEndGrace: TimeInterval = 2

    mutating func status(state: String, label: String, now: Date = Date()) {
        let active = !state.isEmpty && state != Self.ended
        if let endedAt = hostEndedAt {
            if !active {
                hostEndedAt = nil
            } else if now.timeIntervalSince(endedAt) < Self.hostEndGrace {
                return
            } else {
                hostEndedAt = nil
            }
        }
        self.state = state
        self.label = label
        callActive = active
        // The call is over: the chat it happened in is what to see now.
        if !active { collapsed = false }
    }

    /// The host app asked for the call collapsed from the start
    /// (`Clarity.startVoiceCall(.bubble)`): collapsed before the page reports
    /// it. A call that never comes (no voice on the channel) reads as over,
    /// and opens the chat.
    mutating func startCollapsed() {
        collapsed = true
        bubbleSize = nil
    }

    /// The customer asked to collapse the call.
    mutating func collapse() {
        if callActive { collapsed = true }
    }

    /// Something is about to be shown in the app. In a call a tool's reveal
    /// collapses the sheet instead of stepping it aside: true when it did, and
    /// the reveal moves nothing itself. The app's own step-aside never does.
    mutating func revealStarting(origin: InAppRevealOrigin) -> Bool {
        guard callActive, origin == .tool else { return false }
        collapsed = true
        return true
    }

    mutating func bubbleMeasured(width: Int, height: Int) {
        if width > 0, height > 0 { bubbleSize = BubbleSize(width: width, height: height) }
    }

    /// The page shows the call again, not the bubble.
    mutating func bubbleHidden() {
        bubbleSize = nil
    }

    /// The customer tapped the bubble, or the widget closed.
    mutating func expand() {
        collapsed = false
        bubbleSize = nil
    }

    /// The page is gone: no call survives it.
    mutating func reset() {
        self = WidgetVoice()
    }

    /// The host app ended the call (`Clarity.dismiss()` with the sheet up):
    /// over from here, before the page reports it, so the sheet closes instead
    /// of collapsing.
    mutating func endedByHost(now: Date = Date()) {
        status(state: Self.ended, label: "", now: now)
        hostEndedAt = now
    }

    /// The host app closed the widget (`Clarity.dismiss()`): a call that is on
    /// ends with it, and one asked for that the page has not mounted yet is
    /// called off too, or it would start later in a WebView with no window
    /// (the page cancels a pending request on `endVoiceCall`). True when the
    /// page must be told; it ignores the message when nothing is pending.
    mutating func hostClosed(pageLoaded: Bool, now: Date = Date()) -> Bool {
        if callActive {
            endedByHost(now: now)
            return true
        }
        return pageLoaded
    }

    /// The host app asked for a call: whatever it ended before is behind it.
    mutating func callRequested() {
        hostEndedAt = nil
    }

    /// What the host app hears of the call (`ClarityListener.onVoiceCallEvent`).
    var phase: VoiceCallPhase {
        VoiceCallPhase(active: callActive, collapsed: callActive && collapsed)
    }
}

/// Whether a call is on and whether it is the bubble: the host app hears every
/// change of it, once (`ClarityVoiceCallEvent`).
struct VoiceCallPhase: Equatable {
    let active: Bool
    let collapsed: Bool

    static let idle = VoiceCallPhase(active: false, collapsed: false)

    /// The events that take a host from `old` to this phase, in order.
    func events(since old: VoiceCallPhase) -> [ClarityVoiceCallEvent] {
        if active != old.active {
            guard active else { return [.ended] }
            return collapsed ? [.started, .collapsed] : [.started]
        }
        guard active, collapsed != old.collapsed else { return [] }
        return [collapsed ? .collapsed : .expanded]
    }
}
