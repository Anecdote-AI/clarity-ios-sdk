import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches the organization's public website for `find_on_site` and
/// `read_link`: HTTPS only, its own origin only (redirects followed by hand,
/// at most 3, and only on the origin), no cookies sent or kept, 10 s, at most
/// 2 MB, HTML, XML or plain text only. Off the main thread.
///
/// The body is streamed through the delegate and the task is cancelled as
/// soon as it is known to be too large (a `Content-Length` over the limit, or
/// the bytes received so far), so a huge file is never held in the host
/// app's memory. Foundation only, so `swift test` covers it.
final class SiteFetcher: NSObject, SiteFetching, URLSessionDataDelegate {

    static let timeoutSeconds: TimeInterval = 10
    static let maxBytes = 2 * 1024 * 1024
    static let maxRedirects = 3

    typealias Completion = (Result<SiteResponse, SiteFetchError>) -> Void

    /// One request in flight.
    private final class Pending {
        let url: URL
        let redirectsLeft: Int
        let completion: Completion
        var contentType = ""
        var body = Data()

        init(url: URL, redirectsLeft: Int, completion: @escaping Completion) {
            self.url = url
            self.redirectsLeft = redirectsLeft
            self.completion = completion
        }
    }

    let siteURL: URL
    private let protocolClasses: [AnyClass]?
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var sessionMade = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        configuration.timeoutIntervalForResource = Self.timeoutSeconds
        configuration.httpAdditionalHeaders = [
            "User-Agent": "ClaritySDK/\(ClarityVersion.current) (\(ClarityPlatform.identifier))",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8",
        ]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        sessionMade = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// `protocolClasses`: for tests, a stub `URLProtocol` that answers instead of the network.
    init(siteURL: URL, protocolClasses: [AnyClass]? = nil) {
        self.siteURL = siteURL
        self.protocolClasses = protocolClasses
    }

    /// The fetcher is replaced (the website changed): its session, which
    /// holds this object as its delegate until invalidated, is let go once
    /// the requests in flight finish.
    func invalidate() {
        lock.lock()
        let made = sessionMade
        lock.unlock()
        if made { session.finishTasksAndInvalidate() }
    }

    func fetch(_ url: URL, completion: @escaping Completion) {
        fetch(url, redirectsLeft: Self.maxRedirects, completion: completion)
    }

    private func fetch(_ url: URL, redirectsLeft: Int, completion: @escaping Completion) {
        guard url.scheme?.lowercased() == "https", SiteAddress.isSameOrigin(url, siteURL) else {
            completion(.failure(SiteFetchError(message: "only pages of \(siteURL.host ?? "the website") can be read")))
            return
        }
        lock.lock()
        let task = session.dataTask(with: url)
        pending[task.taskIdentifier] = Pending(url: url, redirectsLeft: redirectsLeft, completion: completion)
        lock.unlock()
        task.resume()
    }

    /// A response header, by case-insensitive name (`value(forHTTPHeaderField:)`
    /// needs macOS 10.15, and `swift test` builds for older).
    static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        let wanted = name.lowercased()
        return response.allHeaderFields.first { ($0.key as? String)?.lowercased() == wanted }?.value as? String
    }

    static func isReadable(_ contentType: String) -> Bool {
        contentType.isEmpty || contentType.contains("html") || contentType.contains("xml") || contentType.hasPrefix("text/plain")
    }

    /// Removes the request's state: the one place that answers, once.
    private func take(_ task: URLSessionTask) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: task.taskIdentifier)
    }

    private func current(_ task: URLSessionTask) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        return pending[task.taskIdentifier]
    }

    /// Answers and stops the task (its own completion then finds nothing).
    private func finish(_ task: URLSessionTask, _ result: (Pending) -> Result<SiteResponse, SiteFetchError>) {
        guard let request = take(task) else { return }
        task.cancel()
        request.completion(result(request))
    }

    // MARK: URLSessionDataDelegate

    // Redirects are followed by hand, so each hop is checked: the 3xx comes
    // back as the response.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let request = current(dataTask) else {
            completionHandler(.cancel)
            return
        }
        let path = SiteAddress.pathOf(request.url)
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(dataTask) { _ in .failure(SiteFetchError(message: "\(path) could not be fetched")) }
            return
        }
        if (300..<400).contains(http.statusCode), let location = Self.header("Location", in: http) {
            completionHandler(.cancel)
            guard let request = take(dataTask) else { return }
            guard request.redirectsLeft > 0, let next = SiteAddress.sameOriginURL(location, base: request.url) else {
                request.completion(.failure(SiteFetchError(message: "\(path) redirects off the website")))
                return
            }
            fetch(next, redirectsLeft: request.redirectsLeft - 1, completion: request.completion)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(dataTask) { _ in .failure(SiteFetchError(message: "\(path) answered \(http.statusCode)")) }
            return
        }
        let type = (Self.header("Content-Type", in: http) ?? "").lowercased()
        guard Self.isReadable(type) else {
            completionHandler(.cancel)
            finish(dataTask) { _ in .failure(SiteFetchError(message: "\(path) is not a web page")) }
            return
        }
        guard http.expectedContentLength <= Int64(Self.maxBytes) else {
            completionHandler(.cancel)
            finish(dataTask) { _ in .failure(SiteFetchError(message: "\(path) is too large to read")) }
            return
        }
        lock.lock()
        request.contentType = type
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let request = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        request.body.append(data)
        let tooLarge = request.body.count > Self.maxBytes
        lock.unlock()
        if tooLarge {
            finish(dataTask) { _ in .failure(SiteFetchError(message: "\(SiteAddress.pathOf(request.url)) is too large to read")) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = take(task) else { return }
        let path = SiteAddress.pathOf(request.url)
        if let error {
            request.completion(.failure(SiteFetchError(message: "\(path) could not be fetched: \(error.localizedDescription)")))
        } else {
            request.completion(.success(SiteResponse(url: request.url, contentType: request.contentType, body: request.body)))
        }
    }
}
