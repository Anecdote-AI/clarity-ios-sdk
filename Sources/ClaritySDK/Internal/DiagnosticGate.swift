/// Decides whether a load failure gets a visible developer diagnostic.
///
/// Deliberately NOT inside a `#if canImport(UIKit)` guard, and deliberately
/// free of any UIKit type: this is the entire contract of a surface that must
/// never appear in a customer's release build, so it is unit-tested directly
/// (and on Linux) rather than inferred from a simulator run.
///
/// Port of the Android SDK's `DiagnosticGate.kt` — same three inputs, same
/// precedence, so the two platforms cannot drift on when a developer sees this.
enum DiagnosticGate {

    /// The default when the host has expressed no preference.
    ///
    /// `#if DEBUG` here reflects how THIS package was compiled. Xcode builds
    /// SPM and CocoaPods dependencies with the app's own configuration, so in
    /// practice a Debug app yields `true` — but it is a build-config
    /// inference, not a fact about the host, which is exactly why
    /// `ClarityConfig.showDiagnosticsOnFailure` exists to override it.
    static var defaultEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// - Parameters:
    ///   - override: `ClarityConfig.showDiagnosticsOnFailure`; nil means
    ///     "decide from the build" via ``defaultEnabled``.
    ///   - showWasPending: whether a `Clarity.show` was waiting on this load.
    ///     A background `preload()` failing must stay silent — nobody asked for
    ///     a window, and stealing the screen mid-session would be worse than
    ///     the bug being diagnosed.
    static func shouldPresent(
        override: Bool?,
        defaultEnabled: Bool = DiagnosticGate.defaultEnabled,
        showWasPending: Bool
    ) -> Bool {
        guard showWasPending else { return false }
        return override ?? defaultEnabled
    }
}
