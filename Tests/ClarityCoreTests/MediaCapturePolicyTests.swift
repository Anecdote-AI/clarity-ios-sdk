import XCTest
@testable import ClaritySDK

/// The widget's answer to the page's microphone/camera request. WebKit's
/// default asked the customer on every page load even after the app was
/// allowed (ACX-2288 #4).
final class MediaCapturePolicyTests: XCTestCase {

    func testAnAllowedAppGetsTheDeviceWithoutAsking() {
        XCTAssertEqual(MediaCapturePolicy.verdict(missingUsageKeys: [], permissions: [.granted]), .grant)
    }

    func testAnAppNotYetAskedAsksTheSystemOnce() {
        XCTAssertEqual(MediaCapturePolicy.verdict(missingUsageKeys: [], permissions: [.undetermined]), .askSystem)
        XCTAssertEqual(
            MediaCapturePolicy.verdict(missingUsageKeys: [], permissions: [.granted, .undetermined]), .askSystem
        )
    }

    func testARefusalIsKept() {
        XCTAssertEqual(MediaCapturePolicy.verdict(missingUsageKeys: [], permissions: [.denied]), .deny)
        XCTAssertEqual(
            MediaCapturePolicy.verdict(missingUsageKeys: [], permissions: [.undetermined, .denied]), .deny
        )
    }

    /// Without the usage description the OS kills the app on capture.
    func testAnUnprovisionedAppIsAlwaysDenied() {
        XCTAssertEqual(
            MediaCapturePolicy.verdict(
                missingUsageKeys: [HostCapabilities.microphoneUsageKey], permissions: [.granted]
            ),
            .deny
        )
    }
}
