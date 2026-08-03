import Foundation

/// Single source of truth for the widget page URL. The real load path and the
/// public preview API (`Clarity.previewWidgetUrl`) both build through here, so
/// a preview always shows exactly what the SDK will load.
///
/// Port of the Android SDK's `WidgetUrl.kt` — parameter order and encoding are
/// intentionally identical; the only difference is `nativeMode=ios`.
enum WidgetURL {

    static func build(
        config: ClarityConfig,
        user: ClarityUser,
        userAttributes: [String: ClarityAttributeValue],
        ticketAttributes: [String: ClarityAttributeValue],
        oneTimeToken: String
    ) -> String {
        var params: [(String, String)] = [
            ("oneTimeToken", oneTimeToken),
            ("nativeMode", ClarityPlatform.identifier),
            ("layout", "mobile"),
            ("placement", "right"),
            ("identity", "unverified"),
            // Same defaults the web embed snippet passes; the page maps
            // widgetType to the backend live_chat_type field and uses
            // organizationId for brand customization.
            ("mode", "live_chat"),
            ("widgetType", "live_chat"),
            ("organizationId", config.organizationId),
            ("integrationKey", config.integrationKey),
            ("sdkVersion", ClarityVersion.current),
        ]
        if let language = config.language { params.append(("language", language)) }
        if let externalId = user.externalId { params.append(("externalId", externalId)) }
        if let firstName = user.firstName { params.append(("firstName", firstName)) }
        if let lastName = user.lastName { params.append(("lastName", lastName)) }
        if let email = user.email { params.append(("email", email)) }
        if let phone = user.phone { params.append(("phone", phone)) }
        if let avatar = user.avatar { params.append(("avatar", avatar)) }
        if let userHash = user.userHash { params.append(("userHash", userHash)) }
        // Append order is frozen: user attributes before ticket attributes,
        // matching Android and the e2e-pinned URL shape.
        appendAttributes(userAttributes, scope: .user, to: &params)
        appendAttributes(ticketAttributes, scope: .ticket, to: &params)
        let query = params
            .map { "\($0.0)=\(FormURLEncoder.encode($0.1))" }
            .joined(separator: "&")
        return "\(trimTrailingSlashes(config.baseUrl))/?\(query)"
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
