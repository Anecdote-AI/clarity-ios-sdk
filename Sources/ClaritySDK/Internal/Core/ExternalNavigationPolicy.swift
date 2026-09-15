import Foundation

/// "Does this navigation leave the widget WebView for the browser?"
///
/// Lives here rather than inline in the `WKNavigationDelegate` because
/// `WKNavigationAction` cannot be constructed in a test: as a free function
/// over plain values the rule is reachable from the pure-Swift suite that runs
/// on every push, instead of only from the simulator suite.
enum ExternalNavigationPolicy {

    /// - Parameters:
    ///   - url: the navigation's target. Host-less URLs (`about:blank`,
    ///     `data:`) always stay inside — they are the page's own plumbing.
    ///   - baseUrl: the configured widget origin; an unparseable or
    ///     non-http(s) value disables the hand-off rather than sending
    ///     everything to the browser.
    ///   - isSubframe: whether the navigation targets a nested frame. An html
    ///     widget is a sandboxed iframe whose `src` redirects to presigned
    ///     object storage — cross-origin BY DESIGN — so treating a sub-frame
    ///     load as a followed link cancels the widget and opens its document
    ///     in the browser. Only a main-frame navigation, or a new window
    ///     (`target=_blank`, which has no target frame at all), is a link.
    static func shouldOpenExternally(
        url: URL,
        baseUrl: String?,
        isSubframe: Bool
    ) -> Bool {
        guard !isSubframe,
              url.host != nil,
              let base = baseUrl.flatMap({ URL(string: $0) }),
              base.isWebLink,
              base.host != nil
        else { return false }

        return !url.isSameOrigin(as: base)
    }
}
