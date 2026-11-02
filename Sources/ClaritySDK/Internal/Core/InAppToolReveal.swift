import Foundation

/// The chat window's side of a reveal. The widget's view controller is the
/// real one; the tests use a fake.
protocol InAppRevealSurface: AnyObject {
    /// Steps the chat aside and calls `ready` once it is out of the way.
    /// False when it cannot (a full-screen chat has no app behind it), and
    /// then `ready` is never called.
    func beginReveal(style: ClarityToolReveal.Style, message: String, ready: @escaping () -> Void) -> Bool
    /// A new loader text, while the chat is aside.
    func updateReveal(message: String)
    /// Brings the chat back.
    func endReveal()
}

/// Keeps the chat aside while something holds it there, and brings it back
/// when nothing does. A hold is a tool running, the pause after one, or a
/// wait for the app's `Clarity.bringChatBack()` (after a tool with
/// `waitForApp`, or the app's own `Clarity.stepAside`). The first to step the
/// chat aside sets its style; later ones only change the loader text. Main
/// thread only.
final class InAppRevealCoordinator {

    /// Long enough for any sheet animation: past it, a step-aside that never
    /// reported ready (the chat closed mid-way) lets the tools run anyway.
    static let readyWatchdogMs = 1500
    /// A wait for the app's signal ends here even without it, so a missed
    /// `bringChatBack()` never hides the chat for good.
    static let signalWaitCapMs = 30_000

    private enum Phase {
        case idle
        case steppingAside(beginId: Int, waiting: [() -> Void])
        case aside
    }

    private enum HoldKind { case running, pause, untilSignal }

    private struct Hold {
        var kind: HoldKind
    }

    private let surface: () -> InAppRevealSurface?
    private let after: (Int, @escaping () -> Void) -> Void
    private let onAside: () -> Void
    private let onReturned: () -> Void
    private weak var current: InAppRevealSurface?
    private var phase: Phase = .idle
    private var beginId = 0
    private var holds: [Int: Hold] = [:]
    private var nextHoldId = 0

    init(
        surface: @escaping () -> InAppRevealSurface?,
        after: @escaping (Int, @escaping () -> Void) -> Void,
        onAside: @escaping () -> Void = {},
        onReturned: @escaping () -> Void = {}
    ) {
        self.surface = surface
        self.after = after
        self.onAside = onAside
        self.onReturned = onReturned
    }

    // MARK: - A tool with a reveal

    /// Runs `body` with the chat aside. `body` gets `finished`, to call once
    /// the tool answered (only the first call counts).
    func run(_ reveal: ClarityToolReveal, body: @escaping (_ finished: @escaping () -> Void) -> Void) {
        let hold = addHold(Hold(kind: .running))
        let start = { [weak self] in
            guard let self else { return }
            self.after(Self.milliseconds(reveal.delayBefore)) {
                let once = Once()
                body { [weak self] in
                    guard once.claim() else { return }
                    self?.toolAnswered(hold: hold, reveal: reveal)
                }
            }
        }
        stepAside(style: reveal.style, message: reveal.message, then: start) { [weak self] in
            self?.release(hold)
            body {}
        }
    }

    private func toolAnswered(hold: Int, reveal: ClarityToolReveal) {
        guard holds[hold] != nil else { return }
        if let pause = reveal.holdAfter {
            holds[hold]?.kind = .pause
            after(Self.milliseconds(pause)) { [weak self] in self?.release(hold) }
        } else if reveal.waitForApp {
            holds[hold]?.kind = .untilSignal
            after(Self.signalWaitCapMs) { [weak self] in self?.release(hold) }
        } else {
            release(hold)
        }
    }

    // MARK: - The app's own calls

    /// `Clarity.stepAside`: the chat stays aside until `bringChatBack()`.
    func appStepAside(style: ClarityToolReveal.Style, message: String) {
        let hold = addHold(Hold(kind: .untilSignal))
        after(Self.signalWaitCapMs) { [weak self] in self?.release(hold) }
        stepAside(style: style, message: message, then: nil) { [weak self] in self?.release(hold) }
    }

    /// `Clarity.updateStepAside`: a new loader text, if the chat is aside.
    func appUpdate(message: String) {
        if case .idle = phase { return }
        current?.updateReveal(message: message)
    }

    /// `Clarity.bringChatBack`: ends every wait for the app's signal. A tool
    /// still running, or the pause after one, keeps the chat aside — and a
    /// tool that answers later still waits for its own signal. The natural
    /// `completion(…); Clarity.bringChatBack()` works because the runner
    /// hands an answer given on the main thread over at once
    /// (`InAppToolRunner`), so its wait exists before the signal arrives.
    func bringChatBack() {
        holds = holds.filter { $0.value.kind != .untilSignal }
        returnIfNothingHolds()
    }

    /// The chat closed: nothing it held carries over to the next one. The
    /// tools still waiting for the chat to step aside run at once, and a
    /// tool still running answers as usual.
    func chatClosed() {
        abandon()
        holds.removeAll()
    }

    /// Lets go of the chat this state was about: runs what was waiting for it
    /// and, if the host heard it step aside, tells the host it is back.
    private func abandon() {
        let previous = phase
        phase = .idle
        current = nil
        switch previous {
        case .steppingAside(_, let waiting):
            waiting.forEach { $0() }
        case .aside:
            onReturned()
        case .idle:
            break
        }
    }

    // MARK: - Shared

    private func stepAside(
        style: ClarityToolReveal.Style,
        message: String,
        then start: (() -> Void)?,
        cannot: () -> Void
    ) {
        // The chat this state was about is gone (closed, maybe reopened):
        // start over with the one on screen now.
        if current == nil, !isIdle {
            abandon()
        }
        switch phase {
        case .aside:
            current?.updateReveal(message: message)
            start?()
        case .steppingAside(let id, let waiting):
            current?.updateReveal(message: message)
            phase = .steppingAside(beginId: id, waiting: waiting + (start.map { [$0] } ?? []))
        case .idle:
            guard let surface = surface() else { return cannot() }
            beginId += 1
            let id = beginId
            phase = .steppingAside(beginId: id, waiting: start.map { [$0] } ?? [])
            current = surface
            let began = surface.beginReveal(style: style, message: message) { [weak self] in
                self?.becameAside(beginId: id)
            }
            guard began else {
                phase = .idle
                current = nil
                return cannot()
            }
            after(Self.readyWatchdogMs) { [weak self] in self?.becameAside(beginId: id) }
        }
    }

    private var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    private func becameAside(beginId id: Int) {
        guard case .steppingAside(let current, let waiting) = phase, current == id else { return }
        phase = .aside
        onAside()
        waiting.forEach { $0() }
        returnIfNothingHolds()
    }

    private func addHold(_ hold: Hold) -> Int {
        nextHoldId += 1
        holds[nextHoldId] = hold
        return nextHoldId
    }

    private func release(_ hold: Int) {
        guard holds.removeValue(forKey: hold) != nil else { return }
        returnIfNothingHolds()
    }

    private func returnIfNothingHolds() {
        guard holds.isEmpty, case .aside = phase else { return }
        phase = .idle
        current?.endReveal()
        current = nil
        onReturned()
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) * 1000).rounded())
    }
}

/// True for the first claim only.
private final class Once {
    private var claimed = false

    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}
