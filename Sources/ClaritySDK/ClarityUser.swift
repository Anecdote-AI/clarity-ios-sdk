/// The identity the host app knows the current user by. All fields are
/// optional — an empty `ClarityUser()` represents an anonymous visitor.
///
/// `userHash` is the HMAC-SHA256 of `externalId` computed with the
/// organization's verification secret **on the host's backend** — never ship
/// the secret inside the app.
public struct ClarityUser: Equatable, Sendable {
    public var externalId: String?
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var phone: String?
    public var avatar: String?
    public var userHash: String?

    public init(
        externalId: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        avatar: String? = nil,
        userHash: String? = nil
    ) {
        self.externalId = externalId
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.avatar = avatar
        self.userHash = userHash
    }
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
