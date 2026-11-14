#if canImport(UIKit)
import UIKit
import WebKit

/// Reads the host's current screen into a `ScreenSnapshot` (spec 4.4).
///
/// Two sources, because UIKit's standard controls describe themselves to
/// accessibility only while an assistive technology is on (their labels and
/// traits come from bundles iOS loads for VoiceOver):
///
///  - the views themselves, through public UIKit properties: `UILabel.text`,
///    a button's title, `UITextField`'s content type and placeholder, a tab
///    bar's items… plus every accessibility label, trait or element list the
///    app set itself. This works on every screen built from UIKit views,
///    including SwiftUI's text fields, toggles and navigation bars, which are
///    UIKit views underneath;
///  - the accessibility elements a view vends, when it vends any — SwiftUI
///    does while an assistive technology is on, and then its text and buttons
///    are read too. Without one, SwiftUI's text and buttons cannot be read in
///    the app (they are drawn, not views), the snapshot is `partial`, and the
///    app can name what matters with `.clarityLabel(_:)`.
///
/// Never reads a field's text: only whether it has any (`hasText`).
/// Main thread only.
enum ScreenReader {

    static let maxNodes = 3000
    static let maxDepth = 80
    static let budgetSeconds: CFTimeInterval = 0.1
    static let webViewNote = "This screen is a web page inside the app, which the app cannot read."
    static let nothingNote = "The app has no screen on display now."

    /// The window the customer sees the app in: the one the chat is presented
    /// over, else the key window (never the voice bubble's own window).
    static func hostWindow() -> UIWindow? {
        if let window = WidgetHolder.presentedContainer?.view.window, !(window is VoiceBubbleWindow) {
            return window
        }
        if let key = ActiveWindow.keyWindow(), !(key is VoiceBubbleWindow) { return key }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { !($0 is VoiceBubbleWindow) && !$0.isHidden }
    }

    static func snapshot(path: String?) -> ScreenSnapshot {
        var snapshot = ScreenSnapshot()
        snapshot.path = path
        snapshot.lang = Locale.preferredLanguages.first
        guard let window = hostWindow() else {
            snapshot.unreadable = nothingNote
            return snapshot
        }
        snapshot.rightToLeft = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
        snapshot.title = title(in: window)
        var walker = Walker(window: window)
        walker.walk(window, depth: 0)
        walker.addAlerts()
        walker.dropPrivateSources()
        snapshot.truncated = walker.truncated
        snapshot.partial = walker.sawUnreadableSwiftUI
        if walker.webViewCoversScreen {
            snapshot.unreadable = webViewNote
        }
        let visible = walker.nodes.filter { node in
            !walker.privateRects.contains { $0.insetBy(dx: -1, dy: -1).contains(node.rect) }
        }
        let marked = ClickCheck.markNoClick(visible, regions: walker.noClickRects)
        snapshot.nodes = ScreenSnapshot.readingOrder(dedupe(marked), rightToLeft: snapshot.rightToLeft)
        return snapshot
    }

    /// The same element seen twice (as a view and as an accessibility
    /// element): same name, same place.
    private static func dedupe(_ nodes: [ScreenNode]) -> [ScreenNode] {
        var seen = Set<String>()
        return nodes.filter { node in
            let key = "\(node.role.rawValue)|\(node.name)|\(Int(node.rect.minX))|\(Int(node.rect.minY))|\(Int(node.rect.width))"
            return seen.insert(key).inserted
        }
    }

    // MARK: - The title

