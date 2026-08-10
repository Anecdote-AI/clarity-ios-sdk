import XCTest
@testable import ClaritySDK

/// The whole contract of a screen that must never reach a customer. Asserted
/// directly rather than inferred from a simulator run, because the failure mode
/// — a diagnostic leaking into a release build — is precisely the kind a green
/// e2e suite would not notice. Mirrors `DiagnosticGateTest.kt` case for case.
final class DiagnosticGateTests: XCTestCase {

    func testReleaseBuildShowsNothing() {
        XCTAssertFalse(
            DiagnosticGate.shouldPresent(
                override: nil, defaultEnabled: false, showWasPending: true
            )
        )
    }

    func testDebugBuildShowsItWhenSomeoneWasWaitingForTheWidget() {
        XCTAssertTrue(
            DiagnosticGate.shouldPresent(
                override: nil, defaultEnabled: true, showWasPending: true
            )
        )
    }

    /// A background pre-warm failing must never steal the screen.
    func testAFailedPreloadStaysSilentEvenInADebugBuild() {
        XCTAssertFalse(
            DiagnosticGate.shouldPresent(
                override: nil, defaultEnabled: true, showWasPending: false
            )
        )
    }

    func testAnExplicitTrueOverridesAReleaseDefault() {
        XCTAssertTrue(
            DiagnosticGate.shouldPresent(
                override: true, defaultEnabled: false, showWasPending: true
            )
        )
    }

    /// The opt-out has to work, or an integrator cannot silence it.
    func testAnExplicitFalseWinsOverADebugDefault() {
        XCTAssertFalse(
            DiagnosticGate.shouldPresent(
                override: false, defaultEnabled: true, showWasPending: true
            )
        )
    }

    /// No override can defeat the pending-show rule.
    func testEvenAnExplicitTrueStaysSilentForAPreload() {
        XCTAssertFalse(
            DiagnosticGate.shouldPresent(
                override: true, defaultEnabled: true, showWasPending: false
            )
        )
    }
}
