import Foundation

/// Preflight for OS capabilities the widget page can trigger that require
/// HOST-app provisioning (Info.plist usage descriptions). iOS terminates the
/// process outright — a TCC kill, not a catchable exception — when a
/// privacy-gated API is touched without its usage description, so the SDK
/// must know in advance what the host is provisioned for and refuse the
/// dangerous path instead of letting the OS kill the app. Consumers:
/// the init-time host-app audit (`WidgetEngine.initialize`), the
/// camera-picker airbag (`ClarityWidgetViewController.present`) and the
/// getUserMedia gate (`WidgetEngine+WebKitBridge`).
enum HostCapabilities {

    static let cameraUsageKey = "NSCameraUsageDescription"
    static let microphoneUsageKey = "NSMicrophoneUsageDescription"

    /// True when the host app's Info.plist carries a non-empty
    /// `NSCameraUsageDescription` — the precondition for WebKit's
    /// "Take Photo" file-upload source and for page camera capture.
    static var cameraCaptureProvisioned: Bool {
        hasUsageDescription(cameraUsageKey, in: Bundle.main.infoDictionary)
    }

    /// True when the host app's Info.plist carries a non-empty
    /// `NSMicrophoneUsageDescription` — the precondition for getUserMedia
    /// audio (voice calls, composer dictation). Also decides whether the
    /// widget URL advertises the microphone to the page (`WidgetURL`).
    static var microphoneCaptureProvisioned: Bool {
        hasUsageDescription(microphoneUsageKey, in: Bundle.main.infoDictionary)
    }

    /// The check itself, seamed on the info dictionary: `Bundle.main` is
    /// fixed per process, so tests exercise this with literal dictionaries.
    /// An empty or whitespace-only description is treated as missing — the
    /// App Store rejects empty strings, and a blank prompt would be as
    /// unshippable as none.
    static func hasUsageDescription(_ key: String, in info: [String: Any]?) -> Bool {
        guard let value = info?[key] as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
