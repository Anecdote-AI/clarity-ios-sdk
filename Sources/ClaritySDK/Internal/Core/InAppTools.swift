import Foundation

/// In-app tools: the tools the host app declared, and the JSON both
/// directions of the bridge carry. Pure Foundation so `swift test` covers it.
///
/// Page → native: `{"action":"inAppToolCall","callId","name","kind","arguments","timeoutMs"}`.
/// Native → page: `inAppToolsRegistered` (the declarations) and
/// `inAppToolResult` — the same messages the Android SDK sends (`InAppTools.kt`).
/// The page passes the declarations to the backend, which checks them in full;
/// what is refused here is only what could never be accepted there.
final class InAppToolRegistry {

    static let shared = InAppToolRegistry()

    static let statusDone = "done"
    static let statusError = "error"
    static let statusUnavailable = "unavailable"
    static let errorTimeout = "handler_timeout"
    static let errorNotJSON = "result_not_json"
    static let maxErrorLength = 300

    /// The backend's `MAX_DECLARED_TOOLS`: a longer declaration is refused
    /// whole, which would leave the agent with no tool at all.
    static let maxDeclaredTools = 32

    private let lock = NSLock()
    private var tools: [String: ClarityTool] = [:]
    /// The names in registration order, which is the order the agent is
    /// offered them: the order changes what the agent does (it neglects the
    /// tools listed last), so it is the app's to choose and is never sorted.
    /// Registering a name again replaces the tool in its place.
    private var order: [String] = []
    /// The SDK's ready-made tools (`ClarityToolTemplates`), by name. Offered
    /// after the host's, in `TemplateCatalog.order`; a host tool of the same
    /// name replaces one, whichever was registered first.
    private var nativeTemplates: [String: ClarityTool] = [:]
    /// Templates a wrapper SDK (Flutter) implements and registers itself
    /// (`registerTemplateTool`); they win over a native one of the same name.
    private var wrapperTemplates: [String: ClarityTool] = [:]
    /// The answers of `rememberResult` tools, by name: in memory only.
    /// Expiries are on the monotonic `now` clock.
    private var remembered: [String: (value: Any, expires: TimeInterval?)] = [:]
    /// Bumped by `forgetRemembered`: an answer to a call that started
    /// before it belongs to the session that was forgotten.
    private var rememberGeneration = 0
    /// The tools last left out by `maxDeclaredTools`, so the warning is not
    /// repeated on every announcement.
    private var warnedLeftOut: [String] = []
    private var check: ClaritySecurityCheck?
    private let log: (String) -> Void
    /// Seconds on a monotonic clock, so a remembered answer's expiry matches
    /// the runner's timer for it and ignores changes to the device clock.
    private let now: () -> TimeInterval

    init(
        log: @escaping (String) -> Void = ClarityLog.log,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.log = log
        self.now = now
    }

    /// The app's security check (`Clarity.setSecurityCheck`); nil when it has none.
    var securityCheck: ClaritySecurityCheck? {
        get { lock.lock(); defer { lock.unlock() }; return check }
        set { lock.lock(); check = newValue; lock.unlock() }
    }

    /// Whether a card with these tools needs the app's security check.
    func needsSecurityCheck(_ names: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.contains { resolve($0)?.requiresSecurityCheck == true }
    }

    /// Why the tool cannot be declared, or nil when it can (`InAppToolValidation`).
    static func problem(with tool: ClarityTool) -> String? {
        InAppToolValidation.problem(with: tool)
    }

    /// The note a remembered tool's description gets, as on the web.
    static let rememberedNote =
        " The customer already allowed this during this visit: it returns at once what they shared then, without asking them again."

    /// Whether the tool's answer is kept: only an action without arguments,
    /// whose one answer stands for every later call. Never a tool that
    /// requires the security check: a remembered answer would skip the check
    /// for the rest of the session, so it goes through the card and the
    /// check every time. Anything else is ignored with a log line.
    static func remembers(_ tool: ClarityTool) -> Bool {
        let properties = tool.parameters["properties"] as? [String: Any] ?? [:]
        return tool.rememberResult && tool.kind == .action && properties.isEmpty
            && !tool.requiresSecurityCheck
    }

    /// `remembers`, with the log line for a tool that asks for it but cannot.
    private func checkRemembers(_ tool: ClarityTool) {
        guard tool.rememberResult && !Self.remembers(tool) else { return }
        if tool.requiresSecurityCheck {
            log("registerTool: \"\(tool.name)\": rememberResult is ignored for a tool that requiresSecurityCheck; it asks every time")
        } else {
            log("registerTool: \"\(tool.name)\": rememberResult works only for an action that takes no arguments; ignored")
        }
    }

