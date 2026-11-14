#if os(iOS)
import CoreLocation
import Foundation
// A module of its own with Swift Package Manager (`import ClarityLocation`);
// part of ClaritySDK itself with the CocoaPods subspec `ClaritySDK/Location`
// (the podspec sets CLARITY_COCOAPODS), which must not import itself.
#if !CLARITY_COCOAPODS
import ClaritySDK
#endif

/// The location for the `get_location` in-app tool, from CoreLocation.
///
/// It lives apart from the core SDK so an app that does not use the location
/// never links the location APIs (App Store review flags a binary that does
/// without a usage string). Add `NSLocationWhenInUseUsageDescription` to your
/// Info.plist, then:
///
/// ```swift
/// config.inAppToolTemplates = ClarityToolTemplates(
///     location: .with(.init(provider: ClarityCoreLocation()))
/// )
/// ```
///
/// The system asks the customer once, after they allowed the location on the
/// chat's card; the fix is about a kilometre accurate, and a reduced-accuracy
/// grant is enough.
public final class ClarityCoreLocation: NSObject, ClarityLocationProvider, CLLocationManagerDelegate, @unchecked Sendable {

    private var manager: CLLocationManager?
    private var waiting: [(Result<ClarityLocationFix, ClarityLocationFailure>) -> Void] = []
    private var maximumAge: TimeInterval = 60
    private var timeout: TimeInterval = 15
    private var generation = 0

    public override init() {
        super.init()
    }

    @MainActor
    public func authorizationStatus() -> String {
        switch locationManager().authorizationStatus {
        case .notDetermined: return "prompt"
        case .denied, .restricted: return "denied"
        case .authorizedAlways, .authorizedWhenInUse: return "granted"
        @unknown default: return "unknown"
        }
    }

    @MainActor
    public func requestLocation(
        timeout: TimeInterval,
        maximumAge: TimeInterval,
        completion: @escaping @Sendable (Result<ClarityLocationFix, ClarityLocationFailure>) -> Void
    ) {
        self.maximumAge = maximumAge
        self.timeout = timeout
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        generation += 1
        let current = generation
        // Asked off the main thread, as CoreLocation wants.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                guard enabled else { return self.finish(.failure(.servicesOff)) }
                self.proceed()
            }
        }
    }

    private func locationManager() -> CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyKilometer
        manager = created
        return created
    }

    private func proceed() {
        let manager = locationManager()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.failure(.denied))
        default:
            if let last = manager.location, -last.timestamp.timeIntervalSinceNow <= maximumAge {
                finish(.success(fix(last)))
            } else {
                // The time for a fix counts from here: the customer's answer
                // to the system's permission prompt is not part of it.
                let current = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.finish(.failure(.unavailable("the device did not find it in time")))
                }
                manager.requestLocation()
            }
        }
    }

    private func fix(_ location: CLLocation) -> ClarityLocationFix {
        ClarityLocationFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy
        )
    }

    private func finish(_ result: Result<ClarityLocationFix, ClarityLocationFailure>) {
        let callbacks = waiting
        waiting.removeAll()
        generation += 1
        callbacks.forEach { $0(result) }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.waiting.isEmpty, manager.authorizationStatus != .notDetermined else { return }
            self.proceed()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.waiting.isEmpty else { return }
            self.finish(.success(self.fix(last)))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.waiting.isEmpty else { return }
            if (error as? CLError)?.code == .denied {
                self.finish(.failure(.denied))
            } else {
                self.finish(.failure(.unavailable(error.localizedDescription)))
            }
        }
    }
}
#endif
