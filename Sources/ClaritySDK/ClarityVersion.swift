/// Single source of truth for the SDK version.
///
/// Sent to the widget page as the `sdkVersion` query parameter and checked by
/// the release workflow against the `ios-sdk-v<version>` tag (the iOS analog
/// of the Android SDK's `gradle.properties` `VERSION_NAME` guard).
public enum ClarityVersion {
    public static let current = "1.0.0"
}
