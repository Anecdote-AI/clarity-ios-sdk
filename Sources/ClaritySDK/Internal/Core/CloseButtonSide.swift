import Foundation

/// The edge the widget's native ✕ is pinned to. It must sit where the page's
/// own close button sits — at the end of the page's text direction — or an app
/// whose direction differs from the chat's (an English app with
/// `language: "ar"`) shows two crosses in opposite corners.
enum CloseButtonSide: Equatable {
    case left
    case right

    /// `htmlDir` is the page's `<html dir>`. Anything else — not read yet, or
    /// a page that never set it — falls back to the host app's direction, the
    /// side the button always took before.
    static func forPage(htmlDir: String?, hostIsRightToLeft: Bool) -> CloseButtonSide {
        switch htmlDir?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rtl": return .left
        case "ltr": return .right
        default: return hostIsRightToLeft ? .left : .right
        }
    }
}
