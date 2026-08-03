#if canImport(UIKit)
import UIKit

/// One home for the "which window?" scene scan the SDK needs in two flavors.
/// Main-thread confined by convention — see `MainThread`.
enum ActiveWindow {

    /// The key window of a foreground scene — where presentation starts.
    /// Nil rather than falling back: presenting from a non-key window is
    /// worse than not presenting (see `TopViewController`).
    static func keyWindow() -> UIWindow? {
        foregroundWindows().last(where: \.isKeyWindow)
    }

    /// Any window of a foreground scene — window attachment is all WebKit
    /// needs to keep rAF running (see `WarmupHost`), key or not.
    static func anyWindow() -> UIWindow? {
        keyWindow() ?? foregroundWindows().first
    }

    private static func foregroundWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }
            .flatMap(\.windows)
    }
}
#endif
