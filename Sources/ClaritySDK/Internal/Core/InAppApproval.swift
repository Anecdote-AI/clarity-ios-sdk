import Foundation

/// Approval modes of in-app actions, on the app's side.
///
/// The platform decides whether an action may run without a card ("Allow for
/// this chat", the customer's "Allow all"), and enforces it. What the APP
/// registered has the last word, though: a call that came without a card
/// (`approval` on the call) runs only when the tool's registration lets that
/// mode cover it, and never for a tool that always asks. Otherwise the call is
/// answered `approval_required[:<category>]` and the platform puts the card
/// up instead, saying why. A declaration forged on the platform therefore
/// never makes a tool skip its card.
///
/// Money is the only thing guessed from words, from a copy of the platform's
/// lexicon (`InAppApprovalLexicon`, which the web chat reads too);
/// the other categories ask when the app declares them. Same rules as the
/// web chat and the Android SDK.
enum InAppApproval {

    static let approvalRequired = "approval_required"
    static let sourceSession = "session"
    static let sourceAllowAll = "allow_all"
    static let securityCheck = "security_check"
    static let payment = "payment"
    static let subscription = "subscription"
    static let accountDeletion = "account_deletion"
    static let clickTool = "click_element"
    static let clickTarget = "target"

    /// The refusal, naming why the call must ask when it is known: `approval_required:payment`.
    static func requiredError(_ category: String?) -> String {
        category.map { "\(approvalRequired):\($0)" } ?? approvalRequired
    }

    // MARK: - The lexicon

    // Spelled out as on Android, where `\w`, `\s` and `\d` are not Unicode:
    // these read as the platform's Python `re` does.
    private static let letter = "[\\p{L}\\p{N}_]"
    private static let space = "[\\s\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]"
    private static let digit = "\\p{Nd}"

    private struct Lexicon {
        let payment: [NSRegularExpression]
        let subscription: [NSRegularExpression]
        let moneyContext: [NSRegularExpression]
        let accountClosing: [NSRegularExpression]
        let moneyPaths: Set<String>
        let amount: NSRegularExpression
    }

    private static let lexicon: Lexicon = {
        let data = Data(InAppApprovalLexicon.json.utf8)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
        func compiled(_ group: String) -> [NSRegularExpression] {
            let entry = json[group] as? [String: Any] ?? [:]
            return ["word", "prefix", "contains"].flatMap { mode in
                strings(entry[mode]).compactMap { word -> NSRegularExpression? in
                    let body = term(word)
                    let pattern: String
                    switch mode {
                    case "contains": pattern = body
                    case "prefix": pattern = "(?<!\(letter))\(body)"
                    default: pattern = "(?<!\(letter))\(body)(?!\(letter))"
                    }
                    return try? NSRegularExpression(pattern: pattern)
                }
            }
        }
        let symbols = strings(json["currency_symbols"]).map(escaped).joined()
        let codes = (strings(json["currency_codes"]) + strings(json["currency_words"])).map(escaped).joined(separator: "|")
        let amount = "(?:[\(symbols)]|(?<!\(letter))(?:\(codes)))\(space)*\(digit)"
            + "|\(digit)(?:(?:\(digit)|[.,]|\(space))*\(digit))?\(space)*(?:[\(symbols)]|(?:\(codes))(?!\(letter)))"
        return Lexicon(
            payment: compiled("payment"),
            subscription: compiled("subscription"),
            moneyContext: compiled("money_context"),
            accountClosing: compiled("account_closing"),
            moneyPaths: Set(strings(json["money_paths"])),
            // swiftlint:disable:next force_try
            amount: try! NSRegularExpression(pattern: amount)
        )
    }()

