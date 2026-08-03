import XCTest
@testable import ClaritySDK

/// The handshake failure classifier: only a 4xx is a credential rejection
/// (non-recoverable); a 5xx that exhausted the retries — or no HTTP response
/// at all — must stay recoverable. Regression for the review finding where
/// any preserved HTTP status (including 500) was reported as
/// `handshakeRejected` with `recoverable == false`.
final class HandshakeClassificationTests: XCTestCase {

    func testNoHttpResponseIsNetwork() {
        XCTAssertEqual(ClarityError.Kind.forHandshakeFailure(lastHttpCode: nil), .network)
    }

    func testRejectionRangeBoundsAreRejected() {
        XCTAssertEqual(ClarityError.Kind.forHandshakeFailure(lastHttpCode: 400), .handshakeRejected)
        XCTAssertEqual(ClarityError.Kind.forHandshakeFailure(lastHttpCode: 404), .handshakeRejected)
        XCTAssertEqual(ClarityError.Kind.forHandshakeFailure(lastHttpCode: 499), .handshakeRejected)
    }

    func testServerErrorsStayRecoverable() {
        for code in [500, 502, 503, 599] {
            let kind = ClarityError.Kind.forHandshakeFailure(lastHttpCode: code)
            XCTAssertEqual(kind, .network, "HTTP \(code) must classify as transient")
            let error = ClarityError(kind: kind, code: code, message: "test")
            XCTAssertTrue(error.recoverable, "HTTP \(code) must be recoverable")
        }
    }

    func testRejectedIsTheOnlyNonRecoverableKind() {
        XCTAssertFalse(
            ClarityError(kind: .handshakeRejected, code: 404, message: "test").recoverable
        )
        XCTAssertTrue(ClarityError(kind: .network, code: 500, message: "test").recoverable)
    }
}
