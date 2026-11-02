import Foundation

/// In-app tools: the tools the host app declared, and the JSON both
/// directions of the bridge carry. Pure Foundation so `swift test` covers it.
///
/// Page → native: `{"action":"inAppToolCall","callId","name","arguments","timeoutMs"}`.
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

    private let lock = NSLock()
    private var tools: [String: ClarityTool] = [:]
    private var check: ClaritySecurityCheck?

    /// The app's security check (`Clarity.setSecurityCheck`); nil when it has none.
    var securityCheck: ClaritySecurityCheck? {
        get { lock.lock(); defer { lock.unlock() }; return check }
        set { lock.lock(); check = newValue; lock.unlock() }
    }

    /// Whether a card with these tools needs the app's security check.
    func needsSecurityCheck(_ names: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.contains { tools[$0]?.requiresSecurityCheck == true }
    }

    /// Why the tool cannot be declared, or nil when it can (`InAppToolValidation`).
    static func problem(with tool: ClarityTool) -> String? {
        InAppToolValidation.problem(with: tool)
    }

    /// False (with the reason logged by the caller) for a tool that could
    /// never be declared.
    @discardableResult
    func register(_ tool: ClarityTool) -> Bool {
        guard Self.problem(with: tool) == nil else { return false }
        lock.lock(); defer { lock.unlock() }
        tools[tool.name] = tool
        return true
    }

    @discardableResult
    func unregister(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tools.removeValue(forKey: name) != nil
    }

    func handler(for name: String) -> ClarityToolHandler? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]?.handler
    }

    func reveal(for name: String) -> ClarityToolReveal? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]?.reveal
    }

    // MARK: - Outbound messages

    func registeredMessage() -> String {
        lock.lock()
        let declared = tools.values.sorted { $0.name < $1.name }
        lock.unlock()
        return JSONEncoding.objectString([
            "action": "inAppToolsRegistered",
            "tools": declared.map(Self.declaration),
            // Kept out of the declarations: the page asks for the check on
            // Allow, the backend never hears of it.
            "securityCheck": declared.filter(\.requiresSecurityCheck).map(\.name),
        ])
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

    init(callId: String, send: @escaping (String) -> Void) {
        self.callId = callId
        self.send = send
    }

    func complete(_ result: ClarityToolResult) {
        guard claim() else { return }
        switch result {
        case .success(let value):
            send(InAppToolRegistry.doneMessage(callId: callId, result: value))
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
