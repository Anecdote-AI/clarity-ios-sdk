import Foundation

/// Single source of truth for the widget page URL. The real load path and the
/// public preview API (`Clarity.previewWidgetUrl`) both build through here, so
/// a preview always shows exactly what the SDK will load.
///
/// Port of the Android SDK's `WidgetUrl.kt` — parameter order and encoding are
/// intentionally identical; the only difference is `nativeMode=ios`.
enum WidgetURL {

    /// Comma-separated capabilities the page may rely on (live-chat
    /// `nativeSdkBridge.ts`) — same spelling as Android's `WidgetUrl.kt`.
    static let nativeCapabilitiesParam = "nativeCapabilities"
    static let microphoneCapability = "microphone"

    static func build(
        config: ClarityConfig,
        user: ClarityUser,
        userAttributes: [String: ClarityAttributeValue],
        ticketAttributes: [String: ClarityAttributeValue],
        oneTimeToken: String,
        microphoneAvailable: Bool
    ) -> String {
        var params: [(String, String)] = [
            ("oneTimeToken", oneTimeToken),
            ("nativeMode", ClarityPlatform.identifier),
            ("layout", "mobile"),
            ("placement", "right"),
            ("identity", user.jwt == nil ? "unverified" : "verified"),
            // Same defaults the web embed snippet passes; the page maps
            // widgetType to the backend live_chat_type field and uses
            // organizationId for brand customization.
            ("mode", "live_chat"),
            ("widgetType", "live_chat"),
            ("organizationId", config.organizationId),
            ("integrationKey", config.integrationKey),
            ("sdkVersion", ClarityVersion.current),
        ]
        // Tells the page this SDK can hand it the microphone (the host
        // carries NSMicrophoneUsageDescription, so the getUserMedia gate
        // prompts instead of denying). SDK builds that predate the param
        // never send it, so the page keeps voice and dictation hidden there.
        if microphoneAvailable {
            params.append((nativeCapabilitiesParam, microphoneCapability))
        }
        if let language = config.language { params.append(("language", language)) }
        if let externalId = user.externalId { params.append(("externalId", externalId)) }
        if let firstName = user.firstName { params.append(("firstName", firstName)) }
        if let lastName = user.lastName { params.append(("lastName", lastName)) }
        if let email = user.email { params.append(("email", email)) }
        if let phone = user.phone { params.append(("phone", phone)) }
        if let avatar = user.avatar { params.append(("avatar", avatar)) }
        if let userHash = user.legacyUserHash { params.append(("userHash", userHash)) }
        // Append order is frozen: user attributes before ticket attributes,
        // matching Android and the e2e-pinned URL shape.
        appendAttributes(userAttributes, scope: .user, to: &params)
        appendAttributes(ticketAttributes, scope: .ticket, to: &params)
        let query = params
            .map { "\($0.0)=\(FormURLEncoder.encode($0.1))" }
            .joined(separator: "&")
        let url = "\(trimTrailingSlashes(config.baseUrl))/?\(query)"
        // The signed token the host's backend minted; the page forwards it to
        // the session handshake, which is what makes the identity verified.
        // It rides the FRAGMENT, never the query: WebKit never sends the
        // fragment to the server, so the token stays out of the request line
        // that nginx and the ingress write to their access logs (and a long
        // one cannot overflow it into a 414). The page reads it from
        // `location.hash` and strips it. Same spelling as Android.
        guard let jwt = user.jwt else { return url }
        return "\(url)#\(jwtFragmentName)=\(FormURLEncoder.encode(jwt))"
    }

    /// The fragment key the page reads the identity token from (live-chat
    /// `identityTokenUrl.ts`) — same spelling as Android's `WidgetUrl.kt`.
    static let jwtFragmentName = "jwt"

    private static let redactedURLPrefixLength = 160

    /// A URL as it may be logged: cut before the query — it can carry the
    /// one-time token or, for attachment URLs, signed access credentials —
    /// and before the fragment, which carries the identity token.
    static func redactedForLog(_ absoluteURL: String) -> String {
        String(absoluteURL.prefix { $0 != "?" && $0 != "#" }.prefix(redactedURLPrefixLength))
    }

    /// One scope's attributes as a JSON query param — omitted entirely when
    /// nothing can ride the URL. The page's parser accepts primitive values
    /// only and rejects the whole object otherwise, so list values, removals
    /// and non-finite doubles (not JSON — one would void the whole param)
    /// are filtered out here; they reach the platform via the page-loaded
    /// bridge flush instead.
    private static func appendAttributes(
        _ attributes: [String: ClarityAttributeValue],
        scope: AttributeScope,
        to params: inout [(String, String)]
    ) {
        let urlAttributes = ClarityAttributeValue
            .droppingNonFiniteValues(attributes)
            .compactMapValues { $0.urlPrimitive }
        guard !urlAttributes.isEmpty else { return }
        params.append((scope.urlQueryName, JSONEncoding.objectString(urlAttributes)))
    }

    static func trimTrailingSlashes(_ url: String) -> String {
        var trimmed = Substring(url)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
