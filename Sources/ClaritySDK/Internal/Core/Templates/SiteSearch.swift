import Foundation

/// The organization's website (`ClarityToolTemplates.SiteSearch.siteURL`):
/// what counts as one of its pages. HTTPS and the site's own origin only.
enum SiteAddress {

    static func problem(siteURL: URL) -> String? {
        guard siteURL.scheme?.lowercased() == "https", let host = siteURL.host, !host.isEmpty else {
            return "siteURL must be an https:// address"
        }
        return nil
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port.map { $0 == 443 && scheme == "https" ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    static func isSameOrigin(_ url: URL, _ other: URL) -> Bool {
        guard let a = origin(url) else { return false }
        return a == origin(other)
    }

    /// A path or a full URL, as one of the site's pages over HTTPS; nil for
    /// any other origin or scheme. A relative path resolves against `base`.
    static func sameOriginURL(_ href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              isSameOrigin(url, base)
        else { return nil }
        // The fragment is a place on the page, never another page.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.url
    }

    /// The path and query, as the agent is given a page of the site.
    static func pathOf(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return path + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    /// The search URL with `{query}`, made absolute, when it is on the site.
    /// Its placeholders stay as written.
    static func searchTemplate(_ value: String, siteURL: URL) -> String? {
        guard value.contains("{query}"),
              sameOriginURL(value.replacingOccurrences(of: "{query}", with: "x"), base: siteURL) != nil
        else { return nil }
        // Placeholders swapped for plain markers while the URL is resolved,
        // so their braces are not percent-encoded.
        var placeholders: [String] = []
        var marked = ""
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            marked += rest[rest.startIndex..<open] + "clarityplaceholder\(placeholders.count)x"
            placeholders.append(String(rest[open...close]))
            rest = rest[rest.index(after: close)...]
        }
        marked += rest
        guard var absolute = URL(string: marked, relativeTo: siteURL)?.absoluteString else { return nil }
        for (index, placeholder) in placeholders.enumerated() {
            absolute = absolute.replacingOccurrences(of: "clarityplaceholder\(index)x", with: placeholder)
        }
        return absolute
    }

    /// The search URL for these words: `{query}` URL-encoded as
    /// `encodeURIComponent` does, optional placeholders (`{startPage?}`) dropped.
    static func fillSearch(_ template: String, query: String, siteURL: URL) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: componentCharacters) ?? query
        var filled = template.replacingOccurrences(of: "{query}", with: encoded)
        while let open = filled.range(of: "{"), let close = filled.range(of: "?}", range: open.upperBound..<filled.endIndex) {
            filled.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return sameOriginURL(filled, base: siteURL)
    }

    // encodeURIComponent leaves A–Z a–z 0–9 - _ . ! ~ * ' ( ) unescaped.
    private static let componentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    /// A link on an app screen, as `read_page` lists it: the path when it is
    /// on the site's origin (so `read_link` takes it), else the full URL.
    static func linkPath(_ href: String, siteURL: URL?) -> String {
        if let siteURL, URL(string: href)?.scheme != nil, let url = sameOriginURL(href, base: siteURL) {
            return pathOf(url)
        }
        return href
    }
}

/// One file of the website, as the fetcher got it.
struct SiteResponse {
    /// After redirects.
    let url: URL
    let contentType: String
    let body: Data
}

/// Fetches a file of the website: over HTTPS, on its origin, without
/// cookies (`SiteFetcher` in the app; a fake serving the golden fixtures in
/// the tests). Answers once, on any thread, with the file or why not.
protocol SiteFetching {
    func fetch(_ url: URL, completion: @escaping (Result<SiteResponse, SiteFetchError>) -> Void)
}

struct SiteFetchError: Error, Equatable {
    let message: String
}

/// `find_on_site` and `read_link` over a fetcher (the web's `siteSearch.ts`
/// and `sitemap.ts`). Results go to `completion` once, as the tool's result
/// or as the error the agent is given.
final class SiteSearchTools {

