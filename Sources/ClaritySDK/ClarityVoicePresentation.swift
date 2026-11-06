/// How `Clarity.startVoiceCall(_:)` shows the voice assistant.
public enum ClarityVoicePresentation: String, Sendable {
    /// The chat's sheet opens with the call in it; the customer can collapse it.
    case sheet

    /// The call starts collapsed: only the bubble appears over the app, and a
    /// tap on it opens the call.
    case bubble
}
