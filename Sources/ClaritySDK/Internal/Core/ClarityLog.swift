import Foundation

/// The SDK's single console-logging channel: every line carries the
/// `[ClaritySDK]` prefix so host-app logs are filterable (and the e2e
/// suite's syslog capture can grep it). Listener-visible debug events go
/// through the engine's `debug(_:)`, which writes here AND notifies.
enum ClarityLog {

    static func log(_ message: String) {
        NSLog("[ClaritySDK] %@", message)
    }
}