    static let maxResults = 10
    static let maxTextLength = 3000
    static let maxTitleLength = 200
    static let maxListedPages = 100

    static let drawnByScript = "is drawn by JavaScript in the browser, so it cannot be read without opening it"
    static let lookElsewhere = "Look at the links read_page returns instead."

    enum Source: String {
        case option
        case sitemap
    }

    private let siteURL: URL
    private let searchTemplate: String?
    private let fetcher: SiteFetching

    init(siteURL: URL, searchURL: String?, fetcher: SiteFetching) {
        self.siteURL = siteURL
        self.searchTemplate = searchURL.flatMap { SiteAddress.searchTemplate($0, siteURL: siteURL) }
        self.fetcher = fetcher
    }

    var host: String { siteURL.host ?? "" }

    // MARK: - find_on_site

    func find(query rawQuery: String?, completion: @escaping (Result<[String: Any], SiteFetchError>) -> Void) {
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            listPages(completion: completion)
            return
        }
        guard let template = searchTemplate, let url = SiteAddress.fillSearch(template, query: query, siteURL: siteURL) else {
            sitemapAnswer(query: query, resultsDrawnByScript: false, completion: completion)
            return
        }
        fetchPage(url) { [self] result in
            guard case .success(let (page, finalURL)) = result else {
                // The search answered with an error: the sitemap may still know.
                sitemapAnswer(query: query, resultsDrawnByScript: false, completion: completion)
                return
            }
            let ownPath = Self.decodedPath(finalURL)
            var seen = Set<String>()
            var results: [[String: Any]] = []
            for link in page.links() {
                guard results.count < Self.maxResults,
                      let target = SiteAddress.sameOriginURL(link.href, base: finalURL)
                else { continue }
                let path = SiteAddress.pathOf(target)
                // Links back to the search itself (pagination, filters) are
                // not results: the same path, whatever the query. Equal, not
                // a prefix — a search at "/" (WordPress's "/?s=") or at
                // "/search" must keep the pages under it ("/search-tips").
                if Self.decodedPath(target) == ownPath || !seen.insert(path).inserted { continue }
                results.append(["text": String(link.text.prefix(80)), "path": path])
            }
            if results.isEmpty && page.isScriptShell {
                sitemapAnswer(query: query, resultsDrawnByScript: true, completion: completion)
                return
            }
            completion(.success([
                "results_page": SiteAddress.pathOf(url),
                "found_via": Source.option.rawValue,
                "results": results,
            ]))
        }
    }

    private func sitemapAnswer(
        query: String,
        resultsDrawnByScript: Bool,
        completion: @escaping (Result<[String: Any], SiteFetchError>) -> Void
    ) {
        sitemapPaths { paths in
            let matched = Sitemap.pathsMatching(paths, query: query, limit: Self.maxResults)
            if !matched.isEmpty {
                completion(.success([
                    "found_via": Source.sitemap.rawValue,
                    "note": "Matched by page address only.",
                    "results": matched.map { ["path": $0] },
                ]))
                return
            }
            let why = resultsDrawnByScript
                ? "This site's search results page \(Self.drawnByScript)"
                : "This site publishes no search"
            completion(.success([
                "results": [Any](),
                "note": "\(why), and no page address in its sitemap matches. \(Self.lookElsewhere)",
            ]))
        }
    }

    private func listPages(completion: @escaping (Result<[String: Any], SiteFetchError>) -> Void) {
        sitemapPaths { paths in
            if paths.isEmpty {
                completion(.success([
                    "total": 0,
                    "pages": [Any](),
                    "note": "This site publishes no sitemap. \(Self.lookElsewhere)",
                ]))
            } else {
                completion(.success(["total": paths.count, "pages": Array(paths.prefix(Self.maxListedPages))]))
            }
        }
    }