    /// `navigationItem.title ?? title` of the deepest visible host controller.
    static func title(in window: UIWindow) -> String? {
        guard var controller = window.rootViewController else { return nil }
        while true {
            if let presented = controller.presentedViewController,
               !isClarity(presented), !presented.isBeingDismissed, !(presented is UIAlertController) {
                controller = presented
            } else if let navigation = controller as? UINavigationController, let top = navigation.visibleViewController,
                      top !== controller, !isClarity(top) {
                controller = top
            } else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
                controller = selected
            } else if let child = controller.children.last(where: { $0.isViewLoaded && $0.view.window != nil && !isClarity($0) }) {
                controller = child
            } else {
                break
            }
        }
        var current: UIViewController? = controller
        while let node = current {
            let text = ScreenSnapshot.clean(node.navigationItem.title ?? node.title, limit: PageResults.maxHeading)
            if !text.isEmpty { return text }
            current = node.parent
        }
        return nil
    }

    static func isClarity(_ controller: UIViewController) -> Bool {
        controller === WidgetHolder.presentedContainer || controller === WidgetHolder.presentedPreview
    }

    // MARK: - The walk

    private struct Walker {
        let window: UIWindow
        let started = CACurrentMediaTime()
        let chatView: UIView?
        let previewView: UIView?
        /// Alerts the app presented: read as one dialog (`addAlerts`), not view by view.
        var alertViews: [UIView] = []
        var nodes: [ScreenNode] = []
        var privateRects: [CGRect] = []
        /// Regions the app keeps from `click_element`: read, never pressed.
        var noClickRects: [CGRect] = []
        var visited = 0
        var truncated = false
        var sawUnreadableSwiftUI = false
        var webViewCoversScreen = false
        /// Fields seen, so one vended again as an element is not listed twice.
        var seenFields = Set<ObjectIdentifier>()
        /// Where a field's name and error were read from, by node index: a
        /// label inside a private region found later (a SwiftUI marker's
        /// frame) must not name the field (`dropPrivateSources`).
        var fieldSources: [Int: (name: CGRect?, fallbackName: String, error: CGRect?)] = [:]

        init(window: UIWindow) {
            self.window = window
            chatView = WidgetHolder.presentedContainer?.view
            previewView = WidgetHolder.presentedPreview?.view
            var controller = window.rootViewController
            while let current = controller {
                if let alert = current as? UIAlertController { alertViews.append(alert.view) }
                guard let next = current.presentedViewController, !ScreenReader.isClarity(next) else { break }
                controller = next
            }
        }

        private mutating func overBudget() -> Bool {
            if truncated { return true }
            if nodes.count >= ScreenReader.maxNodes {
                truncated = true
            } else if visited % 100 == 0, CACurrentMediaTime() - started > ScreenReader.budgetSeconds {
                truncated = true
            }
            return truncated
        }

        private func rect(of view: UIView) -> CGRect {
            view.convert(view.bounds, to: window)
        }

        private func isHidden(_ view: UIView) -> Bool {
            view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden
        }

        mutating func walk(_ view: UIView, depth: Int) {
            visited += 1
            guard depth <= ScreenReader.maxDepth, !overBudget(), !isHidden(view) else { return }
            if view === chatView || view === previewView || view is ClarityOverlayView
                || alertViews.contains(where: { $0 === view }) { return }
            if view.clarityPrivate || view is ClarityPrivateMarkerView {
                privateRects.append(rect(of: view))
                return
            }
            if view is ClarityNoClickMarkerView {
                noClickRects.append(rect(of: view))
                return
            }
            if view.clarityNoClick { noClickRects.append(rect(of: view)) }
            if let marker = view as? ClarityLabelMarkerView {
                addLabelMarker(marker)
                return
            }
            if handled(view) { return }
            // The app's own accessibility, set on the view itself.
            if view.isAccessibilityElement, let label = view.accessibilityLabel, !label.isEmpty {
                add(role(for: view.accessibilityTraits, fallback: .text), name: label, rect: rect(of: view), handle: view)
                return
            }
            if isSwiftUIHost(view) {
                if let elements = view.accessibilityElements, !elements.isEmpty {
                    elements.forEach { walkElement($0, depth: depth + 1) }
                } else {
                    sawUnreadableSwiftUI = true
                }
            } else if let elements = view.accessibilityElements, !elements.isEmpty,
                      !(view is UITableView || view is UICollectionView) {
                // A container the app described itself.
                elements.forEach { walkElement($0, depth: depth + 1) }
                return
            }
            for child in view.subviews {
                walk(child, depth: depth + 1)
            }
        }

        private func isSwiftUIHost(_ view: UIView) -> Bool {
            NSStringFromClass(type(of: view)).contains("UIHostingView")
        }

        /// An accessibility element a container vends: a view is walked as
        /// one, any other element is a leaf or a container of its own.
        mutating func walkElement(_ element: Any, depth: Int) {
            visited += 1
            guard depth <= ScreenReader.maxDepth, !overBudget() else { return }
            if let view = element as? UIView {
                walk(view, depth: depth)
                return
            }
            guard let object = element as? NSObject, !object.accessibilityElementsHidden else { return }
            if object.isAccessibilityElement {
                guard let label = object.accessibilityLabel, !label.isEmpty else { return }
                let frame = window.convert(object.accessibilityFrame, from: nil)
                add(role(for: object.accessibilityTraits, fallback: .text), name: label, rect: frame, handle: object)
                return
            }
            (object.accessibilityElements ?? []).forEach { walkElement($0, depth: depth + 1) }
        }

        private func role(for traits: UIAccessibilityTraits, fallback: ScreenRole) -> ScreenRole {
            if traits.contains(.header) { return .heading }
            if traits.contains(.link) { return .link }
            if traits.contains(.adjustable) { return .toggle }
            if traits.contains(.button) {
                if #available(iOS 17.0, *), traits.contains(.toggleButton) { return .toggle }
                return .button
            }
            if traits.contains(.image) { return .image }
            if traits.contains(.staticText) { return .text }
            return fallback
        }

        private mutating func add(
            _ role: ScreenRole, name: String, rect: CGRect, handle: AnyObject?,
            url: String? = nil, field: ScreenField? = nil, messageKind: ScreenMessageKind? = nil
        ) {
            let limit = role == .heading ? PageResults.maxHeading : (role == .text || role == .message ? PageResults.maxPageText : 200)
            let clean = ScreenSnapshot.clean(name, limit: limit)
            guard !clean.isEmpty || field != nil else { return }
            nodes.append(ScreenNode(
                role: role, name: clean, url: url, rect: rect, field: field, messageKind: messageKind, handle: handle
            ))
        }

        private mutating func addLabelMarker(_ marker: ClarityLabelMarkerView) {
            let role: ScreenRole
            switch marker.role {
            case .button: role = .button
            case .link: role = .link
            case .heading: role = .heading
            case .text: role = .text
            case .tab: role = .tab
            case .toggle: role = .toggle
            case .image: role = .image
            case .status:
                add(.message, name: marker.name, rect: rect(of: marker), handle: marker, messageKind: .status)
                return
            }
            add(role, name: marker.name, rect: rect(of: marker), handle: marker, url: marker.url?.absoluteString)
        }

        // MARK: Views read by their own properties

        /// Reads a view UIKit describes through its properties; true when
        /// its subtree is done with.
        private mutating func handled(_ view: UIView) -> Bool {
            switch view {
            case let field as UITextField:
                addField(field, label: field.accessibilityLabel, placeholder: field.placeholder, secure: field.isSecureTextEntry,
                         contentType: field.textContentType?.rawValue, keyboard: field.keyboardType.rawValue,
                         enabled: field.isEnabled, editable: true, filled: field.hasText)
                return true
            case let search as UISearchBar:
                let field = search.searchTextField
                addField(field, label: search.accessibilityLabel, placeholder: search.placeholder ?? field.placeholder, secure: false,
                         contentType: nil, keyboard: field.keyboardType.rawValue,
                         enabled: field.isEnabled, editable: true, filled: field.hasText)
                return true
            case let textView as UITextView:
                if textView.isEditable {
                    addField(textView, label: textView.accessibilityLabel, placeholder: nil, secure: textView.isSecureTextEntry,
                             contentType: textView.textContentType?.rawValue, keyboard: textView.keyboardType.rawValue,
                             enabled: textView.isUserInteractionEnabled, editable: true, filled: textView.hasText)
                } else {
                    addReadOnlyText(textView)
                }
                return true
            case let label as UILabel:
                addLabel(label)
                return true
            case let toggle as UISwitch:
                let name = toggle.accessibilityLabel ?? nearbyLabel(toggle, before: true)?.text
                add(.toggle, name: name ?? "", rect: rect(of: toggle), handle: toggle)
                return true
            case let segmented as UISegmentedControl:
                addSegments(segmented)
                return true
            case let tabBar as UITabBar:
                addTabs(tabBar)
                return true
            case let button as UIButton:
                add(.button, name: buttonName(button) ?? "", rect: rect(of: button), handle: button)
                return true
            case is UISlider, is UIStepper, is UIDatePicker, is UIPickerView, is UIPageControl:
                if let label = view.accessibilityLabel {
                    add(.toggle, name: label, rect: rect(of: view), handle: view)
                }
                return true
            case let webView as WKWebView:
                let area = rect(of: webView).intersection(window.bounds)
                if area.width * area.height > window.bounds.width * window.bounds.height * 0.5 {
                    webViewCoversScreen = true
                }
                return true
            case let image as UIImageView:
                if let label = image.accessibilityLabel, !label.isEmpty {
                    add(.image, name: label, rect: rect(of: image), handle: image)
                }
                return true
            case let control as UIControl where !(control is UITextField):
                // A bar button, a custom control: named by its label or its text.
                let name = control.accessibilityLabel ?? firstText(in: control)
                if let name, !name.isEmpty {
                    add(.button, name: name, rect: rect(of: control), handle: control)
                    return true
                }
                return false
            default:
                return false
            }
        }

        private func buttonName(_ button: UIButton) -> String? {
            let candidates: [String?] = [
                button.accessibilityLabel,
                button.configuration?.title,
                button.currentTitle,
                button.currentAttributedTitle?.string,
                button.titleLabel?.text,
                button.imageView?.image?.accessibilityLabel,
            ]
            return candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        private func firstText(in view: UIView) -> String? {
            for child in view.subviews where !child.isHidden {
                if let label = child as? UILabel, let text = label.text, !text.isEmpty { return text }
                if let text = firstText(in: child) { return text }
            }
            return nil
        }

        private mutating func addLabel(_ label: UILabel) {
            guard let text = label.accessibilityLabel ?? label.attributedText?.string ?? label.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            // The navigation bar's title is the screen's title, not its content.
            if isInside(label, UINavigationBar.self) && label.font.pointSize < 30 { return }
            let marked = label.accessibilityTraits.contains(.header)
            // A large label is a heading only when it reads like a title: the
            // biggest label is often a balance or a total, not a title.
            let inferred = !marked && label.font.pointSize >= 22 && PageResults.readsLikeTitle(text)
                && !nodes.contains { $0.role == .heading }
            add(marked || inferred ? .heading : .text, name: text, rect: rect(of: label), handle: label)
            if inferred { nodes[nodes.count - 1].inferredHeading = true }
        }

        private func isInside<T: UIView>(_ view: UIView, _ type: T.Type) -> Bool {
            var current = view.superview
            while let node = current {
                if node is T { return true }
                current = node.superview
            }
            return false
        }

        private mutating func addReadOnlyText(_ textView: UITextView) {
            let text = textView.attributedText?.string ?? textView.text ?? ""
            add(.text, name: text, rect: rect(of: textView), handle: textView)
            guard let attributed = textView.attributedText, attributed.length > 0 else { return }
            attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                let url = (value as? URL)?.absoluteString ?? (value as? String)
                guard let url else { return }
                let name = (attributed.string as NSString).substring(with: range)
                var linkRect = rect(of: textView)
                if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                   let end = textView.position(from: start, offset: range.length),
                   let textRange = textView.textRange(from: start, to: end) {
                    linkRect = textView.convert(textView.firstRect(for: textRange), to: window)
                }
                add(.link, name: name, rect: linkRect, handle: textView, url: url)
            }
        }

        private mutating func addSegments(_ control: UISegmentedControl) {
            guard control.numberOfSegments > 0 else { return }
            let whole = rect(of: control)
            let width = whole.width / CGFloat(control.numberOfSegments)
            for index in 0..<control.numberOfSegments {
                let title = control.titleForSegment(at: index) ?? control.imageForSegment(at: index)?.accessibilityLabel ?? ""
                let segment = CGRect(x: whole.minX + width * CGFloat(index), y: whole.minY, width: width, height: whole.height)
                add(.tab, name: title, rect: segment, handle: control)
            }
        }

        private mutating func addTabs(_ tabBar: UITabBar) {
            let items = tabBar.items ?? []
            let buttons = tabBar.subviews
                .filter { $0 is UIControl && !$0.isHidden }
                .sorted { $0.frame.minX < $1.frame.minX }
            for (index, item) in items.enumerated() {
                let name = item.accessibilityLabel ?? item.title ?? ""
                let frame = index < buttons.count ? rect(of: buttons[index]) : rect(of: tabBar)
                add(.tab, name: name, rect: frame, handle: index < buttons.count ? buttons[index] : tabBar)
            }
        }

        // MARK: Fields

        private mutating func addField(
            _ view: UIView, label: String?, placeholder: String?, secure: Bool, contentType: String?, keyboard: Int,
            enabled: Bool, editable: Bool, filled: Bool
        ) {
            guard seenFields.insert(ObjectIdentifier(view)).inserted else { return }
            let type = FieldTypes.type(contentType: contentType, keyboardType: keyboard, isSecure: secure)
            let error = errorLabel(below: view)
            let field = ScreenField(
                type: type,
                inputKind: FieldTypes.inputKind(keyboardType: keyboard),
                customerOnly: secure || FieldTypes.isCustomerOnly(type),
                filled: filled,
                enabled: enabled,
                editable: editable,
                error: error?.text
            )
            // As the web names a field: its own label, the label next to it,
            // then its placeholder.
            func usable(_ text: String?) -> String? {
                text.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            }
            let nearby = usable(label) == nil ? nearbyLabel(view, before: false) : nil
            let fallback = usable(placeholder) ?? ""
            let name = usable(label) ?? usable(nearby?.text) ?? fallback
            let before = nodes.count
            add(.field, name: name, rect: rect(of: view), handle: view, field: field)
            if nodes.count > before, nearby != nil || error != nil {
                fieldSources[before] = (usable(nearby?.text) != nil ? nearby?.rect : nil, fallback, error?.rect)
            }
        }

        /// The nearest label above the view, or before it on its row, within
        /// 48 points, in the same superview or the one above.
        private func nearbyLabel(_ view: UIView, before: Bool) -> (text: String, rect: CGRect)? {
            let target = rect(of: view)
            var best: (distance: CGFloat, text: String, rect: CGRect)?
            var container = view.superview
            for _ in 0..<2 {
                guard let parent = container else { break }
                for label in labels(in: parent, excluding: view) {
                    let frame = rect(of: label)
                    let above = frame.maxY <= target.minY + 2 && target.minY - frame.maxY <= 48
                        && frame.maxX > target.minX - 8 && frame.minX < target.maxX
                    let sameRow = abs(frame.midY - target.midY) <= 24 && frame.maxX <= target.minX + 2
                        && target.minX - frame.maxX <= 200
                    guard above || sameRow, let text = label.text, !text.isEmpty else { continue }
                    let distance = above ? target.minY - frame.maxY : target.minX - frame.maxX
                    if best == nil || distance < best!.distance { best = (distance, text, frame) }
                }
                if best != nil { break }
                container = parent.superview
            }
            return best.map { ($0.text, $0.rect) }
        }

        private func labels(in view: UIView, excluding: UIView) -> [UILabel] {
            var out: [UILabel] = []
            func visit(_ node: UIView, depth: Int) {
                guard depth < 4, node !== excluding, !node.isHidden else { return }
                // A private view's labels never name a field or give its error.
                if node.clarityPrivate || node is ClarityPrivateMarkerView { return }
                if let label = node as? UILabel { out.append(label); return }
                if node is UITextField || node is UITextView || node is UIButton { return }
                node.subviews.forEach { visit($0, depth: depth + 1) }
            }
            view.subviews.forEach { visit($0, depth: 0) }
            return out
        }

        /// A red label right below a field is that field's error (UIKit).
        private func errorLabel(below field: UIView) -> (text: String, rect: CGRect)? {
            let target = rect(of: field)
            let containers = [field.superview, field.superview?.superview].compactMap { $0 }
            for container in containers {
                for label in labels(in: container, excluding: field) {
                    let frame = rect(of: label)
                    guard frame.minY >= target.maxY - 2, frame.minY - target.maxY <= 32,
                          frame.maxX > target.minX - 8, frame.minX < target.maxX,
                          let text = label.text, !text.isEmpty, isRed(label.textColor, in: label.traitCollection)
                    else { continue }
                    return (text, frame)
                }
            }
            return nil
        }

        /// A field named, or given its error, by a label that lies inside a
        /// private region (one only known once the whole screen is walked:
        /// a SwiftUI private marker's frame) loses that name or error.
        mutating func dropPrivateSources() {
            func isPrivate(_ rect: CGRect?) -> Bool {
                guard let rect else { return false }
                return privateRects.contains { $0.insetBy(dx: -1, dy: -1).contains(rect) }
            }
            for (index, source) in fieldSources where index < nodes.count {
                if isPrivate(source.name) { nodes[index].name = ScreenSnapshot.clean(source.fallbackName, limit: 200) }
                if isPrivate(source.error) { nodes[index].field?.error = nil }
            }
        }

        private func isRed(_ color: UIColor?, in traits: UITraitCollection) -> Bool {
            guard let resolved = color?.resolvedColor(with: traits) else { return false }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
            return red > 0.6 && green < 0.35 && blue < 0.35
        }

        // MARK: Alerts

        /// A `UIAlertController` the app presented: a dialog message and its buttons.
        mutating func addAlerts() {
            var controller = window.rootViewController
            while let current = controller {
                if let alert = current as? UIAlertController, alert.view.window != nil {
                    let text = [alert.title, alert.message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
                    let frame = rect(of: alert.view)
                    add(.dialog, name: text, rect: frame, handle: alert.view, messageKind: .dialog)
                    for action in alert.actions {
                        add(.button, name: action.title ?? "", rect: frame, handle: alert.view)
                    }
                }
                guard let next = current.presentedViewController, !ScreenReader.isClarity(next) else { break }
                controller = next
            }
        }
    }
}
#endif
