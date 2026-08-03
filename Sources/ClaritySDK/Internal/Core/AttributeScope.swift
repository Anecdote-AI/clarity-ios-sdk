/// The two attribute scopes the page accepts. Both share one pipeline
/// (store → send-if-loaded → flush-on-pageLoaded), but the ticket scope is
/// additionally ONE-SHOT: the platform stages ticket context on the session
/// and consumes it into exactly one ticket, so the engine drops its local
/// copy after every forward (see `WidgetEngine.setAttributes`). `allCases`
/// order (user, then ticket) is the flush order.
enum AttributeScope: CaseIterable {
    case user
    case ticket

    /// Bridge action name — frozen protocol, byte-identical to Android.
    var action: String {
        switch self {
        case .user: return "setUserAttributes"
        case .ticket: return "setTicketAttributes"
        }
    }

    /// Widget-URL query param carrying this scope's bootstrap attributes.
    /// The user scope rides the web-inject param name (`customAttributes` →
    /// session/complete) — frozen protocol, byte-identical to Android.
    var urlQueryName: String {
        switch self {
        case .user: return "customAttributes"
        case .ticket: return "ticketAttributes"
        }
    }
}
