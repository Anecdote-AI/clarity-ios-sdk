#if canImport(UIKit)
import UIKit

/// The ready-made in-app tools at run time: turns the config's
/// `inAppToolTemplates` into registered tools (`apply`), keeps what the app
/// set at run time (navigator, reloader), and runs each tool's handler on
/// the screen. Main thread only.
final class TemplateRuntime {

    static let shared = TemplateRuntime()

    private let registry: InAppToolRegistry
    /// The config's `inAppToolTemplates`: nil is every group (the web's defaults).
    private(set) var templates: ClarityToolTemplates?
    /// Whether the SDK has a config at all; without one nothing is offered.
    private var configured = false
    /// Each group's setting under the web's rules.
    private var chosen = TemplateCatalog.Chosen(ClarityToolTemplates.disabled)
    private var language: String?
    private(set) var navigator: ClarityNavigator?
    private(set) var reloader: (@MainActor (@escaping @Sendable (ClarityTaskOutcome) -> Void) -> Void)?
    private var offeredScreens: [ClarityScreen] = []
    private var fetcher: SiteFetcher?
    private var lastWarnings: [String] = []
    /// The chat's accent colour, as the page sent it with the last call.
    var accentColor: UIColor = OverlayHost.defaultAccent

    let pointer = PointerOverlay()
    let ring = FieldRing()

    static let navigatorTimeoutSeconds: TimeInterval = 10
    static let reloaderTimeoutSeconds: TimeInterval = 10
    static let locationTimeoutSeconds: TimeInterval = 15
    /// Kept free before get_location's own timeout, so the SDK answers before the page gives up.
    static let locationAnswerMargin: TimeInterval = 2
    static let locationNoDecision = "the customer did not decide on the location in time"
    static let locationMaxAgeSeconds: TimeInterval = 60
    static let coveredError = "the chat covers the whole screen, so nothing in the app can be shown now; tell the customer where it is"

    init(registry: InAppToolRegistry = .shared) {
        self.registry = registry
    }

    // MARK: - Configuration

    /// Registers the templates the config turns on, replacing those of the
    /// previous config. True when the offered set may have changed.
    func apply(_ config: ClarityConfig?) {
        configured = config != nil
        templates = config?.inAppToolTemplates
        language = config?.language
        rebuild()
    }

    // Only a group set `.with(options)` has any; the others offer nothing that needs them.
    private var siteSearchOptions: ClarityToolTemplates.SiteSearch? { TemplateCatalog.Chosen.options(chosen.siteSearch) }
    private var navigationOptions: ClarityToolTemplates.Navigation? { TemplateCatalog.Chosen.options(chosen.navigation) }
    private var locationOptions: ClarityToolTemplates.Location? { TemplateCatalog.Chosen.options(chosen.location) }

    func setNavigator(_ navigator: ClarityNavigator?) {
        let had = self.navigator != nil
        self.navigator = navigator
        if had != (navigator != nil) { rebuild() }
    }

    func setReloader(_ reloader: (@MainActor (@escaping @Sendable (ClarityTaskOutcome) -> Void) -> Void)?) {
        let had = self.reloader != nil
        self.reloader = reloader
        if had != (reloader != nil) { rebuild() }
    }

    /// Called by `rebuild` so a loaded page hears the new list.
    var onChange: (() -> Void)?

    private func rebuild() {
        let environment = TemplateCatalog.Environment(
            hasNavigator: navigator != nil,
            hasReloader: reloader != nil,
            locationUsageDeclared: HostCapabilities.locationProvisioned,
            appURLSchemes: HostCapabilities.appURLSchemes(in: Bundle.main.infoDictionary)
        )
        let source = configured ? templates : ClarityToolTemplates.disabled
        chosen = TemplateCatalog.Chosen(source)
        let (specs, warnings) = TemplateCatalog.specs(for: source, environment: environment)
        if warnings != lastWarnings {
            warnings.forEach { ClarityLog.log("inAppToolTemplates: \($0)") }
            lastWarnings = warnings
        }
        offeredScreens = navigationOptions.map {
            ScreenPaths.validScreens($0.screens) { _ in }
        } ?? []
        if let site = siteSearchOptions, fetcher?.siteURL != site.siteURL {
            // The old session holds its fetcher as delegate until invalidated.
            fetcher?.invalidate()
            fetcher = SiteFetcher(siteURL: site.siteURL)
        }
        registry.replaceNativeTemplates(specs.map(tool))
        onChange?()
    }

