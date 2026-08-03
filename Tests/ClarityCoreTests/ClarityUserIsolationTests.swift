import XCTest
@testable import ClaritySDK

/// Session isolation on `identify` is decided by the stable identity key
/// (`externalId`), never by whole-profile equality. Regression for the review
/// finding where re-identifying the same user with a newly known email wiped
/// their cookies, attributes, queued events and unread state.
final class ClarityUserIsolationTests: XCTestCase {

    func testSameExternalIdWithNewProfileFieldsIsNotASwitch() {
        let before = ClarityUser(externalId: "u1", email: nil)
        let after = ClarityUser(
            externalId: "u1", firstName: "Ada", lastName: "L", email: "ada@example.com"
        )
        XCTAssertFalse(before.requiresSessionIsolation(switchingTo: after))
    }

    func testDifferentExternalIdIsASwitch() {
        let userA = ClarityUser(externalId: "u1", email: "a@example.com")
        let userB = ClarityUser(externalId: "u2", email: "a@example.com")
        XCTAssertTrue(userA.requiresSessionIsolation(switchingTo: userB))
    }

    func testDroppingTheExternalIdIsASwitch() {
        let identified = ClarityUser(externalId: "u1")
        let anonymous = ClarityUser(firstName: "Guest")
        XCTAssertTrue(identified.requiresSessionIsolation(switchingTo: anonymous))
    }

    func testAnonymousPreviousUserIsNeverWiped() {
        // Empty visitor → identified: the platform merges the visitor.
        XCTAssertFalse(
            ClarityUser().requiresSessionIsolation(switchingTo: ClarityUser(externalId: "u1"))
        )
        // Anonymous with profile fields → identified: still a merge.
        let namedGuest = ClarityUser(firstName: "Guest", email: "guest@example.com")
        XCTAssertFalse(
            namedGuest.requiresSessionIsolation(switchingTo: ClarityUser(externalId: "u1"))
        )
        // Anonymous → anonymous profile change: same visitor.
        XCTAssertFalse(
            namedGuest.requiresSessionIsolation(switchingTo: ClarityUser(firstName: "Renamed"))
        )
    }
}
