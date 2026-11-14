import XCTest
@testable import ClaritySDK

/// A tool that shows something in the app gets the chat out of the way while
/// it runs (`ClarityToolReveal`). The Android port is `InAppToolRevealTest.kt`.
final class InAppToolRevealTests: XCTestCase {

    /// The chat window as the coordinator sees it: it records what it was
    /// asked to do and reports ready only when the test says so.
    private final class FakeChat: InAppRevealSurface {
        var events: [String] = []
        var origins: [InAppRevealOrigin] = []
        var canStepAside = true
        var ready: (() -> Void)?

        func beginReveal(
            style: ClarityToolReveal.Style,
            message: String,
            origin: InAppRevealOrigin,
            ready: @escaping () -> Void
        ) -> Bool {
            guard canStepAside else { return false }
            origins.append(origin)
            events.append("aside \(style == .strip ? "strip" : "fade"): \(message)")
            self.ready = ready
            return true
        }

        func updateReveal(message: String) { events.append("message: \(message)") }

        func endReveal() { events.append("back") }
    }

    /// Timers run only when the test fires them, in the order they were set.
    private final class Harness {
        var sent: [String] = []
        var timers: [(ms: Int, block: () -> Void)] = []
        var chat: FakeChat? = FakeChat()
        var notified: [String] = []
        /// Whether the host answers on the main thread; off by default, so
        /// an answer is handed over by a timer the test fires.
        var onMain = false
        let registry = InAppToolRegistry()
        lazy var reveals = InAppRevealCoordinator(
            surface: { [unowned self] in self.chat },
            after: { [unowned self] ms, block in self.timers.append((ms, block)) },
            onAside: { [unowned self] in self.notified.append("aside") },
            onReturned: { [unowned self] in self.notified.append("returned") }
        )
        lazy var runner = InAppToolRunner(
            registry: registry,
            send: { [unowned self] in self.sent.append($0) },
            after: { [unowned self] ms, block in self.timers.append((ms, block)) },
            isPageLoaded: { true },
            reveals: reveals,
            isMainThread: { [unowned self] in self.onMain }
        )

        /// Runs the first pending timer set for `ms`.
        func fire(_ ms: Int, file: StaticString = #filePath, line: UInt = #line) {
            guard let index = timers.firstIndex(where: { $0.ms == ms }) else {
                return XCTFail("no timer for \(ms) ms; pending: \(timers.map(\.ms))", file: file, line: line)
            }
            timers.remove(at: index).block()
        }
    }

    private func screenTool(
        _ name: String,
        message: String,
        holdAfter: TimeInterval? = 1.0,
        waitForApp: Bool = false,
        log: @escaping (String) -> Void,
        answer: ((@escaping ClarityToolCompletion) -> Void)? = nil
    ) -> ClarityTool {
        ClarityTool(
            name: name,
            description: "Opens a screen",
            kind: .safeAction,
            reveal: ClarityToolReveal(
                message: message, delayBefore: 0.3, holdAfter: holdAfter, waitForApp: waitForApp
            )
        ) { _, completion in
            log("run \(name)")
            if let answer { answer(completion) } else { completion(.success(["ok": true])) }
        }
    }

    func testTheChatStepsAsideBeforeTheToolAndComesBackAfterIt() {
        let harness = Harness()
        harness.registry.register(screenTool("open_screen", message: "Opening your plan…") {
            harness.chat?.events.append($0)
        })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        XCTAssertEqual(harness.chat?.events, ["aside strip: Opening your plan…"], "nothing runs before the chat is aside")

        harness.chat?.ready?()
        harness.fire(300)
        XCTAssertEqual(harness.chat?.events.last, "run open_screen")
        XCTAssertEqual(harness.sent.count, 1, "the answer goes to the page at once")

        harness.fire(0)
        harness.fire(1000)
        XCTAssertEqual(harness.chat?.events, ["aside strip: Opening your plan…", "run open_screen", "back"])
    }

    func testStepsThatFollowOneAnotherKeepTheChatAsideUntilTheLast() {
        let harness = Harness()
        let log: (String) -> Void = { harness.chat?.events.append($0) }
        harness.registry.register(screenTool("open_screen", message: "Opening your plan…", log: log))
        harness.registry.register(screenTool("highlight", message: "Showing the button…", log: log))

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.chat?.ready?()
        harness.fire(300)
        harness.fire(0)
        // The next step starts within the pause after the first.
        harness.runner.run(callId: "c2", name: "highlight", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.fire(1000)
        XCTAssertFalse(harness.chat?.events.contains("back") ?? true, "a pause that a new step started within is called off")

        harness.fire(300)
        harness.fire(0)
        harness.fire(1000)

        XCTAssertEqual(harness.chat?.events, [
            "aside strip: Opening your plan…",
            "run open_screen",
            "message: Showing the button…",
            "run highlight",
            "back",
        ])
    }

    func testAFullScreenChatLetsTheToolRunAsItIs() {
        let harness = Harness()
        harness.chat?.canStepAside = false
        var ran = false
        harness.registry.register(screenTool("open_screen", message: "Opening…") { _ in ran = true })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)

        XCTAssertTrue(ran)
        XCTAssertEqual(harness.chat?.events, [])
    }

