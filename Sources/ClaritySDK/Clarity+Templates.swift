import Foundation

// The run-time half of the ready-made in-app tools (`ClarityToolTemplates`):
// what the app provides once its UI exists.
extension Clarity {

    /// Opens your app's screens for `open_link` (the `navigation` template),
    /// or stops with nil. Works before `initialize`.
    ///
    /// ```swift
    /// Clarity.setNavigator(ClarityNavigator(
    ///     open: { request, done in
    ///         router.open(request.path)
    ///         done(.done)
    ///     },
    ///     currentPath: { router.currentPath }
    /// ))
    /// ```
    public static func setNavigator(_ navigator: ClarityNavigator?) {
        #if canImport(UIKit)
        MainThread.run { TemplateRuntime.shared.setNavigator(navigator) }
        #endif
    }

    /// Turns on `reload_page` (with the `diagnostics` template): what
    /// refreshing the current screen means in your app — fetch its data
    /// again, say. Call the completion once, from any thread. nil turns it off.
    public static func setScreenReloader(
        _ reload: (@MainActor (@escaping @Sendable (ClarityTaskOutcome) -> Void) -> Void)?
    ) {
        #if canImport(UIKit)
        MainThread.run { TemplateRuntime.shared.setReloader(reload) }
        #endif
    }

    /// An error your app ran into, for `get_diagnostics` (the last 20 are
    /// kept in memory): a short message, never the customer's data.
    public static func recordAppError(_ message: String, screen: String? = nil) {
        AppErrorLog.shared.record(message, screen: screen)
    }

    /// For the Clarity wrapper SDKs (Flutter): registers a template the
    /// wrapper implements itself. It is offered after the app's own tools,
    /// in the templates' order, and an app tool of the same name replaces it.
    @_spi(ClarityWrapper)
    @discardableResult
    public static func registerTemplateTool(_ tool: ClarityTool) -> Bool {
        if let problem = InAppToolRegistry.problem(with: tool) {
            ClarityLog.log("registerTemplateTool: \"\(tool.name)\" was not registered: \(problem)")
            return false
        }
        InAppToolRegistry.shared.registerTemplate(tool)
        #if canImport(UIKit)
        MainThread.run { controller.announceInAppTools() }
        #endif
        return true
    }

    @_spi(ClarityWrapper)
    public static func unregisterTemplateTool(_ name: String) {
        guard InAppToolRegistry.shared.unregisterTemplate(name) else { return }
        #if canImport(UIKit)
        MainThread.run { controller.announceInAppTools() }
        #endif
    }
}
