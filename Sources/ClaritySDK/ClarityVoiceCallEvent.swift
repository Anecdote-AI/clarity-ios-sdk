/// What happened to the voice call, for `ClarityListener.onVoiceCallEvent`.
public enum ClarityVoiceCallEvent: String, Sendable {
    /// A call started: the customer chose voice in the chat, or the app
    /// called `Clarity.startVoiceCall`.
    case started

    /// The call shrank to its bubble over the app. It goes on.
    case collapsed

    /// The call is in the chat's sheet again.
    case expanded

    /// The call is over: hung up, failed, or the widget's page went away.
    case ended
}
