#if canImport(UIKit)
import Foundation
import UserNotifications

/// Local "new support message" notification, shown when an agent reply
/// arrives while the widget is hidden. Port of Android's NotificationHelper:
/// a SINGLE constant identifier so a newer reply replaces the previous
/// notification in place (no stacking), and the SDK NEVER prompts for
/// notification permission — that is the host app's decision; without
/// authorization this is a silent no-op.
enum NotificationHelper {

    static let notificationIdentifier = "clarity-support-message"
    /// Marker in userInfo so `Clarity.handleNotificationResponse` can route taps.
    static let userInfoMarkerKey = "clarity_notification"


    /// Bumped by `cancel()`, captured by `showNewMessage`, re-checked before
    /// the request is filed. `getNotificationSettings` answers asynchronously,
    /// so without this a cancel landing in that window (agent reply
    /// immediately followed by opening the widget, `resetSession()` or an
    /// identity switch) would be undone by the pending `add` — notifying over
    /// a visible widget, or showing the previous user's message preview to the
    /// new one. Only ever touched on the main thread.
    private static var generation = 0

    /// Safe from any thread: `Clarity.handlePush` forwards straight from the
    /// host's push handler, so the generation bookkeeping hops to main first.
    /// - Parameter language: `ClarityConfig.language`; the title and the
    ///   fallback body follow it like the chat does (`NativeStrings`).
    static func showNewMessage(_ text: String, language: String?) {
        MainThread.run {
            let issuedGeneration = generation
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                else { return }

                let content = UNMutableNotificationContent()
                content.title = NativeStrings.text(.notificationTitle, language: language)
                content.body = text.isEmpty
                    ? NativeStrings.text(.notificationFallbackBody, language: language)
                    : text
                content.sound = .default
                content.userInfo = [userInfoMarkerKey: true]
                content.interruptionLevel = .active

                let request = UNNotificationRequest(
                    identifier: notificationIdentifier,
                    content: content,
                    trigger: nil
                )
                MainThread.run {
                    guard issuedGeneration == generation else { return }
                    center.add(request, withCompletionHandler: nil)
                }
            }
        }
    }

    static func cancel() {
        MainThread.run {
            generation += 1
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        }
    }
}
#endif
