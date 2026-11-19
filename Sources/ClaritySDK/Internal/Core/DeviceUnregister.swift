import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unbinds the device token from the live-chat session a logout or an
/// identity switch ends (`POST /api/live-chat/device/unregister`). Without it
/// the backend keeps pushing the previous customer's messages to this phone
/// until the next page load registers the token for the new session — and
/// nothing loads the page after a reset. Session-scoped: the request can only
/// drop that session's own binding. The token itself stays in the SDK; the
/// next page load registers it again. Pure, so `swift test` covers it on Linux.
enum DeviceUnregister {

    static let path = "/api/live-chat/device/unregister"

    /// The widget session's cookie: `livechat_session_id` in production,
    /// `livechat_session_id_<environment>` on the other stands. The AI and
    /// extension sessions (`ai_livechat_session_id`, …) are never the widget's.
    static let sessionCookieName = "livechat_session_id"

    /// At most this many candidate sessions are unbound (one per stand whose
    /// cookie the domain carries; in practice one).
    static let maxSessions = 3

    /// The session ids among the widget host's cookies: the exact production
    /// name first, then any per-stand name, deduplicated. A value that is not
    /// a UUID is no session (the backend refuses it anyway).
    static func sessionIds(fromCookies cookies: [(name: String, value: String)]) -> [String] {
        let exact = cookies.filter { $0.name == sessionCookieName }
        let perStand = cookies.filter { $0.name.hasPrefix(sessionCookieName + "_") }
        var ids: [String] = []
        for cookie in exact + perStand {
            let value = cookie.value.trimmingCharacters(in: .whitespaces)
            guard UUID(uuidString: value) != nil, !ids.contains(value) else { continue }
            ids.append(value)
        }
        return Array(ids.prefix(maxSessions))
    }

    /// The unregister request for one session, or nil for a base URL that is
    /// not a URL. Its log line must never carry the token or the session id.
    static func request(baseUrl: String, sessionId: String, deviceToken: String) -> URLRequest? {
        guard let url = URL(string: WidgetURL.trimTrailingSlashes(baseUrl) + path),
              let body = JSONEncoding.string(fromJSONObject: ["device_token": deviceToken])
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionId, forHTTPHeaderField: "Live-Chat-Authorization")
        request.httpBody = Data(body.utf8)
        return request
    }

    static let timeout: TimeInterval = 10
}
