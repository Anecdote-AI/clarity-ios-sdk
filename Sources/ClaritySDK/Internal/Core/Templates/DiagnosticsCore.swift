import Foundation

/// `get_diagnostics` (spec 5.11) and `get_location` (5.10) without the OS:
/// the mappings from raw platform values, the errors the app reported, and
/// the result shapes. The collector (`DiagnosticsCollector`) reads the OS.
enum DiagnosticsCore {

    /// What the device lets the app use, as the agent is told.
    enum Permission: String {
        case granted, denied, prompt
        case notDeclared = "not_declared"
        case unknown
    }

    /// `AVAuthorizationStatus.rawValue`: notDetermined 0, restricted 1,
    /// denied 2, authorized 3. Without the Info.plist usage string the app
    /// cannot use it at all.
    static func capturePermission(rawStatus: Int, usageDeclared: Bool) -> Permission {
        guard usageDeclared else { return .notDeclared }
        switch rawStatus {
        case 0: return .prompt
        case 1, 2: return .denied
        case 3: return .granted
        default: return .unknown
        }
    }

    /// The camera or the microphone. Without the Info.plist usage string it
    /// is `not_declared` and the probe is never asked, so an app without the
    /// string never reaches `AVCaptureDevice` (ITMS-90683). A probe that
    /// cannot find the class answers `unknown`.
    static func capturePermission(
        mediaType: String,
        usageDeclared: Bool,
        probe: CaptureDeviceProbe
    ) -> Permission {
        guard usageDeclared else { return .notDeclared }
        guard let status = probe.authorizationStatus(mediaType) else { return .unknown }
        return capturePermission(rawStatus: status, usageDeclared: true)
    }

    /// The number of cameras, only when the app declared the camera usage string.
    static func cameraCount(usageDeclared: Bool, probe: CaptureDeviceProbe) -> Int? {
        usageDeclared ? probe.cameraCount() : nil
    }

    /// `UNAuthorizationStatus.rawValue`: notDetermined 0, denied 1,
    /// authorized 2, provisional 3, ephemeral 4.
    static func notificationPermission(rawStatus: Int) -> Permission {
        switch rawStatus {
        case 0: return .prompt
        case 1: return .denied
        case 2, 3, 4: return .granted
        default: return .unknown
        }
    }

    /// The location as the provider says it, when the location template is
    /// on; `unknown` without the module, `not_declared` without the usage string.
    static func locationPermission(providerStatus: String?, usageDeclared: Bool) -> Permission {
        guard usageDeclared else { return .notDeclared }
        guard let status = providerStatus else { return .unknown }
        return Permission(rawValue: status) ?? .unknown
    }

    struct Environment {
        var osVersion: String
        var device: String
        var appVersion: String?
        var language: String?
        var timezone: String
        var localTime: String
        var screen: String
        var fontScale: Double
        var darkMode: Bool
        var online: Bool?
        var connection: String
        var metered: Bool?
        var dataSaver: Bool?
        var batterySaver: Bool
    }

    static func result(
        environment: Environment,
        permissions: [String: Permission],
        microphones: Int?,
        cameras: Int?,
        appErrors: [[String: Any]]
    ) -> [String: Any] {
        [
            "environment": [
                "platform": ClarityPlatform.identifier,
                "os_version": environment.osVersion,
                "device": environment.device,
                "app_version": environment.appVersion ?? NSNull(),
                "sdk_version": "\(ClarityPlatform.identifier) \(ClarityVersion.current)",
                "language": environment.language ?? NSNull(),
                "timezone": environment.timezone,
                "local_time": environment.localTime,
                "screen": environment.screen,
                "font_scale": (environment.fontScale * 100).rounded() / 100,
                "dark_mode": environment.darkMode,
                "online": environment.online ?? NSNull(),
                "connection": environment.connection,
                "metered": environment.metered ?? NSNull(),
                "data_saver": environment.dataSaver ?? NSNull(),
                "battery_saver": environment.batterySaver,
            ] as [String: Any],
            "permissions": permissions.mapValues(\.rawValue),
            "devices": [
                "microphones": microphones ?? NSNull(),
                "cameras": cameras ?? NSNull(),
                "speakers": NSNull(),
            ] as [String: Any],
            "app_errors": appErrors,
            "last_exit": NSNull(),
        ]
    }

    /// An ISO 8601 time with the device's offset ("2026-11-10T14:03:11+01:00").
    static func isoTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }

    // MARK: - get_location

    /// Two decimals is about a kilometre: enough for "the nearest store".
    static func locationResult(_ fix: ClarityLocationFix) -> [String: Any] {
        [
            "lat": (fix.latitude * 100).rounded() / 100,
            "lon": (fix.longitude * 100).rounded() / 100,
            "accuracy_m": Int(fix.accuracy.rounded()),
        ]
    }

    static func locationError(_ failure: ClarityLocationFailure) -> String {
        switch failure {
        case .denied: return "the customer did not allow the location on the device"
        case .servicesOff: return "location is turned off on the device"
        case .unavailable(let reason): return "the location is unavailable: \(reason)"
        }
    }
}

/// The errors the app reported (`Clarity.recordAppError`): the last 20,
/// in memory. Thread-safe.
final class AppErrorLog {

    static let shared = AppErrorLog()
    static let maxEntries = 20
    static let maxMessage = 200
    static let maxScreen = 100

    private let lock = NSLock()
    private var entries: [[String: Any]] = []

    func record(_ message: String, screen: String?, at date: Date = Date()) {
        let text = ScreenSnapshot.clean(message, limit: Self.maxMessage)
        guard !text.isEmpty else { return }
        let entry: [String: Any] = [
            "message": text,
            "screen": screen.map { ScreenSnapshot.clean($0, limit: Self.maxScreen) } ?? NSNull(),
            "at": DiagnosticsCore.isoTime(date),
        ]
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    var all: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
