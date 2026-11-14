import Foundation

/// The engine's part of in-app tools, kept free of UIKit so `swift test`
/// covers it: when the page hears the declarations, and how one call is run
/// and always answered. The engine supplies the web view's `send`, the main
/// queue's timer and whether the page is loaded.
final class InAppToolRunner {

    private let registry: InAppToolRegistry
    private let send: (String) -> Void
    private let after: (Int, @escaping () -> Void) -> Void
    private let isPageLoaded: () -> Bool
    private let reveals: InAppRevealCoordinator?
    private let isMainThread: () -> Bool
    private let gate: InAppCallGate
    private let log: (String) -> Void
    /// Runs on the main thread right before a tool's handler (never for a
    /// remembered answer): the templates take their pointer and field ring
    /// off the screen when the conversation moves on (`TemplateRuntime`).
    var willRun: ((ClarityTool) -> Void)?

    init(
        registry: InAppToolRegistry,
        send: @escaping (String) -> Void,
        after: @escaping (Int, @escaping () -> Void) -> Void,
        isPageLoaded: @escaping () -> Bool,
        reveals: InAppRevealCoordinator? = nil,
        isMainThread: @escaping () -> Bool = { Thread.isMainThread },
        gate: InAppCallGate = InAppCallGate(),
        log: @escaping (String) -> Void = ClarityLog.log
    ) {
        self.registry = registry
        self.send = send
        self.after = after
        self.isPageLoaded = isPageLoaded
        self.reveals = reveals
        self.isMainThread = isMainThread
        self.gate = gate
        self.log = log
    }

    /// The conversation is gone (the web view was reset): no security check
    /// passed in it may cover a call that comes later.
    func forgetSecurityPasses() {
        gate.reset()
    }

    /// The page is up: it hears every tool registered so far, including the
    /// ones registered before `initialize`.
    func pageDidLoad() {
        send(registry.registeredMessage())
    }

    /// A tool was registered or removed: a loaded page hears the new set.
    func toolsDidChange() {
        guard isPageLoaded() else { return }
        send(registry.registeredMessage())
    }

