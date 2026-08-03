/// Host-app observer for widget lifecycle, messages and errors.
///
/// Every method has an empty default implementation — adopt only what you
/// need. All callbacks are delivered on the main thread.
public protocol ClarityListener: AnyObject {
    /// The widget is ON SCREEN. Guaranteed to arrive after the unread
    /// counter reset (`onUnreadCountChanged(0)`) of that presentation, so
    /// `Clarity.unreadCount` is never stale when this fires. Not delivered
    /// for presentations that were dropped before appearing.
    func onWidgetShown()
    /// The widget was dismissed (host `dismiss()`, page ✕, native ✕ or drag).
    func onWidgetDismissed()
    /// Legacy load-failure callback; `onError` fires as well and is a superset.
    func onWidgetFailed(code: Int, message: String)
    /// The single reaction point for every classified SDK failure.
    func onError(_ error: ClarityError)
    /// An agent/AI reply arrived while the widget is hidden (preview text,
    /// truncated to 200 chars by the page before it reaches the SDK).
    func onNewMessage(_ textPreview: String)
    /// BINARY new-message flag for badging the host's Help button: 1 while
    /// unseen agent replies exist, 0 when the widget opens. Never a count —
    /// per-message previews arrive via `onNewMessage`.
    func onUnreadCountChanged(_ count: Int)
    /// The conversation's ticket status as reported by the chat page
    /// (`"open"` / `"closed"`). Fires on change — including after a
    /// `Clarity.refresh()` pulled a change made while the app was away.
    func onTicketStatusChanged(_ status: String)
    /// Unstructured progress trail (handshake, navigation, presentation…) for diagnostics.
    func onDebugEvent(_ event: String)
}

public extension ClarityListener {
    func onWidgetShown() {}
    func onWidgetDismissed() {}
    func onWidgetFailed(code: Int, message: String) {}
    func onError(_ error: ClarityError) {}
    func onNewMessage(_ textPreview: String) {}
    func onUnreadCountChanged(_ count: Int) {}
    func onTicketStatusChanged(_ status: String) {}
    func onDebugEvent(_ event: String) {}
}