    /// False (with the reason logged by the caller) for a tool that could
    /// never be declared.
    @discardableResult
    func register(_ tool: ClarityTool) -> Bool {
        guard Self.problem(with: tool) == nil else { return false }
        checkRemembers(tool)
        lock.lock(); defer { lock.unlock() }
        if tools.updateValue(tool, forKey: tool.name) == nil {
            order.append(tool.name)
        }
        return true
    }

    @discardableResult
    func unregister(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard tools.removeValue(forKey: name) != nil else { return false }
        order.removeAll { $0 == name }
        return true
    }

    /// Replaces every native template with these (`TemplateInstaller`). One
    /// the backend could never accept is left out with a log line.
    func replaceNativeTemplates(_ list: [ClarityTool]) {
        var next: [String: ClarityTool] = [:]
        for tool in list {
            if let problem = Self.problem(with: tool) {
                log("inAppToolTemplates: \"\(tool.name)\" left out: \(problem)")
                continue
            }
            next[tool.name] = tool
        }
        lock.lock()
        nativeTemplates = next
        lock.unlock()
    }

    /// A template a wrapper SDK implements (`registerTemplateTool`).
    @discardableResult
    func registerTemplate(_ tool: ClarityTool) -> Bool {
        guard Self.problem(with: tool) == nil else { return false }
        lock.lock(); defer { lock.unlock() }
        wrapperTemplates[tool.name] = tool
        return true
    }

    @discardableResult
    func unregisterTemplate(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wrapperTemplates.removeValue(forKey: name) != nil
    }

    /// The tool a call with this name runs, as it is now: the host's own
    /// first, then a template.
    func tool(named name: String) -> ClarityTool? {
        lock.lock(); defer { lock.unlock() }
        return resolve(name)
    }

    /// Whether this name is one of the SDK's templates, not shadowed by a
    /// host tool.
    func isTemplate(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tools[name] == nil && (wrapperTemplates[name] ?? nativeTemplates[name]) != nil
    }

    private func resolve(_ name: String) -> ClarityTool? {
        tools[name] ?? wrapperTemplates[name] ?? nativeTemplates[name]
    }

    // MARK: - Remembered answers

    /// The stored answer of a remembered tool, if it still stands.
    func rememberedResult(for name: String) -> Any?? {
        lock.lock(); defer { lock.unlock() }
        purgeExpired()
        guard let entry = remembered[name] else { return nil }
        return .some(entry.value)
    }

