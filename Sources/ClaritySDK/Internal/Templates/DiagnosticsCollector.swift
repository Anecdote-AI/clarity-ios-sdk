#if canImport(UIKit)
// AVFAudio, not AVFoundation: the core must not reference AVCaptureDevice
// (see CaptureDeviceProbe).
import AVFAudio
import Network
import UIKit
import UserNotifications

/// Reads what `get_diagnostics` reports from the OS (spec 5.11). Never a
/// device identifier, the IP, the Wi-Fi name, the carrier, disk space or
/// boot time. Main thread in, main thread out.
enum DiagnosticsCollector {

    static func collect(
        locationStatus: String?,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let group = DispatchGroup()
        var notifications: DiagnosticsCore.Permission = .unknown
        var network: (online: Bool?, connection: String, metered: Bool?, constrained: Bool?) = (nil, "unknown", nil, nil)

        group.enter()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            notifications = DiagnosticsCore.notificationPermission(rawStatus: settings.authorizationStatus.rawValue)
            group.leave()
        }

        group.enter()
        let monitor = NWPathMonitor()
        let once = OnceFlag()
        monitor.pathUpdateHandler = { path in
            guard once.claim() else { return }
            let connection: String
            if path.status != .satisfied {
                connection = "none"
            } else if path.usesInterfaceType(.wifi) {
                connection = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                connection = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                connection = "ethernet"
            } else {
                connection = "other"
            }
            network = (path.status == .satisfied, connection, path.isExpensive, path.isConstrained)
            monitor.cancel()
            group.leave()
        }
        monitor.start(queue: DispatchQueue(label: "com.onclarity.clarity.diagnostics"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if once.claim() {
                monitor.cancel()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let info = Bundle.main.infoDictionary
            let probe = CaptureDeviceProbe.runtime
            let cameraDeclared = HostCapabilities.hasUsageDescription(HostCapabilities.cameraUsageKey, in: info)
            let permissions: [String: DiagnosticsCore.Permission] = [
                "microphone": DiagnosticsCore.capturePermission(
                    mediaType: CaptureDeviceProbe.audio,
                    usageDeclared: HostCapabilities.hasUsageDescription(HostCapabilities.microphoneUsageKey, in: info),
                    probe: probe
                ),
                "camera": DiagnosticsCore.capturePermission(
                    mediaType: CaptureDeviceProbe.video,
                    usageDeclared: cameraDeclared,
                    probe: probe
                ),
                "geolocation": DiagnosticsCore.locationPermission(
                    providerStatus: locationStatus,
                    usageDeclared: HostCapabilities.hasUsageDescription(HostCapabilities.locationUsageKey, in: info)
                ),
                "notifications": notifications,
            ]
            let environment = DiagnosticsCore.Environment(
                osVersion: UIDevice.current.systemVersion,
                device: deviceModel(),
                appVersion: appVersion(info),
                language: Locale.preferredLanguages.first,
                timezone: TimeZone.current.identifier,
                localTime: DiagnosticsCore.isoTime(Date()),
                screen: screenSize(),
                fontScale: Double(UIFontMetrics.default.scaledValue(for: 17) / 17),
                darkMode: UIScreen.main.traitCollection.userInterfaceStyle == .dark,
                online: network.online,
                connection: network.connection,
                metered: network.metered,
                dataSaver: network.constrained,
                batterySaver: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            completion(DiagnosticsCore.result(
                environment: environment,
                permissions: permissions,
                microphones: AVAudioSession.sharedInstance().availableInputs?.count,
                cameras: DiagnosticsCore.cameraCount(usageDeclared: cameraDeclared, probe: probe),
                appErrors: AppErrorLog.shared.all
            ))
        }
    }

    /// "Apple iPhone15,2": the model, never an identifier of the device.
    private static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "Apple \(simulated) (simulator)"
        }
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "Apple \(machine)"
    }

    private static func appVersion(_ info: [String: Any]?) -> String? {
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private static func screenSize() -> String {
        let size = UIScreen.main.nativeBounds.size
        return "\(Int(size.width))x\(Int(size.height))"
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
#endif
