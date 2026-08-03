import Foundation

extension URL {
    /// The only schemes the SDK ever hands to the external browser or the
    /// native image preview.
    var isWebLink: Bool {
        scheme == "http" || scheme == "https"
    }

    /// Same WEB ORIGIN — scheme, host and effective port must all match, so
    /// `https://chat.example.com` ≡ `https://chat.example.com:443` but NOT
    /// `https://chat.example.com:8443` and NOT `http://chat.example.com`.
    ///
    /// The navigation policy keeps same-origin URLs inside the widget WebView
    /// and hands everything else to the browser; comparing only `host` would
    /// let a port or scheme change replace the live conversation instead.
    func isSameOrigin(as other: URL) -> Bool {
        guard let scheme = scheme?.lowercased(),
              let otherScheme = other.scheme?.lowercased(),
              let host = host?.lowercased(),
              let otherHost = other.host?.lowercased()
        else { return false }

        return scheme == otherScheme
            && host == otherHost
            && URL.effectivePort(scheme: scheme, port: port)
                == URL.effectivePort(scheme: otherScheme, port: other.port)
    }

    /// The URL's web origin as a URL (`scheme://host[:port]/`), nil when
    /// scheme or host is missing. An explicit port is part of the origin —
    /// dropping it (https://host:8443 vs https://host) would make requests
    /// against the result cross-origin.
    var originURL: URL? {
        guard let scheme, let host else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = port
        origin.path = "/"
        return origin.url
    }

    /// An omitted port means the scheme's default one — otherwise the same
    /// origin written two legal ways would compare unequal.
    private static func effectivePort(scheme: String, port: Int?) -> Int? {
        if let port { return port }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
