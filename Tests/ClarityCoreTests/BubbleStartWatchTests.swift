import XCTest
@testable import ClaritySDK

/// When a call asked for in the bubble gives up and opens the chat. A fixed
/// 8 s opened the chat while the customer was still answering the microphone
/// prompt, or the call was still connecting (ACX-2288 #5).
final class BubbleStartWatchTests: XCTestCase {

    func testAStartedCallStopsTheWatch() {
        XCTAssertEqual(
            BubbleStartWatch.decide(elapsed: 3, callActive: true, pageAnswered: true, awaitingPermission: false),
            .stop
        )
    }

    func testThePromptStillUpKeepsTheBubble() {
        XCTAssertEqual(
            BubbleStartWatch.decide(elapsed: 12, callActive: false, pageAnswered: true, awaitingPermission: true),
            .keepWaiting
        )
    }

    func testAPageStartingTheCallKeepsTheBubble() {
        XCTAssertEqual(
            BubbleStartWatch.decide(elapsed: 10, callActive: false, pageAnswered: true, awaitingPermission: false),
            .keepWaiting
        )
    }

    /// A page that predates the bubble, or cannot take a call, answers nothing.
    func testAPageThatAnswersNothingOpensTheChat() {
        XCTAssertEqual(
            BubbleStartWatch.decide(
                elapsed: BubbleStartWatch.firstCheck, callActive: false, pageAnswered: false,
                awaitingPermission: false
            ),
            .openChat
        )
    }

    func testTheCapOpensTheChatWhateverHappens() {
        XCTAssertEqual(
            BubbleStartWatch.decide(
                elapsed: BubbleStartWatch.cap, callActive: false, pageAnswered: true, awaitingPermission: true
            ),
            .openChat
        )
    }
}