    /// The session the remembered answers belong to; pass it to `remember`
    /// from the call that produced the answer.
    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return rememberGeneration
    }

    /// Keeps a remembered tool's answer. True when the tool was not
    /// remembered before, so the page must hear its new declaration. An
    /// answer to a call that started in an earlier `generation` (before a
    /// `forgetRemembered`: a logout, another user) is not kept.
    @discardableResult
    func remember(_ name: String, result: Any?, generation: Int? = nil) -> Bool {
        let value = result ?? NSNull()
        // Only an answer the page could be sent is kept.
        guard JSONSerialization.isValidJSONObject(["result": value]) else { return false }
        lock.lock(); defer { lock.unlock() }
        if let generation, generation != rememberGeneration { return false }
        guard let tool = resolve(name), Self.remembers(tool) else { return false }
        let expires = tool.rememberFor.map { now() + $0 }
        let isNew = remembered[name] == nil
        remembered[name] = (value, expires)
        return isNew
    }

    /// Forgets every remembered answer (`resetSession`, a user switch). True
    /// when there was one, so the page must hear the actions again.
    @discardableResult
    func forgetRemembered() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let had = !remembered.isEmpty
        remembered.removeAll()
        rememberGeneration += 1
        return had
    }

    private func purgeExpired() {
        let current = now()
        remembered = remembered.filter { $0.value.expires.map { $0 > current } ?? true }
    }

    // MARK: - Outbound messages

    /// Every tool the agent could be offered, in the order it is offered:
    /// the host's in registration order, then the templates no host tool
    /// replaces, in the canonical template order (a name it does not know
    /// last, by name).
    func effectiveTools() -> [ClarityTool] {
        lock.lock(); defer { lock.unlock() }
        let host = order.compactMap { tools[$0] }
        var templates = nativeTemplates
        wrapperTemplates.forEach { templates[$0.key] = $0.value }
        let extra = templates.values
            .filter { tools[$0.name] == nil }
            .sorted { a, b in
                let (ia, ib) = (TemplateCatalog.rank(a.name), TemplateCatalog.rank(b.name))
                return ia != ib ? ia < ib : a.name < b.name
            }
        return host + extra
    }

    /// The tools the agent is offered: the first `maxDeclaredTools` of
    /// `effectiveTools`. The backend refuses a longer list as a whole, so the
    /// rest — templates first, since they come last — are left out and named
    /// in a warning.
    func declaredTools() -> [ClarityTool] {
        let all = effectiveTools()
        let leftOut = all.dropFirst(Self.maxDeclaredTools).map(\.name)
        lock.lock()
        let warn = !leftOut.isEmpty && leftOut != warnedLeftOut
        warnedLeftOut = leftOut
        lock.unlock()
        if warn {
            log(
                "registerTool: the agent is offered at most \(Self.maxDeclaredTools) tools, the first ones registered; "
                    + "left out: \(leftOut.joined(separator: ", "))"
            )
        }
        return Array(all.prefix(Self.maxDeclaredTools))
    }

    func registeredMessage() -> String {
        let declared = declaredTools()
        let isRemembered = Set(declared.map(\.name).filter { rememberedResult(for: $0) != nil })
        // A remembered tool is answered without a card, so it needs no check
        // and has nothing to allow.
        let carded = declared.filter { !isRemembered.contains($0.name) }
        return JSONEncoding.objectString([
            "action": "inAppToolsRegistered",
            "tools": declared.map { declaration($0, remembered: isRemembered.contains($0.name)) },
            // Kept out of the declarations: the page asks for the check on
            // Allow, the backend never hears of it.
            "securityCheck": carded.filter(\.requiresSecurityCheck).map(\.name),
            "collapseCallOnAllow": carded.filter(\.collapseCallOnAllow).map(\.name),
        ])
    }

    /// The declaration as offered now: a remembered tool is a read that says
    /// it answers at once.
    func declaration(_ tool: ClarityTool, remembered: Bool) -> [String: Any] {
        var declaration = Self.declaration(tool)
        if remembered && Self.remembers(tool) {
            declaration["kind"] = ClarityToolKind.read.rawValue
            let room = InAppToolValidation.maxDescriptionLength - Self.rememberedNote.unicodeScalars.count
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: tool.description.unicodeScalars.prefix(room))
            declaration["description"] = String(scalars) + Self.rememberedNote
        }
        return declaration
    }

    static func securityCheckResultMessage(requestId: String, passed: Bool) -> String {
        JSONEncoding.objectString([
            "action": "inAppSecurityCheckResult",
            "requestId": requestId,
            "passed": passed,
        ])
    }

    static func declaration(_ tool: ClarityTool) -> [String: Any] {
        var declaration: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "kind": tool.kind.rawValue,
            "inputSchema": tool.parameters,
        ]
        declaration["resultSchema"] = tool.resultSchema
        declaration["timeoutSeconds"] = tool.timeoutSeconds
        return declaration
    }

    static func resultMessage(callId: String, status: String) -> String {
        JSONEncoding.objectString(["action": "inAppToolResult", "callId": callId, "status": status])
    }

    static func doneMessage(callId: String, result: Any?) -> String {
        let object: [String: Any] = [
            "action": "inAppToolResult",
            "callId": callId,
            "status": statusDone,
            "result": result ?? NSNull(),
        ]
        guard let encoded = JSONEncoding.string(fromJSONObject: object) else {
            return errorMessage(callId: callId, message: errorNotJSON)
        }
        return encoded
    }

    static func errorMessage(callId: String, message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return JSONEncoding.objectString([
            "action": "inAppToolResult",
            "callId": callId,
            "status": statusError,
            "error": String((text.isEmpty ? "failed" : text).prefix(maxErrorLength)),
        ])
    }
}

/// Answers a call once, whatever the host does after (a second completion,
/// a completion after the timeout fired). Lock-guarded, so the completion may
/// come from any thread.
final class OnceCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private var answeredHook: (() -> Void)?
    private var successHook: ((Any?) -> Void)?
    private let callId: String
    private let send: (String) -> Void

    var isAnswered: Bool {
        lock.lock(); defer { lock.unlock() }
        return answered
    }

    /// Called once, right after the answer (or the timeout) is sent.
    var onAnswered: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return answeredHook }
        set { lock.lock(); answeredHook = newValue; lock.unlock() }
    }

    /// Called once with the value of a successful answer that was sent as
    /// done (not one that failed to serialize), before `onAnswered`.
    var onSuccess: ((Any?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return successHook }
        set { lock.lock(); successHook = newValue; lock.unlock() }
    }

    init(callId: String, send: @escaping (String) -> Void) {
        self.callId = callId
        self.send = send
    }

    func complete(_ result: ClarityToolResult) {
        guard claim() else { return }
        switch result {
        case .success(let value):
            let message = InAppToolRegistry.doneMessage(callId: callId, result: value)
            send(message)
            if JSONSerialization.isValidJSONObject(["result": value ?? NSNull()]) {
                onSuccess?(value)
            }
        case .failure(let message):
            send(InAppToolRegistry.errorMessage(callId: callId, message: message))
        }
        onAnswered?()
    }

    func expire() {
        guard claim() else { return }
        send(InAppToolRegistry.errorMessage(callId: callId, message: InAppToolRegistry.errorTimeout))
        onAnswered?()
    }

    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if answered { return false }
        answered = true
        return true
    }
}
