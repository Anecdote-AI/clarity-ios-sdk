import Foundation

/// The conversation a Clarity push is about. The backend sends it as the
/// `ticket_id` key of the push payload (a string, for FCM parity); a tap on
/// the notification opens the chat at that ticket through the page's
/// `openTicket` bridge action. Pure, so `swift test` covers it on Linux.
enum PushTicket {

    /// The payload key carrying the ticket id — in the remote push, and in
    /// the userInfo of the SDK's own local notification.
    static let userInfoKey = "ticket_id"

    /// A positive id, or nil for anything else: missing, blank, not all
    /// digits, zero, negative, fractional or past `Int.max`. A nil id still
    /// opens the chat on a tap, as it did before.
    static func parse(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let text = raw as? String {
            return parse(text: text)
        }
        // NSNumber first (a JSON number from APNs), with its own integrality
        // check, so a fraction is refused whatever the platform's bridging.
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            guard value.isFinite, value > 0, value.rounded() == value,
                  value < Double(Int.max)
            else { return nil }
            return number.intValue
        }
        if let number = raw as? Int {
            return number > 0 ? number : nil
        }
        return nil
    }

    private static func parse(text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
              let id = Int(trimmed), id > 0
        else { return nil }
        return id
    }
}
