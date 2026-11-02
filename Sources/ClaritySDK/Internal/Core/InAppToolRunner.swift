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

    init(
        registry: InAppToolRegistry,
        send: @escaping (String) -> Void,
        after: @escaping (Int, @escaping () -> Void) -> Void,
        isPageLoaded: @escaping () -> Bool,
        reveals: InAppRevealCoordinator? = nil,
        isMainThread: @escaping () -> Bool = { Thread.isMainThread }
    ) {
        self.registry = registry
        self.send = send
        self.after = after
        self.isPageLoaded = isPageLoaded
        self.reveals = reveals
        self.isMainThread = isMainThread
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
    /// unavailable, no answer in time → handler_timeout. Only the tool name
    /// and the call id may be logged — arguments and results may carry the
    /// customer's data.
    func run(callId: String, name: String, arguments: [String: Any], timeoutMs: Int) {
        guard let handler = registry.handler(for: name) else {
            send(InAppToolRegistry.resultMessage(callId: callId, status: InAppToolRegistry.statusUnavailable))
            return
        }
        let completion = OnceCompletion(callId: callId, send: send)
        after(timeoutMs) { completion.expire() }
        guard let reveal = registry.reveal(for: name), let reveals else {
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

    /// How long the app's security check may take before it counts as not passed.
    static let securityCheckCapSeconds = 60

    /// The customer allowed a card: run the app's security check once for it
    /// when one of its tools needs it, and always answer the page. No tool
    /// that needs it → passed without asking; a tool that needs it but no
    /// check registered → not passed (fail closed). The app's answer counts
    /// once, from any thread; no answer within the cap is not passed.
    func securityCheck(requestId: String, tools names: [String]) {
        let answer = OnceSecurityAnswer { [send] passed in
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
