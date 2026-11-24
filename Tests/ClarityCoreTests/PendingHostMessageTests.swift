import XCTest
@testable import ClaritySDK

final class PendingHostMessageTests: XCTestCase {

    func testSentAtOnceWhenThePageIsUp() {
        var pending = PendingHostMessage()
        XCTAssertEqual(pending.request("  My router is offline ", pageLoaded: true), "My router is offline")
        XCTAssertNil(pending.takeOnPageLoaded(), "nothing left for a later pageLoaded")
    }

    func testWaitsForThePageThenIsDeliveredOnce() {
        var pending = PendingHostMessage()
        XCTAssertNil(pending.request("Change my plan", pageLoaded: false))
        XCTAssertEqual(pending.takeOnPageLoaded(), "Change my plan")
        XCTAssertNil(pending.takeOnPageLoaded(), "a page reload must not send it twice")
    }

    func testTheLatestOfTwoWaitingMessagesWins() {
        var pending = PendingHostMessage()
        _ = pending.request("first", pageLoaded: false)
        _ = pending.request("second", pageLoaded: false)
        XCTAssertEqual(pending.takeOnPageLoaded(), "second")
    }

    func testBlankTextIsIgnored() {
        var pending = PendingHostMessage()
        XCTAssertNil(pending.request(" \n ", pageLoaded: true))
        XCTAssertNil(pending.request("", pageLoaded: false))
        XCTAssertNil(pending.takeOnPageLoaded())
    }

    func testCancelDropsTheWaitingText() {
        var pending = PendingHostMessage()
        _ = pending.request("Hello", pageLoaded: false)
        pending.cancel()
        XCTAssertNil(pending.takeOnPageLoaded())
    }
}