    func testWithTheChatClosedTheToolRunsAtOnce() {
        let harness = Harness()
        harness.chat = nil
        var ran = false
        harness.registry.register(screenTool("open_screen", message: "Opening…") { _ in ran = true })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)

        XCTAssertTrue(ran)
    }

    func testATimeoutBringsTheChatBackToo() {
        let harness = Harness()
        harness.registry.register(screenTool("open_screen", message: "Opening…", log: { _ in }, answer: { _ in }))

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.chat?.ready?()
        harness.fire(300)
        harness.fire(30_000)
        harness.fire(0)
        harness.fire(1000)

        XCTAssertEqual(harness.sent, [#"{"action":"inAppToolResult","callId":"c1","error":"handler_timeout","status":"error"}"#])
        XCTAssertEqual(harness.chat?.events.last, "back")
    }

    func testAChatThatNeverReportsReadyStillLetsTheToolRun() {
        let harness = Harness()
        var ran = false
        harness.registry.register(screenTool("open_screen", message: "Opening…") { _ in ran = true })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.fire(InAppRevealCoordinator.readyWatchdogMs)
        harness.fire(300)

        XCTAssertTrue(ran)
    }

    func testARevealOutsideItsLimitsIsRefusedAtRegistration() {
        let registry = InAppToolRegistry()
        let refused = [
            ClarityToolReveal(message: " "),
            ClarityToolReveal(message: String(repeating: "a", count: 81)),
            ClarityToolReveal(message: "Opening…", delayBefore: 3.5),
            ClarityToolReveal(message: "Opening…", holdAfter: -1),
        ]
        for reveal in refused {
            let tool = ClarityTool(name: "open_screen", description: "Opens a screen", reveal: reveal) { _, _ in }
            XCTAssertFalse(registry.register(tool), "\(reveal)")
        }
        let fine = ClarityTool(
            name: "open_screen", description: "Opens a screen",
            reveal: ClarityToolReveal(message: "Opening…", style: .fade, delayBefore: 0, holdAfter: 3)
        ) { _, _ in }
        XCTAssertTrue(registry.register(fine))
    }

    // MARK: - The app's signal, the app's own calls, the events

    func testAToolThatWaitsForTheAppKeepsTheChatAsideUntilItsSignal() {
        let harness = Harness()
        harness.registry.register(screenTool("open_screen", message: "Opening…", holdAfter: nil, waitForApp: true) {
            harness.chat?.events.append($0)
        })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.chat?.ready?()
        harness.fire(300)
        harness.fire(0)
        XCTAssertEqual(harness.chat?.events.last, "run open_screen", "answered, but the app has not said so yet")

        harness.reveals.bringChatBack()

        XCTAssertEqual(harness.chat?.events.last, "back")
    }

    func testWithAPauseAndAWaitForTheAppThePauseWins() {
        let harness = Harness()
        harness.registry.register(screenTool("open_screen", message: "Opening…", holdAfter: 1.0, waitForApp: true) {
            harness.chat?.events.append($0)
        })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.chat?.ready?()
        harness.fire(300)
        harness.fire(0)
        harness.reveals.bringChatBack()
        XCTAssertNotEqual(harness.chat?.events.last, "back", "the signal does not cut the pause short")

        harness.fire(1000)
        XCTAssertEqual(harness.chat?.events.last, "back")
    }

    func testTheChatComesBackOnItsOwnWhenTheSignalNeverComes() {
        let harness = Harness()
        harness.registry.register(screenTool("open_screen", message: "Opening…", holdAfter: nil, waitForApp: true) { _ in })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 20_000)
        harness.chat?.ready?()
        harness.fire(300)
        harness.fire(0)
        harness.fire(InAppRevealCoordinator.signalWaitCapMs)

        XCTAssertEqual(harness.chat?.events.last, "back")
    }

    func testTheAppStepsTheChatAsideAndBringsItBack() {
        let harness = Harness()

        harness.reveals.appStepAside(style: .fade, message: "Loading your plan…")
        harness.chat?.ready?()
        harness.reveals.appUpdate(message: "Almost there…")
        harness.reveals.bringChatBack()

        XCTAssertEqual(harness.chat?.events, ["aside fade: Loading your plan…", "message: Almost there…", "back"])
        XCTAssertEqual(harness.notified, ["aside", "returned"])
    }

    /// The chat tells the app's step-aside from a tool's: during a voice call
    /// only a tool's collapses the call (silently), the app's steps aside and
    /// the app hears it (`WidgetVoice.revealStarting`).
    func testTheChatKnowsWhoSteppedItAside() {
        let app = Harness()
        app.reveals.appStepAside(style: .strip, message: "Loading your plan…")
        XCTAssertEqual(app.chat?.origins, [.app])

        let tool = Harness()
        tool.registry.register(screenTool("open_screen", message: "Opening your plan…") { _ in })
        tool.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        XCTAssertEqual(tool.chat?.origins, [.tool])
    }

    func testBringingTheChatBackWaitsForAToolStillRunning() {
        let harness = Harness()
        var answer: ClarityToolCompletion?
        harness.registry.register(screenTool("open_screen", message: "Opening…", holdAfter: 0, log: { _ in }) {
            answer = $0
        })

        harness.reveals.appStepAside(style: .strip, message: "Loading…")
        harness.chat?.ready?()
        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.fire(300)
        harness.reveals.bringChatBack()
        XCTAssertNotEqual(harness.chat?.events.last, "back", "the tool still runs")

        answer?(.success(nil))
        harness.fire(0)
        harness.fire(0)

        XCTAssertEqual(harness.chat?.events.last, "back")
    }

    func testAClosedChatHoldsNothingForTheNextOne() {
        let harness = Harness()

        harness.reveals.appStepAside(style: .strip, message: "Loading…")
        harness.chat?.ready?()
        harness.reveals.chatClosed()
        harness.registry.register(screenTool("open_screen", message: "Opening…", holdAfter: 0) { _ in })
        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.chat?.ready?()
        harness.fire(300)
        harness.fire(0)
        harness.fire(0)

        XCTAssertEqual(harness.chat?.events.last, "back", "the closed chat's wait for the app does not hold the new one")
    }

    // Regression: holdAfter defaulted to 1 s, so waitForApp alone never waited.
    func testWaitForAppAloneWaitsAndThePauseOtherwiseDefaultsToASecond() {
        XCTAssertNil(ClarityToolReveal(message: "Opening…", waitForApp: true).holdAfter)
        XCTAssertEqual(ClarityToolReveal(message: "Opening…").holdAfter, 1.0)
        XCTAssertEqual(ClarityToolReveal(message: "Opening…", holdAfter: 2, waitForApp: true).holdAfter, 2)
    }

    // Regression (#1682 review 1): closing the chat during the step-aside
    // dropped the queued tool, and the agent got a timeout instead.
    func testClosingTheChatWhileItStepsAsideStillRunsTheTool() {
        let harness = Harness()
        var ran = false
        harness.registry.register(screenTool("open_screen", message: "Opening…") { _ in ran = true })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.reveals.chatClosed()
        harness.fire(300)

        XCTAssertTrue(ran)
        XCTAssertEqual(harness.sent.count, 1)
    }

    // Regression (#1682 review 3): `completion(…); Clarity.bringChatBack()`
    // reached the coordinator before the answer and was lost for 30 s.
    func testBringChatBackRightAfterTheAnswerIsNotLost() {
        let harness = Harness()
        harness.onMain = true
        harness.registry.register(screenTool("open_screen", message: "Opening…", holdAfter: nil, waitForApp: true,
                                             log: { harness.chat?.events.append($0) }) { completion in
            completion(.success(nil))
            harness.reveals.bringChatBack()
        })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.chat?.ready?()
        harness.fire(300)

        XCTAssertEqual(harness.chat?.events.last, "back")
    }

    // Regression (#1682 re-review B): the signal for screen 1 also counted
    // for step 2 still running, which came back while screen 2 loaded.
    func testTheSignalForOneStepDoesNotCountForTheNext() {
        let harness = Harness()
        var answers: [ClarityToolCompletion] = []
        harness.registry.register(screenTool("open_screen", message: "Opening…", holdAfter: nil, waitForApp: true,
                                             log: { _ in }) { answers.append($0) })

        harness.runner.run(callId: "c1", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.chat?.ready?()
        harness.fire(300)
        answers[0](.success(nil))
        harness.fire(0)
        harness.runner.run(callId: "c2", name: "open_screen", kind: .action, arguments: [:], timeoutMs: 30_000)
        harness.fire(300)
        harness.reveals.bringChatBack()  // screen 1 has loaded
        answers[1](.success(nil))
        harness.fire(0)
        XCTAssertNotEqual(harness.chat?.events.last, "back", "screen 2 is still loading")

        harness.reveals.bringChatBack()  // screen 2 has loaded
        XCTAssertEqual(harness.chat?.events.last, "back")
    }

    // Regression (#1682 review 6): a host that heard the chat step aside
    // never heard it come back when the chat was closed meanwhile.
    func testClosingTheChatWhileAsideTellsTheHostItIsBack() {
        let harness = Harness()

        harness.reveals.appStepAside(style: .strip, message: "Loading…")
        harness.chat?.ready?()
        harness.reveals.chatClosed()

        XCTAssertEqual(harness.notified, ["aside", "returned"])
    }
}
