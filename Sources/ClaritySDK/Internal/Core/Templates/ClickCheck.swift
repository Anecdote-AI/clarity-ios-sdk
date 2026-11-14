import Foundation

/// `click_element`'s rules, apart from the screen: which element a target
/// names (the same matching as `show_on_page`), which ones it refuses, and
/// the answers. The pressing itself is `TemplateRuntime`'s. Identical on
/// Android (`ClickTools`).
enum ClickCheck {

    /// What can be pressed; a field is refused with its own answer.
    static let pressableRoles: Set<ScreenRole> = [.button, .link, .tab, .toggle]

    static let askTheCustomer = "highlight it with show_on_page and ask the customer to press it"

    static func notVisible(_ label: String) -> String {
        "\"\(label)\" is not visible on the screen, so nothing was pressed; \(askTheCustomer)"
    }

    static func disabled(_ label: String) -> String {
        "\"\(label)\" is disabled, so nothing was pressed; \(askTheCustomer)"
    }

    static func textField(_ label: String) -> String {
        "\"\(label)\" is a text field, so nothing was pressed; use focus_form_field or fill_form_fields for it"
    }

    static func noClick(_ label: String) -> String {
        "the app does not let you press \"\(label)\", so nothing was pressed; \(askTheCustomer)"
    }

    static func notAControl(_ label: String) -> String {
        "\"\(label)\" is not a button, link or control, so nothing was pressed; \(askTheCustomer)"
    }

    static func notPressed(_ label: String) -> String {
        "\"\(label)\" could not be pressed; \(askTheCustomer)"
    }

    static func anotherSite(_ label: String) -> String {
        "\"\(label)\" leads to another site, so nothing was pressed; \(askTheCustomer)"
    }

    static func anotherApp(_ label: String) -> String {
        "\"\(label)\" opens another app, which happens only when the customer presses it, so nothing was pressed; \(askTheCustomer)"
    }

    /// Why a text link must not be opened for the customer, or nil when it
    /// may: only a page of the app's own website (https, the `siteSearch`
    /// origin) or one of the app's own URL schemes. A `tel:`, `sms:` or
    /// `mailto:` link, another app's scheme or another site — say in a
    /// review or a message the app shows — is the customer's to press, as
    /// on the web's click_element.
    static func linkRefusal(_ link: String, label: String, siteURL: URL?, appSchemes: Set<String>) -> String? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased()
        else { return notPressed(label) }
        if appSchemes.contains(scheme) { return nil }
        guard scheme == "http" || scheme == "https" else { return anotherApp(label) }
        if let siteURL, SiteAddress.sameOriginURL(link, base: siteURL) != nil { return nil }
        return anotherSite(label)
    }

    /// The name the answers use, cut as `show_on_page` cuts it.
    static func label(_ node: ScreenNode) -> String {
        String(node.name.prefix(PointMatch.maxElementName))
    }

    /// The element `target` names on `screen`, or the refusal: nothing of that
    /// name (a private element is never read, so never found), a text field,
    /// something that is not a control, or a control the app marked no-click.
    static func target(_ target: String, on screen: ScreenSnapshot) -> Result<ScreenNode, ClickRefusal> {
        let candidates = screen.nodes.filter { PointMatch.pointableRoles.contains($0.role) && !$0.name.isEmpty }
        let named = candidates.map { (name: $0.name, role: $0.role) }
        guard let index = PointMatch.best(named, target: target) else {
            return .failure(ClickRefusal(PointMatch.notFound(target: target, candidates: named)))
        }
        let node = candidates[index]
        if node.role == .field { return .failure(ClickRefusal(textField(label(node)))) }
        if !pressableRoles.contains(node.role) {
            // A text label's own words are not quoted back (`PointMatch.elementName`).
            return .failure(ClickRefusal(notAControl(PointMatch.elementName(node.name, role: node.role, target: target))))
        }
        if node.noClick { return .failure(ClickRefusal(noClick(label(node)))) }
        return .success(node)
    }

    /// `{pressed, label}`, and the new screen's title and path when the press opened another one.
    static func pressed(label: String, before: (title: String?, path: String?), after: (title: String?, path: String?)) -> [String: Any] {
        var result: [String: Any] = ["pressed": true, "label": label]
        if before.title != after.title || before.path != after.path {
            result["title"] = after.title.map { $0 as Any } ?? NSNull()
            result["path"] = after.path.map { $0 as Any } ?? NSNull()
        }
        return result
    }

    /// Marks each node inside a region the app made no-click.
    static func markNoClick(_ nodes: [ScreenNode], regions: [CGRect]) -> [ScreenNode] {
        guard !regions.isEmpty else { return nodes }
        return nodes.map { node in
            var node = node
            if regions.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(node.rect) }) { node.noClick = true }
            return node
        }
    }
}

/// Why `click_element` pressed nothing: the agent's answer.
struct ClickRefusal: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