    /// Runs one call on the main thread and always answers it: no handler →
    /// unavailable, no answer in time → handler_timeout. A tool whose answer
    /// is remembered (`rememberResult`) answers with it at once, before any
    /// other check and without its handler: it is declared as a read now, so
    /// the call arrives as a read, below the action the tool was registered
    /// as, and must not become kind_mismatch. Then the SDK's own checks
    /// (`InAppCallGate`): a call the page treated as less than the tool's
    /// registered kind → kind_mismatch; a tool that needs the app's security
    /// check with no pass from one this SDK ran → security_check_required.
    /// Only the tool name and the call id may be logged — arguments and
    /// results may carry the customer's data.
    func run(callId: String, name: String, kind: ClarityToolKind, arguments: [String: Any], timeoutMs: Int) {
        guard let tool = registry.tool(named: name) else {
            send(InAppToolRegistry.resultMessage(callId: callId, status: InAppToolRegistry.statusUnavailable))
            return
        }
        if InAppToolRegistry.remembers(tool), let stored = registry.rememberedResult(for: name) {
            send(InAppToolRegistry.doneMessage(callId: callId, result: stored))
            return
        }
        guard InAppCallGate.kindAllows(called: kind, registered: tool.kind) else {
            if InAppToolRegistry.remembers(tool) {
                // The page still offers it as a read, but its answer is gone
                // (it expired before the timer below told the page): the
                // page hears it as an action again, so the next call comes
                // through a card instead of failing the same way.
                toolsDidChange()
            }
            refuse(callId: callId, name: name, reason: InAppCallGate.errorKindMismatch)
            return
        }
        if tool.requiresSecurityCheck, !gate.consumePass(callId: callId, name: name) {
            refuse(callId: callId, name: name, reason: InAppCallGate.errorSecurityCheckRequired)
            return
        }
        let handler = tool.handler
        let completion = OnceCompletion(callId: callId, send: send)
        if InAppToolRegistry.remembers(tool) {
            // An answer that arrives after a logout or a user switch belongs
            // to the session that was forgotten: not kept.
            let generation = registry.generation
            let lifetime = tool.rememberFor
            completion.onSuccess = { [weak self] value in
                guard let self else { return }
                if self.registry.remember(name, result: value, generation: generation) {
                    // On main: the page hears the tool as a read from now on…
                    self.after(0) { self.toolsDidChange() }
                    // …and as an action again once the answer expires, or its
                    // next call would arrive as a read and be refused.
                    if let lifetime {
                        self.after(Self.milliseconds(lifetime)) { self.toolsDidChange() }
                    }
                }
            }
        }
        after(timeoutMs) { completion.expire() }
        willRun?(tool)
        guard let reveal = tool.reveal, let reveals else {
            invoke(handler, arguments: arguments, completion: completion)
            return
        }
        // The chat steps aside first; it learns of the answer (or the
        // timeout) on the main thread: at once when the host answered there,
        // so a `bringChatBack()` right after the answer finds its wait, or
        // queued on main — ahead of anything the host queues after answering.
        reveals.run(reveal) { [weak self, after, isMainThread] finished in
            if completion.isAnswered {
                finished()
                return
            }
            completion.onAnswered = {
                if isMainThread() { finished() } else { after(0) { finished() } }
            }
            self?.invoke(handler, arguments: arguments, completion: completion)
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int(min((seconds * 1000).rounded(.up), Double(Int32.max)))
    }

    private func refuse(callId: String, name: String, reason: String) {
        log("in-app tool \(name) (\(callId)) refused: \(reason)")
        send(InAppToolRegistry.errorMessage(callId: callId, message: reason))
    }

    /// The remembered answers are gone (`resetSession`, a user switch): a
    /// loaded page hears the tools ask again.
    func forgetRemembered() {
        if registry.forgetRemembered() { toolsDidChange() }
    }

    /// How long the app's security check may take before it counts as not passed.
    static let securityCheckCapSeconds = 60

    /// The customer allowed a card: run the app's security check once for it
    /// when one of its tools needs it, and always answer the page. No tool
    /// that needs it → passed without asking; a tool that needs it but no
    /// check registered → not passed (fail closed). The app's answer counts
    /// once, from any thread; no answer within the cap is not passed. Only
    /// the answer the page hears as passed records the passes the card's
    /// steps run on (`InAppCallGate`), bound to `callIds` when the page sent
    /// them.
    func securityCheck(requestId: String, tools names: [String], callIds: [String]?) {
        let answer = OnceSecurityAnswer { [send, gate, registry, log] passed in
            if passed {
                let recorded = gate.recordPass(tools: names, callIds: callIds) {
                    registry.tool(named: $0)?.requiresSecurityCheck == true
                }
                if !recorded {
                    log("The security check passed, but the card's call ids do not match its steps: no step may run")
                }
            }
            send(InAppToolRegistry.securityCheckResultMessage(requestId: requestId, passed: passed))
        }
        guard registry.needsSecurityCheck(names) else {
            answer.resolve(true)
            return
        }
        guard let check = registry.securityCheck else {
            ClarityLog.log("A tool on this card needs the app's security check, but none is set (Clarity.setSecurityCheck): not run")
            answer.resolve(false)
            return
        }
        after(Self.securityCheckCapSeconds * 1000) { answer.resolve(false) }
        let request = ClaritySecurityCheckRequest(toolNames: names)
        if #available(iOS 13.0, macOS 10.15, *) {
            MainActor.assumeIsolated {
                check(request) { passed in answer.resolve(passed) }
            }
        } else {
            answer.resolve(false)
        }
    }

    private func invoke(
        _ handler: @escaping ClarityToolHandler,
        arguments: [String: Any],
        completion: OnceCompletion
    ) {
        // The engine calls this on the main thread. The check only matters to
        // the macOS host build of `swift test`; the SDK itself needs iOS 15.
        if #available(iOS 13.0, macOS 10.15, *) {
            MainActor.assumeIsolated {
                handler(arguments) { result in completion.complete(result) }
            }
        } else {
            completion.complete(.failure("in-app tools need iOS 13 or later"))
        }
    }
}

/// The answer to one security check: the first of the app's answer and the
/// cap wins, whatever thread it comes from.
final class OnceSecurityAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private let send: (Bool) -> Void

    init(send: @escaping (Bool) -> Void) {
        self.send = send
    }

    func resolve(_ passed: Bool) {
        lock.lock()
        let first = !answered
        answered = true
        lock.unlock()
        if first { send(passed) }
    }
}
