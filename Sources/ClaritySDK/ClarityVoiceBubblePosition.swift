/// Where a collapsed voice call waits over the host app: the customer taps the
/// arrow in the call's header, the chat gives the screen back to the app, and
/// a bubble with the assistant's aura and status waits in this corner; a tap
/// on the bubble opens the call again. Start and end follow the layout
/// direction.
///
/// Raw values match the Android SDK's `ClarityVoiceBubblePosition` names, like
/// `PresentationMode`.
public enum ClarityVoiceBubblePosition: String, Sendable {
    case topStart = "TOP_START"
    case topEnd = "TOP_END"
    case bottomStart = "BOTTOM_START"
    case bottomEnd = "BOTTOM_END"
}
