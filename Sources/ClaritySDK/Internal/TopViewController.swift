#if canImport(UIKit)
import UIKit

/// Finds the view controller to present the widget from — works for UIKit
/// and SwiftUI hosts alike (same lookup pattern as the surveys SDK, walked
/// down through presented controllers so presenting over sheets works).
/// Main-thread confined by convention — see `MainThread`.
enum TopViewController {

    static func find() -> UIViewController? {
        guard var top = ActiveWindow.keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
#endif
