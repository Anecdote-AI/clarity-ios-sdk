import Foundation

/// JSON builders for the native→page direction, delivered by evaluating
/// `window.ClarityBridge.onMessage("<json>")` in the widget WebView.
///
/// The page-side handler is `handleMessageFromNativeSdk` in
/// `anecdote-live-chat/src/utils/nativeSdkBridge.ts`.
enum OutboundMessage {

    /// One builder for both attribute scopes — identical payload shape,
    /// scope-tagged action. Values serialize as their JSON types; `.null`
    /// becomes a JSON null, which the backend treats as "remove this key".
    ///
    /// Callers must pass finite values only: a NaN/inf would make
    /// `JSONSerialization` reject the whole payload, downgrading it to
    /// action-only. The engine sanitizes once when it stores attributes
    /// (`droppingNonFiniteValues`), and everything sent here — direct send
    /// and pageLoaded flush alike — comes from that store.
    static func setAttributes(
        _ attributes: [String: ClarityAttributeValue], scope: AttributeScope
    ) -> String {
        payload(
            action: scope.action,
            fields: ["attributes": attributes.mapValues { $0.jsonValue }]
        )
    }

    static func logEvent(name: String, params: [String: String]) -> String {
        payload(action: "logEvent", fields: ["name": name, "params": params])
    }

    /// `platform` is always sent explicitly: the page-side handler defaults a
    /// missing platform to `"android"` (nativeSdkBridge.ts) — an iOS token
    /// registered under the wrong platform would break push routing later.
    static func setDeviceToken(_ token: String) -> String {
        payload(action: "setDeviceToken", fields: ["token": token, "platform": ClarityPlatform.identifier])
    }

    static func widgetVisibilityChanged(visible: Bool) -> String {
        payload(action: "widgetVisibilityChanged", fields: ["visible": visible])
    }

    /// Host-requested on-demand sync: the page refetches the conversation
    /// events, so the latest ticket state (status + any missed replies) flows
    /// through the normal reporting path.
    static func refreshConversation() -> String {
        payload(action: "refreshConversation", fields: [:])
    }

    /// Fields that may appear in a log line: SDK-generated, never
    /// host-supplied. `visible` is load-bearing for diagnosis — unread-badge
    /// and notification timing questions are answered by the order of the
    /// visibility flips against message delivery, and an action name alone
    /// cannot answer them.
    private static let loggableFields = ["visible"]

    /// The loggable form of a payload built above: the action name plus the
    /// allowlisted fields, and NOTHING else. The payloads carry the APNs device
    /// token, host-supplied attribute values and event params; `ClarityLog`
    /// writes to the device console, which ends up in any sysdiagnose the
    /// customer collects, so logging a whole payload would leak that data.
    static func loggableSummary(ofPayload payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = object["action"] as? String
        else { return "unknown" }

        let extras: [String] = loggableFields.compactMap { key in
            guard let value = object[key] else { return nil }
            if let flag = value as? Bool { return "\(key)=\(flag)" }
            return "\(key)=\(value)"
        }
        return ([action] + extras).joined(separator: " ")
    }

    private static func payload(action: String, fields: [String: Any]) -> String {
        var object: [String: Any] = fields
        object["action"] = action
        return JSONEncoding.string(fromJSONObject: object) ?? #"{"action":"\#(action)"}"#
    }
}
