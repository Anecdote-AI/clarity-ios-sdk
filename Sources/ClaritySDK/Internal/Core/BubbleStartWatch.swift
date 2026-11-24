import Foundation

/// How long a call asked for in the bubble (`Clarity.startVoiceCall(.bubble)`)
/// may take to start before the chat opens instead.
///
/// The chat used to open after a fixed 8 s, so a customer still reading the
/// microphone prompt, or a call still connecting on a slow network, lost the
/// bubble for the chat while the call went on starting. The wait now ends
/// early only when the page reports the call is over (no voice on the
/// channel, the microphone refused); otherwise it goes on while the customer
/// is answering the prompt or the call is on its way, up to a cap.
enum BubbleStartWatch {

    enum Decision: Equatable {
        /// The call is on, or the start is no longer this watch's.
        case stop
        /// Check again after `recheckInterval`.
        case keepWaiting
        /// Nothing came: open the chat.
        case openChat
    }

    /// The first check: a page that answers nothing at all by then predates
    /// the bubble or cannot take a call.
    static let firstCheck: TimeInterval = 8
    static let recheckInterval: TimeInterval = 2
    /// The longest a start may take, prompt included.
    static let cap: TimeInterval = 45

    static func decide(
        elapsed: TimeInterval,
        callActive: Bool,
        pageAnswered: Bool,
        awaitingPermission: Bool
    ) -> Decision {
        if callActive { return .stop }
        if elapsed >= cap { return .openChat }
        if awaitingPermission { return .keepWaiting }
        // The page started on the call (it reported a state, or asked for the
        // microphone): it says when it is over.
        if pageAnswered { return .keepWaiting }
        return .openChat
    }
}
