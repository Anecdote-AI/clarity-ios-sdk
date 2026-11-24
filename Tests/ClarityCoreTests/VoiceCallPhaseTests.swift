import XCTest
@testable import ClaritySDK

/// What the host app hears of a voice call (`ClarityListener.onVoiceCallEvent`,
/// `Clarity.isVoiceCallActive`). Without it an app could not tell a call was
/// still on after the customer closed the sheet (ACX-2288 #3).
final class VoiceCallPhaseTests: XCTestCase {

    private func events(_ change: (inout WidgetVoice) -> Void, from start: WidgetVoice = WidgetVoice()) -> [ClarityVoiceCallEvent] {
        var voice = start
        let before = voice.phase
        change(&voice)
        return voice.phase.events(since: before)
    }

    func testAStartingCallIsStarted() {
        XCTAssertEqual(events { $0.status(state: "starting", label: "") }, [.started])
    }

    func testAStatusDuringTheCallIsNoEvent() {
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "")
        XCTAssertEqual(events({ $0.status(state: "speaking", label: "") }, from: voice), [])
    }

    func testCollapseAndExpandDuringTheCall() {
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "")
        XCTAssertEqual(events({ $0.collapse() }, from: voice), [.collapsed])
        voice.collapse()
        XCTAssertEqual(events({ $0.expand() }, from: voice), [.expanded])
    }

    func testACallAskedForInTheBubbleStartsCollapsed() {
        var voice = WidgetVoice()
        voice.startCollapsed()
        // No call yet: the bubble alone is no event.
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(events({ $0.status(state: "starting", label: "") }, from: voice), [.started, .collapsed])
    }

    /// `Clarity.isVoiceCallActive` reads `callActive` (the getter itself sits
    /// behind UIKit, which `swift test` has no window for): on from the call's
    /// first status, in the sheet or collapsed to the bubble, off the moment
    /// it ends however it ends, and off while only a bubble is asked for.
    func testCallActiveIsWhatIsVoiceCallActiveReports() {
        var voice = WidgetVoice()
        XCTAssertFalse(voice.callActive, "no call yet")

        voice.startCollapsed()
        XCTAssertFalse(voice.callActive, "a bubble asked for is not a call")

        voice.status(state: "starting", label: "")
        XCTAssertTrue(voice.callActive)
        voice.collapse()
        XCTAssertTrue(voice.callActive, "the bubble is a call going on")
        voice.expand()
        XCTAssertTrue(voice.callActive)

        var endedByPage = voice
        endedByPage.status(state: WidgetVoice.ended, label: "")
        XCTAssertFalse(endedByPage.callActive)

        var pageGone = voice
        pageGone.reset()
        XCTAssertFalse(pageGone.callActive)

        var endedByHost = voice
        endedByHost.endedByHost()
        XCTAssertFalse(endedByHost.callActive, "dismiss() ends it before the page says so")
    }

    func testTheEndOfTheCallIsEndedOnce() {
        var voice = WidgetVoice()
        voice.status(state: "speaking", label: "")
        voice.collapse()
        XCTAssertEqual(events({ $0.status(state: WidgetVoice.ended, label: "") }, from: voice), [.ended])
        voice.status(state: WidgetVoice.ended, label: "")
        XCTAssertEqual(events({ $0.status(state: WidgetVoice.ended, label: "") }, from: voice), [])
    }

    func testThePageGoingAwayEndsTheCall() {
        var voice = WidgetVoice()
        voice.status(state: "thinking", label: "")
        XCTAssertEqual(events({ $0.reset() }, from: voice), [.ended])
    }

    /// The host's `dismiss()` ends a call in the sheet at once, so the sheet
    /// closes instead of collapsing to the bubble (ACX-2288 #2).
    func testTheHostEndingTheCallIsOverBeforeThePageSaysSo() {
        var voice = WidgetVoice()
        voice.status(state: "speaking", label: "")
        voice.endedByHost()
        XCTAssertFalse(voice.callActive)
        XCTAssertFalse(voice.collapsed)
        XCTAssertEqual(voice.phase, .idle)
    }

    /// A status the page sent before it heard the host end the call is not a
    /// new call: taken at its word, the host heard `started` and then a second
    /// `ended` when the page went away (`resetSession`).
    func testAStatusInFlightWhenTheHostEndedTheCallIsNoNewCall() {
        let ended = Date(timeIntervalSince1970: 1_000)
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "")
        voice.endedByHost(now: ended)

        let late = events({ $0.status(state: "speaking", label: "", now: ended.addingTimeInterval(0.1)) }, from: voice)
        XCTAssertEqual(late, [])

        voice.status(state: "speaking", label: "", now: ended.addingTimeInterval(0.1))
        XCTAssertFalse(voice.callActive)
        XCTAssertEqual(events({ $0.reset() }, from: voice), [])
    }

    /// The page agreeing the call is over closes the window: the customer's
    /// next call, from the chat itself, is heard.
    func testThePageEndingTheCallClosesTheWindow() {
        let ended = Date(timeIntervalSince1970: 1_000)
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "")
        voice.endedByHost(now: ended)
        voice.status(state: WidgetVoice.ended, label: "", now: ended.addingTimeInterval(0.2))

        let next = events({ $0.status(state: "starting", label: "", now: ended.addingTimeInterval(0.5)) }, from: voice)
        XCTAssertEqual(next, [.started])
    }

    /// Past the grace, a call the page reports is a call, even if it never
    /// said the previous one ended.
    func testACallReportedAfterTheGraceIsHeard() {
        let ended = Date(timeIntervalSince1970: 1_000)
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "")
        voice.endedByHost(now: ended)

        let later = ended.addingTimeInterval(WidgetVoice.hostEndGrace + 0.1)
        XCTAssertEqual(events({ $0.status(state: "starting", label: "", now: later) }, from: voice), [.started])
    }

    /// The host asking for a call again is not held back by the one it ended.
    func testANewCallAskedForRightAfterTheHostEndedOneIsHeard() {
        let ended = Date(timeIntervalSince1970: 1_000)
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "")
        voice.endedByHost(now: ended)
        voice.callRequested()

        let next = events({ $0.status(state: "starting", label: "", now: ended.addingTimeInterval(0.3)) }, from: voice)
        XCTAssertEqual(next, [.started])
    }

    /// `startVoiceCall(.bubble)` with the call on in the sheet collapses it
    /// (Android parity); `.sheet` leaves it on screen. Neither starts another.
    func testAskingForTheBubbleDuringACallInTheSheetCollapsesIt() {
        XCTAssertTrue(VoiceStartRoute.collapsesLiveCall(.bubble))
        XCTAssertFalse(VoiceStartRoute.collapsesLiveCall(.sheet))
    }

    /// Review of #2190: `Clarity.dismiss()` on a call in the bubble marked
    /// nothing over, so the close that followed (`widgetDidClose` →
    /// `expand()`) told the host `expanded` and `isVoiceCallActive` stayed on.
    func testTheHostClosingTheBubbleIsEndedNeverExpanded() {
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "")
        voice.collapse()
        var heard: [ClarityVoiceCallEvent] = []
        var before = voice.phase
        XCTAssertTrue(voice.hostClosed(pageLoaded: true))
        heard += voice.phase.events(since: before)
        before = voice.phase
        voice.expand()
        heard += voice.phase.events(since: before)
        XCTAssertEqual(heard, [.ended])
        XCTAssertFalse(voice.phase.active)
    }

    /// A call asked for that the page has not reported yet is called off with
    /// the widget: the page must hear it, or the call starts later with no
    /// window. No event: the host never heard `started`.
    func testTheHostClosingBeforeTheCallMountedTellsThePage() {
        var voice = WidgetVoice()
        XCTAssertTrue(voice.hostClosed(pageLoaded: true))
        XCTAssertEqual(voice.phase, .idle)
    }

    func testNothingToTellAPageThatIsNotLoaded() {
        var voice = WidgetVoice()
        XCTAssertFalse(voice.hostClosed(pageLoaded: false))
    }

    /// The stc tv sheet spinner: a call asked for in the sheet with the page
    /// already loaded went to the WebView before the sheet was on screen, and
    /// WebKit held its microphone request for good.
    func testACallInTheSheetNeverStartsBeforeTheSheetIsOnScreen() {
        XCTAssertEqual(VoiceStartRoute.sheetStart(pageLoaded: true, sheetOnScreen: false), .onceOnScreen)
        XCTAssertEqual(VoiceStartRoute.sheetStart(pageLoaded: true, sheetOnScreen: true), .now)
        XCTAssertEqual(VoiceStartRoute.sheetStart(pageLoaded: false, sheetOnScreen: true), .afterLoad)
        XCTAssertEqual(VoiceStartRoute.sheetStart(pageLoaded: false, sheetOnScreen: false), .afterLoad)
    }
}
