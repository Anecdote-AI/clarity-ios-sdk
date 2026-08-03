import XCTest
@testable import ClaritySDK

/// The usage-description check backing the camera-capture airbag: a wrong
/// answer here either re-opens the TCC-kill crash (false positive) or
/// blocks a correctly provisioned host's camera (false negative).
final class HostCapabilitiesTests: XCTestCase {

    private let key = HostCapabilities.cameraUsageKey

    func testMissingKeyIsNotProvisioned() {
        XCTAssertFalse(HostCapabilities.hasUsageDescription(key, in: [:]))
        XCTAssertFalse(HostCapabilities.hasUsageDescription(key, in: nil))
    }

    func testEmptyAndWhitespaceDescriptionsAreNotProvisioned() {
        XCTAssertFalse(HostCapabilities.hasUsageDescription(key, in: [key: ""]))
        XCTAssertFalse(HostCapabilities.hasUsageDescription(key, in: [key: "  \n "]))
    }

    func testNonStringValueIsNotProvisioned() {
        XCTAssertFalse(HostCapabilities.hasUsageDescription(key, in: [key: 1]))
        XCTAssertFalse(HostCapabilities.hasUsageDescription(key, in: [key: true]))
    }

    func testRealDescriptionIsProvisioned() {
        XCTAssertTrue(HostCapabilities.hasUsageDescription(
            key, in: [key: "Camera is used to attach photos."]
        ))
    }

    func testOtherKeysDoNotSatisfyTheCheck() {
        XCTAssertFalse(HostCapabilities.hasUsageDescription(
            key, in: [HostCapabilities.microphoneUsageKey: "Mic prompt"]
        ))
    }
}