    private func tool(_ spec: TemplateCatalog.Spec) -> ClarityTool {
        let reveal = spec.reveal.map {
            ClarityToolReveal(
                message: NativeStrings.text($0.message, language: language),
                style: .strip,
                delayBefore: 0.3,
                holdAfter: $0.holdAfter
            )
        }
        var tool = ClarityTool(
            name: spec.name,
            description: spec.description,
            kind: spec.kind,
            parameters: spec.parameters,
            timeoutSeconds: spec.timeoutSeconds,
            reveal: reveal,
            rememberResult: spec.rememberFor != nil,
            handler: handler(for: spec.name)
        )
        tool.rememberFor = spec.rememberFor
        return tool
    }

    // MARK: - Around every call

    /// Before a tool runs (`InAppToolRunner.willRun`): an action takes the
    /// pointer off the screen, and a tool outside the forms group lets go of
    /// the field the agent was asking about.
    func willRun(_ tool: ClarityTool) {
        if tool.kind != .read && tool.name != TemplateCatalog.Name.showOnPage {
            pointer.hide()
        }
        if registry.isTemplate(tool.name) && !TemplateCatalog.formsGroup.contains(tool.name) {
            ring.release()
        }
    }

    /// The conversation is gone: nothing of it stays on the screen.
    func reset() {
        pointer.hide()
        ring.release()
    }

    private var currentPath: String? {
        guard let read = navigator?.currentPath else { return nil }
        return MainActor.assumeIsolated { read() }
    }

    private func snapshot() -> ScreenSnapshot {
        ScreenReader.snapshot(path: currentPath)
    }