    /// Every page the site's sitemaps list, as paths, in their order: an
    /// index is followed a few files deep. Never fails: no sitemap is no pages.
    func sitemapPaths(completion: @escaping ([String]) -> Void) {
        guard let robotsURL = SiteAddress.sameOriginURL("/robots.txt", base: siteURL) else {
            completion([])
            return
        }
        fetcher.fetch(robotsURL) { [self] result in
            let robots: String? = {
                guard case .success(let response) = result else { return nil }
                return String(decoding: response.body, as: UTF8.self)
            }()
            var queue = Sitemap.sitemapURLs(robots: robots, siteURL: siteURL)
            var seenSitemaps = Set<String>()
            var paths: [String] = []
            var seenPaths = Set<String>()

            func next() {
                while let url = queue.first, seenSitemaps.contains(url.absoluteString) {
                    queue.removeFirst()
                }
                guard let url = queue.first, seenSitemaps.count < Sitemap.maxSitemaps else {
                    completion(paths)
                    return
                }
                queue.removeFirst()
                seenSitemaps.insert(url.absoluteString)
                fetcher.fetch(url) { result in
                    if case .success(let response) = result, let file = Sitemap.parse(response.body) {
                        switch file {
                        case .index(let locs):
                            queue.append(contentsOf: locs
                                .compactMap { SiteAddress.sameOriginURL($0, base: self.siteURL) }
                                .filter { !Sitemap.isCompressed($0) })
                        case .pages(let locs):
                            for loc in locs {
                                guard paths.count < Sitemap.maxPages,
                                      let page = SiteAddress.sameOriginURL(loc, base: self.siteURL)
                                else { continue }
                                let path = SiteAddress.pathOf(page)
                                if seenPaths.insert(path).inserted { paths.append(path) }
                            }
                        }
                    }
                    next()
                }
            }
            next()
        }
    }

    // MARK: - read_link

    func read(path: String, completion: @escaping (Result<[String: Any], SiteFetchError>) -> Void) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(SiteFetchError(message: "path is required")))
            return
        }
        guard let url = SiteAddress.sameOriginURL(trimmed, base: siteURL) else {
            completion(.failure(SiteFetchError(message: "only pages of \(host) can be read")))
            return
        }
        fetchPage(url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (page, _)):
                if page.isScriptShell {
                    completion(.success([
                        "path": SiteAddress.pathOf(url),
                        "readable": false,
                        "note": "This page \(Self.drawnByScript).",
                    ]))
                    return
                }
                let result: [String: Any] = [
                    "path": SiteAddress.pathOf(url),
                    "title": String(page.title.prefix(Self.maxTitleLength)),
                    "text": page.mainText(limit: Self.maxTextLength),
                ]
                completion(.success(Self.withStructuredData(result, page.structuredData)))
            }
        }
    }

    /// The schema.org items, only while the result stays within
    /// `PageResults.maxResultBytes`; the ones left out are named, as the
    /// web's `read_page` does. A long FAQPage alone used to push the result
    /// past the 16 KB a result may take, and the agent lost the whole page.
    static func withStructuredData(_ base: [String: Any], _ items: [[String: Any]]) -> [String: Any] {
        var result = PageResults.trim(base)
        guard !items.isEmpty else { return result }
        var kept: [[String: Any]] = []
        for item in items {
            var candidate = result
            candidate["structured_data"] = kept + [item]
            if PageResults.byteSize(candidate) <= PageResults.maxResultBytes { kept.append(item) }
        }
        if !kept.isEmpty { result["structured_data"] = kept }
        if kept.count < items.count {
            result["left_out"] = [
                "structured_data: \(items.count - kept.count) of \(items.count) items, too large for one read",
            ]
        }
        return result
    }

    /// The URL's path, percent-decoded, "/" when empty.
    private static func decodedPath(_ url: URL) -> String {
        url.path.isEmpty ? "/" : url.path
    }

    private func fetchPage(_ url: URL, completion: @escaping (Result<(HTMLDocument, URL), SiteFetchError>) -> Void) {
        fetcher.fetch(url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let html = String(decoding: response.body, as: UTF8.self)
                completion(.success((HTMLDocument(html: html), response.url)))
            }
        }
    }
}
