import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// Reads the camera and the microphone for `get_diagnostics` without a
/// static reference to `AVCaptureDevice`.
///
/// App Store Connect flags an app that references a privacy-sensitive API
/// without the matching Info.plist usage string (ITMS-90683), and the SDK is
/// linked into every integrator's app. So the core names the class only at
/// run time, and only after the app declared the usage string
/// (`DiagnosticsCore.capture`).
struct CaptureDeviceProbe {

    /// `AVMediaType.video` / `AVMediaType.audio`.
    static let video = "vide"
    static let audio = "soun"

    /// The built-in camera types `cameraCount` asks for
    /// (`AVCaptureDevice.DeviceType` raw values).
    static let cameraTypes = [
        "AVCaptureDeviceTypeBuiltInWideAngleCamera",
        "AVCaptureDeviceTypeBuiltInTelephotoCamera",
        "AVCaptureDeviceTypeBuiltInUltraWideCamera",
        "AVCaptureDeviceTypeBuiltInTrueDepthCamera",
    ]

    /// `AVAuthorizationStatus.rawValue` for a media type; nil when the class
    /// is not there.
    var authorizationStatus: (String) -> Int?
    /// The number of built-in cameras; nil when the class is not there.
    var cameraCount: () -> Int?

    /// The probe the collector uses: AVFoundation's classes looked up by name.
    static let runtime = objcRuntime()

    /// The core does not link AVFoundation, so its classes are there only
    /// once something loaded it; load it on first use.
    static let avFoundationPath = "/System/Library/Frameworks/AVFoundation.framework"

    #if canImport(ObjectiveC)
    private static func lookUp(_ name: String) -> AnyClass? {
        if let cls = NSClassFromString(name) { return cls }
        _ = Bundle(path: avFoundationPath)?.load()
        return NSClassFromString(name)
    }
    #endif

    /// Looked up by name, so a test can point it at a class that is missing.
    static func objcRuntime(
        deviceClass: String = "AVCaptureDevice",
        discoveryClass: String = "AVCaptureDeviceDiscoverySession"
    ) -> CaptureDeviceProbe {
        #if canImport(ObjectiveC)
        return CaptureDeviceProbe(
            authorizationStatus: { mediaType in
                // + (AVAuthorizationStatus)authorizationStatusForMediaType:(AVMediaType)mediaType
                let selector = NSSelectorFromString("authorizationStatusForMediaType:")
                guard let cls = lookUp(deviceClass),
                      let method = class_getClassMethod(cls, selector) else { return nil }
                typealias Call = @convention(c) (AnyClass, Selector, NSString) -> Int
                let call = unsafeBitCast(method_getImplementation(method), to: Call.self)
                return call(cls, selector, mediaType as NSString)
            },
            cameraCount: {
                // + (instancetype)discoverySessionWithDeviceTypes:mediaType:position:
                // (position 0 is AVCaptureDevicePositionUnspecified)
                let selector = NSSelectorFromString("discoverySessionWithDeviceTypes:mediaType:position:")
                guard let cls = lookUp(discoveryClass),
                      let method = class_getClassMethod(cls, selector) else { return nil }
                typealias Call = @convention(c) (AnyClass, Selector, NSArray, NSString, Int) -> Unmanaged<AnyObject>?
                let call = unsafeBitCast(method_getImplementation(method), to: Call.self)
                guard let session = call(cls, selector, cameraTypes as NSArray, video as NSString, 0)?
                    .takeUnretainedValue() as? NSObject,
                    let devices = session.value(forKey: "devices") as? [Any] else { return nil }
                return devices.count
            }
        )
        #else
        return CaptureDeviceProbe(authorizationStatus: { _ in nil }, cameraCount: { nil })
        #endif
    }
}
