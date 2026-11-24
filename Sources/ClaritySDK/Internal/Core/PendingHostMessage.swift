import Foundation

/// The message `Clarity.show(message:)` sends as the customer, held until the
/// widget page can receive it. Delivered once: a later `show()` without a
/// message, a page reload or a re-presentation never sends it again. The page
/// itself waits for a chat that can take it (`hostMessageRequest`).
struct PendingHostMessage {
    private(set) var text: String?

    /// The text to post now (the page is up), or nil when it waits for
    /// `takeOnPageLoaded`. Blank text is ignored. A newer message replaces
    /// one still waiting: the host asked twice before the page loaded.
    mutating func request(_ raw: String, pageLoaded: Bool) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if pageLoaded {
            text = nil
            return trimmed
        }
        text = trimmed
        return nil
    }

    /// The waiting text, once, for the pageLoaded flush.
    mutating func takeOnPageLoaded() -> String? {
        defer { text = nil }
        return text
    }

    /// The host dismissed the widget, or the load failed: the text is dropped.
    mutating func cancel() {
        text = nil
    }
}