    /// A letter or digit as is; anything else escaped, so it stands for itself (also in a class).
    private static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if !CharacterSet.alphanumerics.contains(scalar) { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private static func term(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { escaped(String($0)) }.joined(separator: "\(space)+")
    }

    /// Lower-cased, NFKC, with `_` and `-` read as spaces (`pay_bill`, `top-up`).
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "[_\\-]+", with: " ", options: .regularExpression)
    }

    private static func present(_ texts: [String?]) -> [String] {
        texts.compactMap { $0 }.filter { !$0.isEmpty }.map(normalized)
    }

    private static func found(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func anyIn(_ group: [NSRegularExpression], _ text: String) -> Bool {
        group.contains { found($0, in: text) }
    }

    static func hasAmount(_ texts: [String?]) -> Bool {
        present(texts).contains { found(lexicon.amount, in: $0) }
    }

    static func hasMoneyContextWord(_ texts: [String?]) -> Bool {
        present(texts).contains { anyIn(lexicon.moneyContext, $0) }
    }

    static func isAccountClosing(_ texts: [String?]) -> Bool {
        present(texts).contains { anyIn(lexicon.accountClosing, $0) }
    }

    /// The money category any of the texts falls in, or nil; "Confirm" counts only next to an amount.
    static func sensitiveCategory(of texts: [String?]) -> String? {
        let all = present(texts)
        if all.contains(where: { anyIn(lexicon.payment, $0) }) { return payment }
        if all.contains(where: { anyIn(lexicon.subscription, $0) }) { return subscription }
        let context = all.contains { anyIn(lexicon.moneyContext, $0) }
        return context && all.contains(where: { found(lexicon.amount, in: $0) }) ? payment : nil
    }

    /// Whether a link's address leads to money: `/checkout/pay`, `/billing`,
    /// and in a deep link, whose first segment is its host, `myapp://checkout`.
    static func isMoneyPath(_ link: String?) -> Bool {
        guard let link, let path = linkPath(link) else { return false }
        return path.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "/._-").union(.whitespaces))
            .contains { lexicon.moneyPaths.contains($0) }
    }

    /// The part of a link that names where it leads: the path of a web
    /// address; the host and the path of any other scheme, whose host is the
    /// app's first segment (`myapp://billing/42` reads "billing/42"). Read by
    /// hand, so a link `URL` would refuse (a space in it) is still read.
    /// Without the query and the fragment. Identical on Android.
    static func linkPath(_ link: String) -> String? {
        var rest = Substring(link.trimmingCharacters(in: .whitespacesAndNewlines))
        if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        var scheme: String?
        if let colon = rest.firstIndex(of: ":"),
           rest[..<colon].range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil {
            scheme = rest[..<colon].lowercased()
            rest = rest[rest.index(after: colon)...]
        }
        guard rest.hasPrefix("//") else { return decoded(rest) }
        rest = rest.dropFirst(2)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let path = rest[slash...]
        if scheme == nil || scheme == "http" || scheme == "https" { return decoded(path) }
        var host = rest[..<slash]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let port = host.firstIndex(of: ":") { host = host[..<port] }
        return decoded(host + path)
    }

    private static func decoded<S: StringProtocol>(_ text: S) -> String {
        String(text).removingPercentEncoding ?? String(text)
    }

    // MARK: - Judging a call

    /// Why an action always asks, or nil when a grant may cover it: the app's
    /// declared category first, then money words on the tool's name and label
    /// and, for the built-in click, on the control it is asked to press
    /// (which also asks for "delete my account"). The description is not
    /// read: long prose would make most tools ask.
    static func alwaysAskReason(name: String, label: String?, sensitive: String?, arguments: [String: Any]) -> String? {
        if let sensitive { return sensitive }
        let target = name == clickTool ? arguments[clickTarget] as? String : nil
        if let target, isAccountClosing([target]) { return accountDeletion }
        return sensitiveCategory(of: [name, label, target])
    }

    /// Why a call that came without a card (`approval`: `session` or
    /// `allow_all`) must not run `tool`, or nil when the app's registration
    /// lets it. Only an action is checked: anything else runs without a card
    /// anyway.
    static func refusal(
        _ tool: ClarityTool,
        approval: String,
        modes: ClarityInAppToolApproval,
        arguments: [String: Any]
    ) -> String? {
        guard tool.kind == .action else { return nil }
        if tool.requiresSecurityCheck { return requiredError(securityCheck) }
        if let reason = alwaysAskReason(
            name: tool.name, label: tool.label, sensitive: tool.approval?.sensitive?.rawValue, arguments: arguments
        ) {
            return requiredError(reason)
        }
        let allowed: Bool
        switch approval {
        case sourceSession: allowed = tool.approval?.allowForSession != false && modes.allowForSession
        case sourceAllowAll: allowed = tool.approval?.allowAll != false && modes.allowAll
        default: allowed = false
        }
        return allowed ? nil : approvalRequired
    }
}
