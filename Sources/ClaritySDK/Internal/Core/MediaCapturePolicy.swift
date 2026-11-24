import Foundation

/// What the widget answers a page's request for the microphone or camera
/// (`getUserMedia`).
///
/// WebKit asks for every page load by default, on top of the system prompt the
/// app already answered, so a customer starting a voice call was asked again
/// each time. The SDK decides instead: an app without the usage description
/// gets a refusal (the OS would kill it), an app the customer already allowed
/// gets the device, and an app not yet asked shows the system prompt once and
/// takes its answer.
enum MediaCapturePolicy {

    /// The system's answer for one device, as the app sees it.
    enum SystemPermission: Equatable {
        case granted
        case denied
        case undetermined
    }

    enum Verdict: Equatable {
        case grant
        case deny
        /// Ask the system for the devices still undetermined, then decide.
        case askSystem
    }

    static func verdict(missingUsageKeys: [String], permissions: [SystemPermission]) -> Verdict {
        guard missingUsageKeys.isEmpty else { return .deny }
        if permissions.contains(.denied) { return .deny }
        if permissions.contains(.undetermined) { return .askSystem }
        return .grant
    }
}
