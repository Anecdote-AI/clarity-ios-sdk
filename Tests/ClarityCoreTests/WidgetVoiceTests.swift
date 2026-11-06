import XCTest
@testable import ClaritySDK

/// The collapsed voice call: when the sheet shrinks to the bubble, and when it
/// comes back. A wrong answer either hides the chat after the call or brings
/// the sheet back over what the assistant just opened in the app. The Android
/// port is `WidgetVoiceTest.kt`.
final class WidgetVoiceTests: XCTestCase {

    func testCollapsesOnlyDuringACall() {
        var voice = WidgetVoice()
        voice.collapse()
        XCTAssertFalse(voice.collapsed)

        voice.status(state: "listening", label: "Listening")
        voice.collapse()
        XCTAssertTrue(voice.collapsed)
        XCTAssertEqual(voice.label, "Listening")
        XCTAssertEqual(voice.state, "listening")
    }

    func testACallAskedForInTheBubbleIsCollapsedBeforeThePageReportsIt() {
        var voice = WidgetVoice()
        voice.startCollapsed()
        XCTAssertTrue(voice.collapsed)

        voice.status(state: "starting", label: "Getting ready")
        XCTAssertTrue(voice.collapsed)

        // The channel has no voice: the page answers with a call that ended.
        voice.status(state: WidgetVoice.ended, label: "")
        XCTAssertFalse(voice.collapsed)
    }

    func testTheEndOfTheCallBringsTheChatBack() {
        var voice = WidgetVoice()
        voice.status(state: "speaking", label: "Speaking")
        voice.collapse()

        voice.status(state: WidgetVoice.ended, label: "Voice chat ended")

        XCTAssertFalse(voice.callActive)
        XCTAssertFalse(voice.collapsed)
    }

    /// A status with no state is not a call either.
    func testAnEmptyStateIsNoCall() {
        var voice = WidgetVoice()
        voice.status(state: "", label: "")
        voice.collapse()

        XCTAssertFalse(voice.callActive)
        XCTAssertFalse(voice.collapsed)
    }

    func testARevealDuringACallCollapsesInsteadOfSteppingAside() {
        var voice = WidgetVoice()
        voice.status(state: "thinking", label: "Thinking")

        XCTAssertTrue(voice.revealStarting(origin: .tool))
        XCTAssertTrue(voice.collapsed)
    }

    func testARevealWithoutACallStepsAsideAsBefore() {
        var voice = WidgetVoice()
        XCTAssertFalse(voice.revealStarting(origin: .tool))
        XCTAssertFalse(voice.collapsed)
    }

    /// Regression: the app's own `Clarity.stepAside` during a call collapsed
    /// the call, and the app never heard `onChatSteppedAside` (nor, after its
    /// `bringChatBack()`, `onChatReturned`). It steps aside as it always has.
    func testTheAppsOwnStepAsideDuringACallStepsAsideAsBefore() {
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "Listening")

        XCTAssertFalse(voice.revealStarting(origin: .app))
        XCTAssertFalse(voice.collapsed)
    }

    /// The page reports the bubble at each status width; only a real size
    /// counts, and the call opening again forgets it.
    func testTheBubbleSizeIsKeptUntilTheCallOpensAgain() {
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "Listening")
        voice.collapse()

        voice.bubbleMeasured(width: 0, height: 84)
        XCTAssertNil(voice.bubbleSize)
        voice.bubbleMeasured(width: 172, height: 84)
        XCTAssertEqual(voice.bubbleSize, WidgetVoice.BubbleSize(width: 172, height: 84))

        voice.expand()
        XCTAssertNil(voice.bubbleSize)
    }

    func testATapOnTheBubbleOpensTheCallAgain() {
        var voice = WidgetVoice()
        voice.status(state: "listening", label: "Listening")
        voice.collapse()

        voice.expand()

        XCTAssertFalse(voice.collapsed)
        XCTAssertTrue(voice.callActive)
    }

    func testANewPageStartsWithoutACall() {
        var voice = WidgetVoice()
        voice.status(state: "speaking", label: "Speaking")
        voice.collapse()

        voice.reset()

        XCTAssertEqual(voice, WidgetVoice())
        XCTAssertFalse(voice.revealStarting(origin: .tool))
    }
}
