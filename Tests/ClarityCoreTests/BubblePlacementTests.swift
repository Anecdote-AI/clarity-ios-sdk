import XCTest
@testable import ClaritySDK

/// The dragged bubble: where it sticks, and that it never goes under the bars,
/// off the screen or under the keyboard. The Android port is
/// `BubblePlacementTest.kt`.
final class BubblePlacementTests: XCTestCase {

    private let area = BubblePlacement.Area(
        width: 400, height: 800, barTop: 50, barBottom: 30, barLeft: 0, barRight: 0,
        keyboard: 0, margin: 6, rightToLeft: false
    )
    private let w = 160.0
    private let h = 80.0

    func testTheDefaultCornerIsTheBottomEndClearOfTheBars() {
        let placed = BubblePlacement.corner(area, width: w, height: h, top: false, start: false)

        XCTAssertEqual(placed.left, 400 - 6 - 160)
        XCTAssertEqual(placed.top, 800 - 30 - 6 - 80)
        XCTAssertFalse(placed.onStartSide)
    }

    func testLetGoLeftOfTheMiddleItSticksToTheLeft() {
        let placed = BubblePlacement.dropped(area, left: 90, top: 300, width: w, height: h)

        XCTAssertEqual(placed.left, 6)
        XCTAssertEqual(placed.top, 300)
        XCTAssertTrue(placed.onStartSide)
    }

    func testInARightToLeftLayoutTheLeftSideIsTheEnd() {
        var rtl = area
        rtl.rightToLeft = true

        XCTAssertFalse(BubblePlacement.dropped(rtl, left: 0, top: 300, width: w, height: h).onStartSide)
    }

    func testItNeverGoesUnderTheStatusBarOrOffTheScreen() {
        let start = BubblePlacement.corner(area, width: w, height: h, top: true, start: true)

        let dragged = start.moved(by: -300, -300, in: area, width: w, height: h)

        XCTAssertEqual(dragged.left, 6)
        XCTAssertEqual(dragged.top, 56)
    }

    func testTheKeyboardPushesItUpAndItGoesBackAfter() {
        var keyboardUp = area
        keyboardUp.keyboard = 300
        // Laid out first while the keyboard was up.
        let placed = BubblePlacement.corner(keyboardUp, width: w, height: h, top: false, start: false)

        XCTAssertEqual(placed.clamped(to: keyboardUp, width: w, height: h).top, 800 - 300 - 6 - 80)
        // Regression: the corner was saved above the keyboard and stayed there.
        XCTAssertEqual(placed.clamped(to: area, width: w, height: h).top, 800 - 30 - 6 - 80)
    }

    func testABubbleOnTheRightThatGrowsKeepsItsRightEdge() {
        let placed = BubblePlacement.corner(area, width: w, height: h, top: false, start: false)

        XCTAssertEqual(placed.stuckToSide(area, width: 200, height: h).left, 400 - 6 - 200)
    }

    /// Regression: the page's `side` came from the app's language while the
    /// bubble was placed by its own view's direction (an app that turns its
    /// views round with `semanticContentAttribute`), so the aura faced inwards.
    /// The side is the edge the bubble was placed on.
    func testThePagesSideIsTheEdgeTheBubbleIsOn() {
        var rtl = area
        rtl.rightToLeft = true

        let corner = BubblePlacement.corner(rtl, width: w, height: h, top: false, start: true)
        XCTAssertEqual(corner.left, 400 - 6 - 160, "the start corner is on the right")
        XCTAssertFalse(corner.onLeft(in: rtl))
        XCTAssertFalse(BubblePlacement.cornerOnLeft(start: true, rightToLeft: true))

        let dropped = BubblePlacement.dropped(rtl, left: 10, top: 300, width: w, height: h)
        XCTAssertEqual(dropped.left, 6)
        XCTAssertTrue(dropped.onLeft(in: rtl), "dropped on the left, whatever start means")
        XCTAssertTrue(BubblePlacement.dropped(area, left: 10, top: 300, width: w, height: h).onLeft(in: area))
    }

    /// Regression: the spring started at the throw's whole speed, so a flick
    /// back to the right that ended left of the middle shot the bubble left
    /// at that speed. Only the part of the throw towards the target counts.
    func testTheSpringCarriesOnlyTheThrowTowardsTheTarget() {
        // 100 pt to fly to the left; a flick to the right launches nothing.
        XCTAssertEqual(
            BubblePlacement.throwVelocity(velocityX: 900, velocityY: 0, toX: -100, 0, max: 8), 0
        )
        // Thrown straight at it: its speed in flight-distances a second.
        XCTAssertEqual(
            BubblePlacement.throwVelocity(velocityX: -300, velocityY: 0, toX: -100, 0, max: 8), 3
        )
        // Thrown across the flight, only the part along it counts.
        XCTAssertEqual(
            BubblePlacement.throwVelocity(velocityX: -300, velocityY: 2000, toX: -100, 0, max: 8), 3
        )
        // A hard throw is capped, and an empty flight launches nothing.
        XCTAssertEqual(
            BubblePlacement.throwVelocity(velocityX: -5000, velocityY: 0, toX: -100, 0, max: 8), 8
        )
        XCTAssertEqual(
            BubblePlacement.throwVelocity(velocityX: -5000, velocityY: 0, toX: 0, 0.5, max: 8), 0
        )
    }
}
