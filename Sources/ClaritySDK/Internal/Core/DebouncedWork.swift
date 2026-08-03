import Dispatch
import Foundation

/// A single pending main-queue `DispatchWorkItem` slot: scheduling replaces
/// (and cancels) the previous item — the debounce/timeout idiom shared by
/// the auto-preload delay, the pageLoaded timeout and the reveal-gate cap.
final class DebouncedWork {

    private var workItem: DispatchWorkItem?

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        workItem?.cancel()
        let work = DispatchWorkItem(block: block)
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
