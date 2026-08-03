#if canImport(UIKit)
import Foundation
import WebKit

/// Wipes the WIDGET's web session — cookies, origin storage, caches — and
/// nothing else. The widget shares the default `WKWebsiteDataStore` with any
/// WebView the host app runs for its own authenticated content, so a blanket
/// `removeData(ofTypes:modifiedSince:)` is forbidden (Android parity: never
/// `removeAllCookies`). Everything is scoped to the widget host's domains.
/// Main-thread confined by convention — see `MainThread`.
enum WebSessionCleaner {

    /// Deletes cookies whose domain matches the widget host or any parent
    /// domain (`Domain=`-scoped cookies live there), plus website-data
    /// records keyed by the host's registrable domain (WebKit groups records
    /// by eTLD+1 — coarser than an origin; acceptable because a customer's
    /// live-chat domain does not host unrelated app content).
    static func clear(baseUrl: String, completion: @escaping () -> Void) {
        guard let host = URL(string: baseUrl)?.host, !host.isEmpty else {
            completion()
            return
        }

        let domains = domainWalk(host: host)
        let store = WKWebsiteDataStore.default()
        let group = DispatchGroup()

        group.enter()
        deleteCookies(matching: domains, host: host, in: store) { group.leave() }

        group.enter()
        deleteRecords(matching: domains, host: host, in: store) { group.leave() }

        group.notify(queue: .main, execute: completion)
    }

    /// Cookies delete one by one (no bulk API) — an inner group joins the
    /// per-cookie completions. Calls `completion` exactly once on every path.
    private static func deleteCookies(
        matching domains: Set<String>,
        host: String,
        in store: WKWebsiteDataStore,
        completion: @escaping () -> Void
    ) {
        store.httpCookieStore.getAllCookies { cookies in
            let doomed = cookies.filter { cookie in
                let cookieDomain = cookie.domain.hasPrefix(".")
                    ? String(cookie.domain.dropFirst())
                    : cookie.domain
                return domains.contains(cookieDomain) || cookieDomain == host
            }
            guard !doomed.isEmpty else {
                completion()
                return
            }
            let inner = DispatchGroup()
            for cookie in doomed {
                inner.enter()
                store.httpCookieStore.delete(cookie) { inner.leave() }
            }
            inner.notify(queue: .main) { completion() }
        }
    }

    /// Website-data records delete in one batch call. Calls `completion`
    /// exactly once on every path.
    private static func deleteRecords(
        matching domains: Set<String>,
        host: String,
        in store: WKWebsiteDataStore,
        completion: @escaping () -> Void
    ) {
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let doomed = records.filter { record in
                domains.contains(record.displayName) || record.displayName == host
            }
            guard !doomed.isEmpty else {
                completion()
                return
            }
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: doomed
            ) { completion() }
        }
    }

    /// host + every parent that still looks registrable: mirrors Android's
    /// walk (`while domain has >= 2 dots, strip the left label`), plus the
    /// eTLD+1 that WebKit uses as a record display name.
    static func domainWalk(host: String) -> Set<String> {
        var domains: Set<String> = [host]
        var domain = host
        while domain.filter({ $0 == "." }).count >= 2 {
            domain = String(domain.drop(while: { $0 != "." }).dropFirst())
            domains.insert(domain)
        }
        return domains
    }
}
#endif
