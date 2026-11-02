/// The identity the host app knows the current user by. All fields are
/// optional — an empty `ClarityUser()` represents an anonymous visitor.
///
/// To prove who the user is, set `jwt` to a token your own backend signs with
/// the channel's identity secret (see the README). The SDK only carries the
/// token to the widget — never ship the secret inside the app.
public struct ClarityUser: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var externalId: String?
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var phone: String?
    public var avatar: String?

    /// A JWT your backend signs with the channel's identity secret. The SDK
    /// only carries it — never embed the secret in the app.
    public var jwt: String?

    /// - Warning: Deprecated and not verified by the platform. Use `jwt`.
    @available(*, deprecated, message: "Not verified by the platform. Use `jwt`.")
    public var userHash: String? {
        get { legacyUserHash }
        set { legacyUserHash = newValue }
    }

    /// Backing storage, so the SDK itself can keep forwarding the deprecated
    /// field to older integrations without tripping its own deprecation.
    var legacyUserHash: String?

    public init(
        externalId: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        avatar: String? = nil,
        jwt: String? = nil,
        userHash: String? = nil
    ) {
        self.externalId = externalId
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.avatar = avatar
        self.jwt = jwt
        self.legacyUserHash = userHash
    }

    /// The token is a credential: it must not reach a log line or a crash
    /// report through string interpolation of the user.
    public var description: String {
        let fields = [
            externalId.map { "externalId: \($0)" },
            email.map { "email: \($0)" },
            jwt.map { _ in "jwt: <redacted>" },
        ].compactMap { $0 }
        return "ClarityUser(\(fields.joined(separator: ", ")))"
    }

    public var debugDescription: String { description }
}

extension ClarityUser {
    /// Whether re-identifying as `next` must wipe the widget web session.
    /// Isolation is decided by the STABLE identity key alone: switching to a
    /// different `externalId` (or dropping it — a de-identification) is an
    /// account switch; changed profile fields on the same key are an update,
    /// not a logout. An anonymous session (`externalId == nil`) is never
    /// wiped — the platform merges the visitor into the identified user.
    func requiresSessionIsolation(switchingTo next: ClarityUser) -> Bool {
        guard let previousId = externalId else { return false }
        return previousId != next.externalId
    }
}
