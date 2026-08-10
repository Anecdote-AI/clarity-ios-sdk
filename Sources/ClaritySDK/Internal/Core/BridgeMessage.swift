import Foundation

/// Messages the widget web page can send to the native side through
/// `ClarityBridge.postMessage(json)`.
///
///  - `pageLoaded`             → page is authenticated and painted, safe to present
///  - `pageLoadedError`        → the page will never become ready, so stop waiting:
///    its own `session/complete` was rejected (required contact attributes
///    missing, token spent, platform error). Carries `error.code` (the HTTP
///    status, 0 if there was no response) and `error.message`. Without it the
///    only signal is the load timeout, which cannot say why.
///  - `contentHeightDidChange` → content height in CSS px (parsed, currently unused)
///  - `close`                  → web UI asks the native container to close
///  - `newMessage`             → agent/AI reply arrived while the widget is hidden
///  - `unreadCountDidChange`   → unread counter for the host app badge
///  - `openImage`              → user tapped an image attachment; native shows
///    a full-screen preview (in the browser the host page renders a lightbox)
///  - `openLink`               → user tapped a link in a message/article; the
///    page never navigates for links, so native opens the external browser
///
/// Port of the Android SDK's `MessageAction.kt`; parsing defaults are kept
/// identical (missing optional fields fall back rather than fail).
enum BridgeMessage: Equatable {
    case pageLoaded
    case pageLoadedError(code: Int, message: String)
    case contentHeightDidChange(height: Double)
    case close
    case newMessage(text: String)
    case unreadCountDidChange(count: Int)
    case ticketStatusChanged(status: String)
    case openImage(url: String)
    case openLink(url: String)
    case unknown(action: String)

    /// nil = unparseable (not JSON, no `action`, or a required field missing) —
    /// the caller logs and drops it, mirroring Android's catch around `fromJson`.
    static func parse(_ raw: String) -> BridgeMessage? {
        guard let json = JSONEncoding.object(from: raw),
              let action = json["action"] as? String
        else { return nil }

        switch action {
        case "pageLoaded":
            return .pageLoaded
        case "pageLoadedError":
            let error = json["error"] as? [String: Any]
            return .pageLoadedError(
                code: intValue(error?["code"]) ?? 0,
                message: error?["message"] as? String ?? "unknown"
            )
        case "contentHeightDidChange":
            // Android uses getDouble (throws when absent) — a heightless
            // message is a parse failure, not a zero.
            guard let height = doubleValue(json["height"]) else { return nil }
            return .contentHeightDidChange(height: height)
        case "close":
            return .close
        case "newMessage":
            return .newMessage(text: json["text"] as? String ?? "")
        case "unreadCountDidChange":
            return .unreadCountDidChange(count: intValue(json["count"]) ?? 0)
        case "ticketStatusChanged":
            return .ticketStatusChanged(status: json["status"] as? String ?? "")
        case "openImage":
            return .openImage(url: json["url"] as? String ?? "")
        case "openLink":
            return .openLink(url: json["url"] as? String ?? "")
        default:
            return .unknown(action: action)
        }
    }

    /// JSONSerialization numbers arrive as NSNumber (with platform-dependent
    /// Int/Double bridging) — one normalization path for both accessors.
    /// NSNumber's accessors clamp out-of-range values from page-controlled
    /// JSON, where `Int(_: Double)` would trap and crash the host app.
    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private static func intValue(_ value: Any?) -> Int? {
        number(value)?.intValue
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        number(value)?.doubleValue
    }
}