    private static func orNull(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    // MARK: - Handlers

    private func handler(for name: String) -> ClarityToolHandler {
        { [weak self] arguments, completion in
            guard let self else {
                completion(.failure("unavailable"))
                return
            }
            switch name {
            case TemplateCatalog.Name.readPage: self.readPage(completion)
            case TemplateCatalog.Name.showOnPage: self.showOnPage(arguments, completion)
            case TemplateCatalog.Name.getPageText: self.pageText(completion)
            case TemplateCatalog.Name.findOnSite: self.findOnSite(arguments, completion)
            case TemplateCatalog.Name.readLink: self.readLink(arguments, completion)
            case TemplateCatalog.Name.openLink: self.openLink(arguments, completion)
            case TemplateCatalog.Name.getForm: completion(.success(PageResults.getForm(self.snapshot())))
            case TemplateCatalog.Name.focusFormField: self.focusField(arguments, completion)
            case TemplateCatalog.Name.fillFormFields: self.fillFields(arguments, completion)
            case TemplateCatalog.Name.getDiagnostics: self.diagnostics(completion)
            case TemplateCatalog.Name.reloadPage: self.reload(completion)
            case TemplateCatalog.Name.getLocation: self.location(completion)
            case TemplateCatalog.Name.clickElement: self.clickElement(arguments, completion)
            default: completion(.failure("unavailable"))
            }
        }
    }

    private func readPage(_ completion: ClarityToolCompletion) {
        let menu = navigationOptions != nil ? ScreenPaths.menuLinks(offeredScreens) : []
        completion(.success(PageResults.readPage(snapshot(), menuLinks: menu, siteURL: siteSearchOptions?.siteURL)))
    }

    private func pageText(_ completion: ClarityToolCompletion) {
        completion(.success(PageResults.pageText(snapshot())))
    }

    private func showOnPage(_ arguments: [String: Any], _ completion: @escaping ClarityToolCompletion) {
        if OverlayHost.chatCoversScreen {
            completion(.failure(Self.coveredError))
            return
        }
        let target = arguments["target"] as? String ?? ""
        let screen = snapshot()
        let candidates = screen.nodes.filter { PointMatch.pointableRoles.contains($0.role) && !$0.name.isEmpty }
        let named = candidates.map { (name: $0.name, role: $0.role) }
        guard let window = ScreenReader.hostWindow(),
              let index = PointMatch.best(named, target: target)
        else {
            // Names controls, fields, headings and pictures only: never a
            // text label, which may be the customer's data (no card here).
            completion(.failure(PointMatch.notFound(target: target, candidates: named)))
            return
        }
        let node = candidates[index]
        let note = PointMatch.note(arguments["note"])
        let moved = OverlayHost.scrollIntoView(node, in: window)
        let draw = { [weak self] in
            guard let self else { return }
            self.pointer.show(rect: Self.currentRect(of: node, in: window, moved: moved), note: note, accent: self.accentColor, in: window)
            completion(.success(["shown": true, "element": PointMatch.elementName(node.name, role: node.role, target: target)]))
        }
        if moved == 0 || OverlayHost.reduceMotion {
            draw()
        } else {
            // After the scroll animation, where the element is now.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: draw)
        }
    }

    /// Where the node is now: a view is measured again; an accessibility
    /// element is moved by the scroll.
    private static func currentRect(of node: ScreenNode, in window: UIWindow, moved: CGFloat) -> CGRect {
        if let view = node.handle as? UIView, view.window === window,
           !(view is UITextView && node.role == .link), !(view is UISegmentedControl), !(node.role == .tab) {
            return view.convert(view.bounds, to: window)
        }
        if let element = node.handle as? NSObject, !(element is UIView), element.accessibilityFrame != .zero {
            return window.convert(element.accessibilityFrame, from: nil)
        }
        return node.rect.offsetBy(dx: 0, dy: -moved)
    }

    /// How long after the press a new screen on top counts as opened by it.
    static let screenSettleSeconds: TimeInterval = 0.6

    private func clickElement(_ arguments: [String: Any], _ completion: @escaping ClarityToolCompletion) {
        let screen = snapshot()
        let node: ScreenNode
        switch ClickCheck.target(arguments["target"] as? String ?? "", on: screen) {
        case .failure(let refusal):
            completion(.failure(refusal.message))
            return
        case .success(let found):
            node = found
        }
        let label = ClickCheck.label(node)
        guard let window = ScreenReader.hostWindow() else {
            completion(.failure(ClickCheck.notPressed(label)))
            return
        }
        if !ClickPress.isEnabled(node) {
            completion(.failure(ClickCheck.disabled(label)))
            return
        }
        if node.handle is UITextView, node.role == .link, let refusal = ClickCheck.linkRefusal(
            node.url ?? "", label: label, siteURL: siteSearchOptions?.siteURL,
            appSchemes: HostCapabilities.appURLSchemes(in: Bundle.main.infoDictionary)
        ) {
            completion(.failure(refusal))
            return
        }
        let before = (title: screen.title, path: screen.path)
        let moved = OverlayHost.scrollIntoView(node, in: window)
        let press = {
            let rect = Self.currentRect(of: node, in: window, moved: moved)
            if !ClickPress.isVisible(node, rect: rect, in: window) {
                completion(.failure(ClickCheck.notVisible(label)))
            } else if !ClickPress.isEnabled(node) {
                completion(.failure(ClickCheck.disabled(label)))
            } else if !ClickPress.press(node, at: rect, in: window) {
                completion(.failure(ClickCheck.notPressed(label)))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.screenSettleSeconds) { [weak self] in
                    let after = (title: ScreenReader.hostWindow().flatMap(ScreenReader.title(in:)), path: self?.currentPath)
                    completion(.success(ClickCheck.pressed(label: label, before: before, after: after)))
                }
            }
        }
        if moved == 0 || OverlayHost.reduceMotion { press() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: press) }
    }

    private func findOnSite(_ arguments: [String: Any], _ completion: @escaping ClarityToolCompletion) {
        guard let site = siteSearchOptions, let fetcher else {
            completion(.failure("unavailable"))
            return
        }
        SiteSearchTools(siteURL: site.siteURL, searchURL: site.searchURL, fetcher: fetcher)
            .find(query: arguments["query"] as? String) { result in
                switch result {
                case .success(let value): completion(.success(value))
                case .failure(let error): completion(.failure(error.message))
                }
            }
    }

    private func readLink(_ arguments: [String: Any], _ completion: @escaping ClarityToolCompletion) {
        guard let site = siteSearchOptions, let fetcher else {
            completion(.failure("unavailable"))
            return
        }
        SiteSearchTools(siteURL: site.siteURL, searchURL: site.searchURL, fetcher: fetcher)
            .read(path: arguments["path"] as? String ?? "") { result in
                switch result {
                case .success(let value): completion(.success(value))
                case .failure(let error): completion(.failure(error.message))
                }
            }
    }

    private func openLink(_ arguments: [String: Any], _ completion: @escaping ClarityToolCompletion) {
        let requested = (arguments["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let request = ScreenPaths.match(requested, screens: offeredScreens) else {
            completion(.failure(ScreenPaths.notOpenableMessage(offeredScreens)))
            return
        }
        if let now = currentPath, ScreenPaths.withoutQuery(now) == request.path {
            completion(.success(["opened": request.path, "already_there": true]))
            return
        }
        if let navigator {
            let answer = OnceOutcome { [weak self] outcome in
                DispatchQueue.main.async {
                    switch outcome {
                    case .done:
                        completion(.success([
                            "opened": request.path,
                            "now_at": Self.orNull(self?.currentPath),
                            "chat_stays_open": true,
                        ]))
                    case .failed(let message):
                        completion(.failure(message))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigatorTimeoutSeconds) {
                answer.resolve(.failed("the app did not confirm it opened the screen"))
            }
            MainActor.assumeIsolated { navigator.open(request) { answer.resolve($0) } }
            return
        }
        let schemes = HostCapabilities.appURLSchemes(in: Bundle.main.infoDictionary)
        guard let link = request.screen.deepLink, ScreenPaths.isAppLink(link, schemes: schemes),
              let url = URL(string: ScreenPaths.fillDeepLink(link, params: request.params))
        else {
            completion(.failure("this app has no handler for opening its screens"))
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            completion(opened
                ? .success(["opened": request.path, "now_at": NSNull(), "chat_stays_open": true])
                : .failure("the app did not open the screen"))
        }
    }

    private func focusField(_ arguments: [String: Any], _ completion: @escaping ClarityToolCompletion) {
        let wanted = arguments["field"] as? String ?? ""
        if wanted == FieldTypes.none {
            ring.release()
            completion(.success(["ended": true]))
            return
        }
        if OverlayHost.chatCoversScreen {
            completion(.failure(Self.coveredError))
            return
        }
        let fields = PageResults.formFields(snapshot())
        guard let match = fields.first(where: { $0.type == wanted }), let view = match.node.handle as? UIView,
              let window = ScreenReader.hostWindow()
        else {
            completion(.failure("there is no \(wanted) field on this screen"))
            return
        }
        // Never focused: the keyboard would cover the screen and take the
        // customer's cursor out of the chat. Shown, and ringed until the
        // agent moves on.
        let moved = OverlayHost.scrollIntoView(match.node, in: window)
        let hold = { [weak self] in
            guard let self else { return }
            self.ring.hold(view, accent: self.accentColor, in: window)
            var result = PageResults.describe(match)
            result["customer_types_it"] = match.customerOnly
            completion(.success(result))
        }
        if moved == 0 || OverlayHost.reduceMotion { hold() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: hold) }
    }

    private func fillFields(_ arguments: [String: Any], _ completion: @escaping ClarityToolCompletion) {
        let requested: [PageResults.FieldValue]
        do {
            requested = try PageResults.requestedFields(arguments)
        } catch {
            completion(.failure((error as? PageResults.FillArgumentsError)?.message ?? "failed"))
            return
        }
        let fields = PageResults.formFields(snapshot())
        let window = ScreenReader.hostWindow()
        var filled: [String] = []
        var notOnScreen: [String] = []
        for (field, value) in requested.map({ ($0.field, $0.value) }) {
            guard let match = fields.first(where: { $0.type == field }), !match.customerOnly,
                  let view = match.node.handle as? UIView, FieldWriter.write(value, to: view)
            else {
                notOnScreen.append(field)
                continue
            }
            if ring.heldField === view { ring.release() }
            if let window { ring.flash(view, accent: accentColor, in: window) }
            filled.append(field)
        }
        let stillEmpty = PageResults.formFields(snapshot())
            .filter { !$0.customerOnly && $0.node.field?.filled != true }
            .map(PageResults.describe)
        completion(.success(["filled": filled, "not_on_page": notOnScreen, "still_empty": stillEmpty]))
    }

    private func diagnostics(_ completion: @escaping ClarityToolCompletion) {
        let provider = locationOptions?.provider
        let status = provider.map { provider in MainActor.assumeIsolated { provider.authorizationStatus() } }
        DiagnosticsCollector.collect(locationStatus: status) { completion(.success($0)) }
    }

    private func reload(_ completion: @escaping ClarityToolCompletion) {
        guard let reloader else {
            completion(.failure("unavailable"))
            return
        }
        let answer = OnceOutcome { [weak self] outcome in
            DispatchQueue.main.async {
                switch outcome {
                case .done:
                    completion(.success(["reloading": Self.orNull(self?.currentPath), "chat_stays_open": true]))
                case .failed(let message):
                    completion(.failure(message))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloaderTimeoutSeconds) {
            answer.resolve(.failed("the app did not confirm it reloaded the screen"))
        }
        MainActor.assumeIsolated { reloader { answer.resolve($0) } }
    }

    private func location(_ completion: @escaping ClarityToolCompletion) {
        guard let provider = locationOptions?.provider else {
            completion(.failure("unavailable"))
            return
        }
        // The provider's 15 s for a fix start only after the system prompt, so a
        // customer who takes long to decide could run past the tool's own 60 s
        // (counted from Allow): whatever the prompt took, the answer comes
        // before then.
        let answer = OnceResult(completion)
        let budget = TimeInterval(TemplateCatalog.locationTimeoutSeconds) - Self.locationAnswerMargin
        DispatchQueue.main.asyncAfter(deadline: .now() + budget) {
            answer.resolve(.failure(Self.locationNoDecision))
        }
        MainActor.assumeIsolated {
            provider.requestLocation(timeout: Self.locationTimeoutSeconds, maximumAge: Self.locationMaxAgeSeconds) { result in
                switch result {
                case .success(let fix): answer.resolve(.success(DiagnosticsCore.locationResult(fix)))
                case .failure(let failure): answer.resolve(.failure(DiagnosticsCore.locationError(failure)))
                }
            }
        }
    }
}

/// Pressing what `click_element` found, as a tap does: a control's
/// `.touchUpInside` (a switch toggles, a segment is chosen), a link's URL, a
/// SwiftUI control through its `clarityLabel` action or its accessibility
/// element's `accessibilityActivate()`.
enum ClickPress {

    /// A disabled `UIControl`, or an element whose traits say not enabled.
    static func isEnabled(_ node: ScreenNode) -> Bool {
        if let control = node.handle as? UIControl { return control.isEnabled }
        if let object = node.handle as? NSObject, !(object is ClarityLabelMarkerView) {
            return !object.accessibilityTraits.contains(.notEnabled)
        }
        return true
    }

    /// On the window, not hidden, and not entirely scrolled or clipped away.
    static func isVisible(_ node: ScreenNode, rect: CGRect, in window: UIWindow) -> Bool {
        if let view = node.handle as? UIView {
            guard view.window === window, !isHidden(view) else { return false }
        }
        let shown = rect.intersection(window.bounds)
        return !shown.isNull && shown.width > 0 && shown.height > 0
    }

    private static func isHidden(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha < 0.01 { return true }
            current = node.superview
        }
        return false
    }

    static func press(_ node: ScreenNode, at rect: CGRect, in window: UIWindow) -> Bool {
        switch node.handle {
        case let marker as ClarityLabelMarkerView:
            if let action = marker.action {
                action()
                return true
            }
            // While VoiceOver (or another assistive technology) is on, SwiftUI vends the element.
            return element(at: rect, in: window)?.accessibilityActivate() ?? false
        case let toggle as UISwitch:
            toggle.setOn(!toggle.isOn, animated: true)
            toggle.sendActions(for: .valueChanged)
            return true
        case let segmented as UISegmentedControl:
            guard let index = (0..<segmented.numberOfSegments).first(where: { segmented.titleForSegment(at: $0) == node.name }) else {
                return false
            }
            segmented.selectedSegmentIndex = index
            segmented.sendActions(for: .valueChanged)
            return true
        case let textView as UITextView:
            guard node.role == .link, let link = node.url, let url = URL(string: link) else { return false }
            return openLink(url, in: textView)
        case let control as UIControl:
            control.sendActions(for: .touchUpInside)
            return true
        case let object as NSObject:
            return object.accessibilityActivate()
        default:
            return false
        }
    }

    /// A text view's link, the way a tap opens it: its delegate decides
    /// first (an app that routes its own links inside the app returns false
    /// and does it there); only when it agrees, or has no say, is the URL
    /// opened. A delegate that answers only through the iOS 17 API, which
    /// cannot be asked outside a real tap, is not bypassed: not pressed.
    private static func openLink(_ url: URL, in textView: UITextView) -> Bool {
        if let delegate = textView.delegate {
            if let agrees = LegacyLinkDelegate.answer(delegate, textView, url, range: linkRange(of: url, in: textView)) {
                // false: the app handled the link itself (or keeps it closed).
                guard agrees else { return true }
            } else if #available(iOS 17.0, *),
                      delegate.responds(to: #selector(UITextViewDelegate.textView(_:primaryActionFor:defaultAction:))) {
                return false
            }
        }
        UIApplication.shared.open(url)
        return true
    }

    private static func linkRange(of url: URL, in textView: UITextView) -> NSRange {
        let text = textView.attributedText ?? NSAttributedString()
        var found = NSRange(location: 0, length: 0)
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            let link = (value as? URL)?.absoluteString ?? value as? String
            if link == url.absoluteString {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// The SwiftUI accessibility element at `rect`, when the hosting view vends one.
    private static func element(at rect: CGRect, in window: UIWindow) -> NSObject? {
        var found: NSObject?
        func visit(_ element: Any, depth: Int) {
            guard found == nil, depth < 40 else { return }
            if let view = element as? UIView {
                if let elements = view.accessibilityElements, !elements.isEmpty {
                    elements.forEach { visit($0, depth: depth + 1) }
                } else {
                    view.subviews.forEach { visit($0, depth: depth + 1) }
                }
                return
            }
            guard let object = element as? NSObject else { return }
            if object.isAccessibilityElement {
                let frame = window.convert(object.accessibilityFrame, from: nil)
                if frame.insetBy(dx: -2, dy: -2).contains(rect) || rect.insetBy(dx: -2, dy: -2).contains(frame) { found = object }
                return
            }
            (object.accessibilityElements ?? []).forEach { visit($0, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return found
    }
}

/// The first answer of a tool, or of its own deadline, counts.
final class OnceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private let completion: ClarityToolCompletion

    init(_ completion: @escaping ClarityToolCompletion) {
        self.completion = completion
    }

    func resolve(_ result: ClarityToolResult) {
        lock.lock()
        let first = !answered
        answered = true
        lock.unlock()
        if first { completion(result) }
    }
}

/// The first answer of a navigator or reloader, or of its timeout, counts.
final class OnceOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private let body: (ClarityTaskOutcome) -> Void

    init(_ body: @escaping (ClarityTaskOutcome) -> Void) {
        self.body = body
    }

    func resolve(_ outcome: ClarityTaskOutcome) {
        lock.lock()
        let first = !answered
        answered = true
        lock.unlock()
        if first { body(outcome) }
    }
}

/// Puts a value into a text field the way typing does, so the app's own
/// state (a SwiftUI binding, a delegate, a target-action) hears it: through
/// `UITextInput` (select all, replace), falling back to `text =` with the
/// editing-changed event and the text-did-change notification. Never a
/// secure field, never focused, never submitted.
enum FieldWriter {

    static func write(_ value: String, to view: UIView) -> Bool {
        if let field = view as? UITextField {
            guard !field.isSecureTextEntry, field.isEnabled else { return false }
            if let range = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
                field.replace(range, withText: value)
            }
            // `replace` is the typing path: target-action (`.editingChanged`),
            // the delegate's notification and a SwiftUI binding all hear it.
            // Only when it did not take is the text set by hand.
            if field.text != value {
                field.text = value
                field.sendActions(for: .editingChanged)
                NotificationCenter.default.post(name: UITextField.textDidChangeNotification, object: field)
            }
            return true
        }
        if let textView = view as? UITextView, textView.isEditable {
            if let range = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) {
                textView.replace(range, withText: value)
            }
            if textView.text != value {
                textView.text = value
                textView.delegate?.textViewDidChange?(textView)
                NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
            }
            return true
        }
        return false
    }
}


/// The pre-iOS 17 link callback, the only one that can be asked outside a
/// real tap. Deprecated itself, so calling the deprecated API is no warning.
@available(iOS, deprecated: 17.0)
private enum LegacyLinkDelegateImpl {
    static func answer(_ delegate: UITextViewDelegate, _ textView: UITextView, _ url: URL, range: NSRange) -> Bool? {
        // The URL variant's Objective-C name (the attachment one shares the Swift name).
        guard delegate.responds(to: NSSelectorFromString("textView:shouldInteractWithURL:inRange:interaction:")) else {
            return nil
        }
        return delegate.textView?(textView, shouldInteractWith: url, in: range, interaction: .invokeDefaultAction)
    }
}

/// Calls `LegacyLinkDelegateImpl` through a protocol, which keeps its
/// deprecation from spreading to the caller.
private protocol LegacyLinkAsking {
    static func answer(_ delegate: UITextViewDelegate, _ textView: UITextView, _ url: URL, range: NSRange) -> Bool?
}

@available(iOS, deprecated: 17.0)
extension LegacyLinkDelegateImpl: LegacyLinkAsking {}

private let LegacyLinkDelegate: LegacyLinkAsking.Type = LegacyLinkDelegateImpl.self
#endif
