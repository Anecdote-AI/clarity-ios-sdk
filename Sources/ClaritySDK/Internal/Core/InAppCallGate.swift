import Foundation

extension ClarityToolKind {
    /// How much the customer was asked before a call of this kind ran:
    /// a read asks nothing, a safe action runs at once, an action waits for
    /// the customer's Allow on a card.
    var rank: Int {
        switch self {
        case .read: return 0
        case .safeAction: return 1
        case .action: return 2
        }
    }

    /// The kind the page says it treated a call as. Missing or unknown is a
    /// read — the least the page can claim, so it never unlocks more.
    static func fromPage(_ value: Any?) -> ClarityToolKind {
        (value as? String).flatMap(ClarityToolKind.init(rawValue:)) ?? .read
    }
}

/// What the SDK checks itself before an in-app tool runs, instead of trusting
/// that the page did it:
///
///  - **Kind floor.** The page says how it treated the call (`kind`). A call
///    treated as less than the kind the app registered — an action that ran
///    without a card, say — is refused with `kind_mismatch`.
///  - **Security check bound natively.** A tool registered with
///    `requiresSecurityCheck` runs only against a pass from a security check
///    this SDK ran and that passed: one pass per step, used once, expiring
///    `passLifetime` after the check. Bound to the step's call id when the
///    page sends `callIds`; counted per tool name for an older page that does
///    not. A check that failed, was cancelled or timed out records nothing,
///    and so does one whose `callIds` do not pair up with its steps.
///
/// Expiry runs on a monotonic clock (`systemUptime`), so moving the device's
/// clock neither stretches a pass nor cuts one short.
///
/// Thread-safe: the app's security-check answer may come from any thread.
final class InAppCallGate {

    static let errorKindMismatch = "kind_mismatch"
    static let errorSecurityCheckRequired = "security_check_required"

    /// How long a passed security check covers the card's steps.
    static let passLifetime: TimeInterval = 10 * 60

    private let lock = NSLock()
    /// Seconds on a monotonic clock; only differences are meaningful.
    private let now: () -> TimeInterval
    /// call id → the tool the pass is for, and when it expires.
    private var passesByCallId: [String: (name: String, expires: TimeInterval)] = [:]
    /// tool name → the expiry of each pass recorded for it (older pages).
    private var passesByName: [String: [TimeInterval]] = [:]

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Whether a call the page treated as `called` may run a tool registered
    /// as `registered`.
    static func kindAllows(called: ClarityToolKind, registered: ClarityToolKind) -> Bool {
        called.rank >= registered.rank
    }

    /// A security check passed for a card: one pass per step whose tool needs
    /// the check. Without `callIds` (nil: the page predates them) each pass
    /// is counted against the tool's name. With them, they must pair up with
    /// `tools` one to one and none may be empty; each pass is then bound to
    /// its step's call id. Otherwise nothing is recorded and this returns
    /// false: a card whose steps cannot be told apart gets no pass (fail
    /// closed) — the same rule as the Android SDK.
    @discardableResult
    func recordPass(tools: [String], callIds: [String]?, needsCheck: (String) -> Bool) -> Bool {
        let expires = now() + Self.passLifetime
        lock.lock(); defer { lock.unlock() }
        purgeExpired()
        guard let callIds = callIds else {
            for name in tools where needsCheck(name) {
                passesByName[name, default: []].append(expires)
            }
            return true
        }
        guard callIds.count == tools.count, !callIds.contains(where: \.isEmpty) else { return false }
        for (callId, name) in zip(callIds, tools) where needsCheck(name) {
            passesByCallId[callId] = (name, expires)
        }
        return true
    }

    /// Uses up the pass for this call, if there is one: the one bound to its
    /// call id, else one counted for its tool's name.
    func consumePass(callId: String, name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        purgeExpired()
        if let pass = passesByCallId[callId], pass.name == name {
            passesByCallId.removeValue(forKey: callId)
            return true
        }
        guard var counted = passesByName[name], !counted.isEmpty else { return false }
        counted.removeFirst()
        passesByName[name] = counted.isEmpty ? nil : counted
        return true
    }

    /// Drops every pass: the conversation they were given in is gone.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        passesByCallId.removeAll()
        passesByName.removeAll()
    }

    private func purgeExpired() {
        let current = now()
        passesByCallId = passesByCallId.filter { $0.value.expires > current }
        passesByName = passesByName.compactMapValues { expiries in
            let left = expiries.filter { $0 > current }
            return left.isEmpty ? nil : left
        }
    }
}
