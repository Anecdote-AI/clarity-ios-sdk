import Foundation

/// Small JSON helpers shared by the URL builder and the bridge. Keys are
/// always sorted so output is deterministic (org.json on Android does not
/// guarantee order; the page parses semantically, tests compare parsed).
enum JSONEncoding {

    /// `["a": "1"]` → `{"a":"1"}`. Falls back to `{}` if serialization fails
    /// (cannot happen for JSON-safe values, but never crash the host).
    static func objectString(_ object: [String: Any]) -> String {
        string(fromJSONObject: object) ?? "{}"
    }

    /// Serialize any JSON-compatible dictionary to a compact, sorted string.
    static func string(fromJSONObject object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parse a JSON object string into a dictionary; nil for anything that is
    /// not a JSON object.
    static func object(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JavaScript string literal (quoted + escaped) holding `string` — the
    /// equivalent of Android's `JSONObject.quote`, used to pass a JSON payload
    /// as the single string argument of `ClarityBridge.onMessage("<json>")`.
    static func javaScriptStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [string], options: []
        ), let wrapped = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // [ "..." ] → "..."
        return String(wrapped.dropFirst().dropLast())
    }
}
