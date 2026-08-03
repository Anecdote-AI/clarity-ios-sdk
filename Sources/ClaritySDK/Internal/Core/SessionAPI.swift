import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal synchronous HTTP seam so `SessionAPI`'s retry/classification logic
/// is unit-testable (and Linux-testable) without touching the network.
protocol HTTPTransport {
    /// Blocking GET. Throws on transport failure (offline, DNS, TLS, timeout);
    /// returns whatever HTTP status the server answered with otherwise.
    func get(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) throws -> (statusCode: Int, body: Data)
}

struct URLSessionTransport: HTTPTransport {
    func get(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // The handshake runs on the SDK's private serial queue (the analog of
        // Android's single-thread executor), so blocking here is deliberate.
        // The semaphore orders the write before the read; the box exists only
        // because a captured `var` is illegal in Swift 6 concurrency.
        final class ResultBox: @unchecked Sendable {
            var value: Result<(Int, Data), Error> = .failure(URLError(.unknown))
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.value = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                box.value = .success((http.statusCode, data ?? Data()))
            } else {
                box.value = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        let (status, body) = try box.value.get()
        return (status, body)
    }
}

/// Plays the role the `inject.js` loader plays on the web: performs the
/// one-time-token handshake (`GET /api/live-chat/session/unverified`) before
/// the widget page is loaded. The page then completes the session itself.
///
/// Port of the Android SDK's `SessionApi.kt`: 3 attempts, 300 ms backoff,
/// 10 s timeout, any 4xx short-circuits (the platform said no — retrying is
/// pointless) and is later classified as `HANDSHAKE_REJECTED`.
final class SessionAPI {

    /// Human-readable reason of the last failed `fetchOneTimeToken` call.
    private(set) var lastError: String?

    /// HTTP status of the last failed call, when the endpoint answered at
    /// all (4xx = the platform rejected the credentials; nil = the request
    /// never got an HTTP response — offline, DNS, TLS, timeout).
    private(set) var lastHttpCode: Int?

    private let transport: HTTPTransport
    private let retryDelay: TimeInterval
    private let log: (String) -> Void

    init(
        transport: HTTPTransport = URLSessionTransport(),
        retryDelay: TimeInterval = SessionAPI.defaultRetryDelay,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.retryDelay = retryDelay
        self.log = log
    }

    /// Blocking — call from a background queue. Returns nil on failure.
    func fetchOneTimeToken(config: ClarityConfig, appId: String) -> String? {
        lastHttpCode = nil
        // Status of the FINAL attempt, published only once the whole call has
        // failed: a retried 5xx that eventually succeeds must leave both
        // `lastError` and `lastHttpCode` clear, but a run that never gets past
        // HTTP 500 must report 500 — not the "no HTTP response" sentinel the
        // engine derives from a nil code (which classified a server that
        // answered every time as an offline device).
        var finalHttpCode: Int?
        for attempt in 0..<Self.maxAttempts {
            do {
                let token = try requestToken(config: config, appId: appId)
                lastError = nil
                return token
            } catch let status as HTTPStatusError where status.isRejection {
                // The platform answered and said no — retrying is pointless.
                // (Non-rejection statuses fall through to the generic catch
                // below and retry, e.g. a transient 5xx.)
                log("session/unverified rejected: HTTP \(status.httpCode)")
                lastError = status.description
                lastHttpCode = status.httpCode
                return nil
            } catch {
                log("session/unverified attempt \(attempt + 1) failed: \(error)")
                lastError = String(describing: error)
                // nil for transport/parse errors, so both fields always
                // describe the same (final) attempt.
                finalHttpCode = (error as? HTTPStatusError)?.httpCode
                if attempt < Self.maxAttempts - 1, retryDelay > 0 {
                    Thread.sleep(forTimeInterval: retryDelay)
                }
            }
        }
        lastHttpCode = finalHttpCode
        return nil
    }

    private struct HTTPStatusError: Error, CustomStringConvertible {
        let httpCode: Int
        /// 4xx: the platform rejected the credentials — non-recoverable,
        /// never retried. Anything else non-200 retries.
        var isRejection: Bool { SessionAPI.rejectionStatusRange.contains(httpCode) }
        var description: String { "session/unverified returned HTTP \(httpCode)" }
    }

    private func requestToken(config: ClarityConfig, appId: String) throws -> String {
        let base = WidgetURL.trimTrailingSlashes(config.baseUrl)
        let urlString = "\(base)\(Self.unverifiedSessionPath)"
            + "?organization_id=\(FormURLEncoder.encode(config.organizationId))"
            + "&integration_key=\(FormURLEncoder.encode(config.integrationKey))"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        // iOS SDK channels are matched by these headers.
        var headers = [
            "x-os": ClarityPlatform.identifier,
            "x-app-id": appId,
        ]
        // Web-widget channels are matched by the Origin host instead.
        if let host = config.channelHost {
            headers["Origin"] = Self.normalizedOrigin(host)
        }

        let (code, body) = try transport.get(url: url, headers: headers, timeout: Self.timeout)
        guard code == 200 else { throw HTTPStatusError(httpCode: code) }

        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let token = json["one_time_token"] as? String
        else {
            throw URLError(.cannotParseResponse)
        }
        return token
    }

    /// `Origin: scheme://host` with no trailing slash — an HTTP header value,
    /// not a widget URL (hence its own helper, not more `WidgetURL` duty).
    private static func normalizedOrigin(_ host: String) -> String {
        let origin = host.contains("://") ? host : "https://\(host)"
        return WidgetURL.trimTrailingSlashes(origin)
    }

    /// Shared with the engine's handshake debug line.
    static let unverifiedSessionPath = "/api/live-chat/session/unverified"
    static let defaultRetryDelay: TimeInterval = 0.3
    /// 4xx = the platform rejected the credentials. Internal (not private):
    /// `ClarityError.Kind.forHandshakeFailure` classifies with the same range
    /// so retry policy and error classification can never disagree.
    static let rejectionStatusRange = 400...499
    private static let maxAttempts = 3
    private static let timeout: TimeInterval = 10
}
