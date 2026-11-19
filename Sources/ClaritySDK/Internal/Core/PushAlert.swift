import Foundation

/// Whether a Clarity remote push is an alert the system shows by itself.
/// The platform sends an `aps.alert` push (it reaches a killed app too), so
/// `Clarity.handlePush` must not post its own notification for it as well:
/// in the background the system already displayed it, and in the foreground
/// the host's `willPresent` decides. Pure, so `swift test` covers it on Linux.
enum PushAlert {

    static func isShownBySystem(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any],
              let alert = aps["alert"]
        else { return false }
        if let text = alert as? String { return !text.isEmpty }
        if let fields = alert as? [AnyHashable: Any] { return !fields.isEmpty }
        return false
    }
}
