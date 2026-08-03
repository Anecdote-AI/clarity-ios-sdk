/// A classified SDK failure delivered through `ClarityListener.onError`.
///
/// Kind raw values match the Android SDK's enum names so cross-platform docs,
/// dashboards and debug trails speak one vocabulary.
public struct ClarityError: Error, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable {
        /// The request never got an HTTP response (offline, DNS, TLS,
        /// timeout) — or the server kept answering with a retryable status
        /// (5xx) until the handshake's retry budget ran out. Transient
        /// either way: retrying can succeed.
        case network = "NETWORK"
        /// The platform answered and rejected the credentials (4xx). The only
        /// non-recoverable kind: retrying with the same config is pointless.
        case handshakeRejected = "HANDSHAKE_REJECTED"
        /// The handshake succeeded but the widget page never became ready
        /// (HTTP >= 400 on the page, or the `pageLoaded` timeout).
        case pageLoadFailed = "PAGE_LOAD_FAILED"
        /// WKWebView's web content process was terminated by the OS; the SDK
        /// recovers automatically. (Android name kept for docs parity.)
        case rendererCrashed = "RENDERER_CRASHED"
        /// An unexpected internal failure the SDK caught instead of crashing the host.
        case internalError = "INTERNAL"
    }

    public let kind: Kind
    /// HTTP status, NSURLError code, -1 (pageLoaded timeout), -2 (handshake
    /// without HTTP response) or 0.
    public let code: Int
    public let message: String

    /// Whether retrying (e.g. calling `show()` again) can succeed.
    public var recoverable: Bool { kind != .handshakeRejected }

    public init(kind: Kind, code: Int, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }

    public var description: String {
        "ClarityError(\(kind.rawValue), code=\(code), recoverable=\(recoverable), \(message))"
    }
}

/// Internal `code` values for failures without an HTTP/NSURLError code
/// (the public doc on `code` lists them for host apps).
extension ClarityError {
    static let codeNone = 0
    static let codePageLoadTimeout = -1
    static let codeNoHTTPResponse = -2
}

extension ClarityError.Kind {
    /// Classify a failed handshake by its final HTTP status. Only a 4xx is a
    /// credential rejection (`handshakeRejected`, non-recoverable); a server
    /// that kept answering 5xx through the retry budget — or never answered
    /// at all — is `network`: transient, and `recoverable` for the host.
    static func forHandshakeFailure(lastHttpCode: Int?) -> ClarityError.Kind {
        guard let code = lastHttpCode else { return .network }
        return SessionAPI.rejectionStatusRange.contains(code) ? .handshakeRejected : .network
    }
}
