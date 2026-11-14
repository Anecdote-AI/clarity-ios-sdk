import Foundation

/// "May this frame talk to the SDK?" — decided for every message that reaches
/// the widget's script message handler.
///
/// WebKit exposes `window.webkit.messageHandlers.<name>` to EVERY frame of
/// the WebView, the html-widget iframes the chat renders included (sandboxed,
/// opaque origin, content the chat does not author). Injecting the
/// `ClarityBridge` shim only into the main frame does not change that: a
/// subframe can call the WebKit handler directly. So the native side checks
/// the sender itself: only the main frame, at the origin of the configured
/// widget base URL, is the live chat page.
///
/// The main frame never sits at another origin in practice — the navigation
/// policy sends every foreign main-frame navigation to the browser — so the
/// origin check costs nothing and keeps a page that got there anyway out.
///
/// Plain values in, so the pure-Swift suite covers it: `WKScriptMessage` and
/// `WKFrameInfo` cannot be built in a test.
enum BridgeFrameFilter {

    /// - Parameters:
    ///   - isMainFrame: `WKFrameInfo.isMainFrame` of the sender.
    ///   - originProtocol: `WKSecurityOrigin.protocol` (`https`, or empty for
    ///     an opaque origin such as a sandboxed iframe).
    ///   - originHost: `WKSecurityOrigin.host`.
    ///   - originPort: `WKSecurityOrigin.port`; 0 means the scheme's default.
    ///   - baseUrl: the configured widget base URL. Unset, unparseable or not
    ///     http(s) accepts nothing (fail closed).
    static func accepts(
        isMainFrame: Bool,
        originProtocol: String,
        originHost: String,
        originPort: Int,
        baseUrl: String?
    ) -> Bool {
        guard isMainFrame,
              let base = baseUrl.flatMap({ URL(string: $0) }),
              base.isWebLink,
              let baseScheme = base.scheme?.lowercased(),
              let baseHost = base.host.map(normalizedHost),
              !baseHost.isEmpty
        else { return false }

        let scheme = originProtocol.lowercased()
        let host = normalizedHost(originHost)
        guard !scheme.isEmpty, !host.isEmpty else { return false }

        return scheme == baseScheme
            && host == baseHost
            && URL.effectivePort(scheme: scheme, port: originPort == 0 ? nil : originPort)
                == URL.effectivePort(scheme: baseScheme, port: base.port)
    }

    /// Hosts compare case-insensitively; an IPv6 literal may come with or
    /// without its brackets depending on the API that produced it.
    private static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }
}
