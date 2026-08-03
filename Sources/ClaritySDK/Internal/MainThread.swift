import Foundation

/// Main-thread confinement helper with Android's `runOnMain` semantics:
/// execute inline when already on the main thread (the e2e suite relies on
/// public API calls from the main thread taking effect synchronously),
/// otherwise hop over asynchronously.
///
/// Everything under `Internal/` that touches UIKit or engine state follows
/// this convention — deliberately NOT `@MainActor`, so the engine's
/// synchronous cross-thread hops stay expressible in language mode 5.
enum MainThread {
    static func run(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// Synchronous main-thread read for the public getters: engine state is
    /// main-confined, so an off-main read must marshal through the main queue
    /// to get a defined value instead of a data race.
    static func sync<T>(_ block: () -> T) -> T {
        if Thread.isMainThread {
            return block()
        }
        return DispatchQueue.main.sync(execute: block)
    }
}
