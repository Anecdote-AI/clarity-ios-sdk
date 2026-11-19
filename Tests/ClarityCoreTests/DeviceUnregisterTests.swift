import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ClaritySDK

/// After a logout or an identity switch the device token is unbound from the
/// session that ended, read from its cookie before the wipe. Android twin:
/// `DeviceUnregisterTest.kt`.
final class DeviceUnregisterTests: XCTestCase {

    private let session = "0f8fad5b-d9cb-469f-a165-70867728950e"
    private let stageSession = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

    func testReadsTheWidgetSessionCookie() {
        let ids = DeviceUnregister.sessionIds(fromCookies: [
            (name: "ai_livechat_session_id", value: stageSession),
            (name: "livechat_session_id", value: session),
            (name: "_ga", value: "GA1.2.3"),
        ])
        XCTAssertEqual(ids, [session])
    }

    /// Dev and stage name the cookie after the stand.
    func testReadsAPerStandCookieAfterTheProductionOne() {
        let ids = DeviceUnregister.sessionIds(fromCookies: [
            (name: "livechat_session_id_stage", value: stageSession),
            (name: "livechat_session_id", value: session),
            (name: "livechat_session_id_dev", value: session),
        ])
        XCTAssertEqual(ids, [session, stageSession])
    }

    func testSkipsAValueThatIsNoSession() {
        XCTAssertEqual(
            DeviceUnregister.sessionIds(fromCookies: [(name: "livechat_session_id", value: "deleted")]),
            []
        )
        XCTAssertEqual(DeviceUnregister.sessionIds(fromCookies: []), [])
    }

    func testTheRequestNamesTheSessionInTheHeaderAndTheTokenInTheBody() throws {
        let request = try XCTUnwrap(DeviceUnregister.request(
            baseUrl: "https://chat.example.com/", sessionId: session, deviceToken: "abc123"
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://chat.example.com/api/live-chat/device/unregister")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Live-Chat-Authorization"), session)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(JSONEncoding.object(from: body)?["device_token"] as? String, "abc123")
    }
}
