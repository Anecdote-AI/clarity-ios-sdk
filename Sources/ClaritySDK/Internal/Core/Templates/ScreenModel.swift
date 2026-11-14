import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One read of the host's current screen (spec 4.1): what `read_page`,
/// `get_page_text`, `show_on_page` and the form tools work on. Built on the
/// main thread at the start of each call by `ScreenReader` and never kept.
/// Never holds what is typed in a field: a field is only `filled` or not.
struct ScreenSnapshot {
    var title: String?
    var path: String?
    var lang: String?
    var nodes: [ScreenNode] = []
    /// Why nothing could be read, when nothing could.
    var unreadable: String?
    /// A budget stopped the walk.
    var truncated = false
    /// Part of the screen is drawn in a way the SDK cannot read (SwiftUI text
    /// and buttons when no assistive technology is on).
    var partial = false
    /// The layout reads right to left.
    var rightToLeft = false
}

enum ScreenRole: String {
    case heading, text, button, link, field, tab, toggle, image, dialog, message
}

enum ScreenMessageKind: String {
    case alert, status, dialog, toast
}

struct ScreenField {
    /// The web token (`FieldTypes`), or nil when it has no recognised type.
    var type: String?
    /// `text`, `email`, `tel` or `number` for an error on a field without a type.
    var inputKind = "text"
    /// Password, one-time code, card: only the customer types it.
    var customerOnly = false
    /// Non-empty; the value itself is never read.
    var filled = false
    var enabled = true
    var editable = true
    /// The error the screen shows for it.
    var error: String?
}

struct ScreenNode {
    var role: ScreenRole
    /// The name a person or a screen reader would give it; never a value.
    var name: String
    var url: String?
    /// In window coordinates.
    var rect: CGRect
    var field: ScreenField?
    var messageKind: ScreenMessageKind?
    /// The platform object to scroll to, draw around or fill (a view, an
    /// accessibility element). Held for the call only.
    var handle: AnyObject?
    /// The app keeps it from `click_element` (`clarityNoClick` on it or around it).
    var noClick = false
    /// A heading only by its large font, not marked as one by the app: the
    /// screen's heading only when nothing better names it (`readPage`).
    var inferredHeading = false
}

extension ScreenSnapshot {

    /// Reading order: rows of 8 points from the top, then from the leading edge.
    static func readingOrder(_ nodes: [ScreenNode], rightToLeft: Bool) -> [ScreenNode] {
        nodes.enumerated().sorted { a, b in
            let rowA = Int((a.element.rect.minY / 8).rounded(.down))
            let rowB = Int((b.element.rect.minY / 8).rounded(.down))
            if rowA != rowB { return rowA < rowB }
            let xA = rightToLeft ? -a.element.rect.maxX : a.element.rect.minX
            let xB = rightToLeft ? -b.element.rect.maxX : b.element.rect.minX
            if xA != xB { return xA < xB }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Whitespace collapsed, cut to `limit` characters.
    static func clean(_ text: String?, limit: Int) -> String {
        String((text ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
    }
}
