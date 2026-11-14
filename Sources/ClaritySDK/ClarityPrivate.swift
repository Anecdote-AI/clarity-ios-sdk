#if canImport(UIKit)
import UIKit
#if canImport(SwiftUI)
import SwiftUI
#endif

/// What a SwiftUI element labelled with `clarityLabel` is, for the agent.
public enum ClarityElementRole: String, Sendable {
    case button, link, heading, text, tab, toggle, image
    /// A status line the screen shows now ("Saved at 12:27"): `read_page`
    /// lists it with the screen's messages.
    case status
}

private var clarityPrivateKey: UInt8 = 0
private var clarityNoClickKey: UInt8 = 0

extension UIView {
    /// Keeps this view and everything inside it out of what the ready-made
    /// in-app tools read (`read_page`, `get_page_text`, `show_on_page`, the
    /// form tools): a balance, a card number, anything the agent should not see.
    public var clarityPrivate: Bool {
        get { (objc_getAssociatedObject(self, &clarityPrivateKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &clarityPrivateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Keeps this view, and every control inside it, from being pressed by
    /// the ready-made `click_element`: the agent can still read it and point
    /// at it, and asks the customer to press it themselves — for "Delete my
    /// account", "Pay now".
    public var clarityNoClick: Bool {
        get { (objc_getAssociatedObject(self, &clarityNoClickKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &clarityNoClickKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// The SDK's marker views: a private region, and a SwiftUI element the app
/// named for the agent. Never drawn, never touched.
final class ClarityPrivateMarkerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}

/// The region of a SwiftUI view marked `clarityNoClick()`.
final class ClarityNoClickMarkerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}

final class ClarityLabelMarkerView: UIView {
    var name = ""
    var role: ClarityElementRole = .button
    var url: URL?
    /// What `click_element` runs to press the SwiftUI control it names.
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}

#if canImport(SwiftUI)
private struct ClarityPrivateMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> ClarityPrivateMarkerView { ClarityPrivateMarkerView() }
    func updateUIView(_ view: ClarityPrivateMarkerView, context: Context) {}
}

private struct ClarityNoClickMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> ClarityNoClickMarkerView { ClarityNoClickMarkerView() }
    func updateUIView(_ view: ClarityNoClickMarkerView, context: Context) {}
}

private struct ClarityLabelMarker: UIViewRepresentable {
    let name: String
    let role: ClarityElementRole
    let url: URL?
    let action: (() -> Void)?

    func makeUIView(context: Context) -> ClarityLabelMarkerView { ClarityLabelMarkerView() }

    func updateUIView(_ view: ClarityLabelMarkerView, context: Context) {
        view.name = name
        view.role = role
        view.url = url
        view.action = action
    }
}

extension View {
    /// Keeps this view out of what the ready-made in-app tools read: the
    /// region it covers is skipped.
    public func clarityPrivate() -> some View {
        background(ClarityPrivateMarker())
    }

    /// Names this view for the ready-made in-app tools. SwiftUI draws text
    /// and buttons in a way an app can read only while an assistive
    /// technology (VoiceOver, Voice Control) is on, so without it `read_page`
    /// does not see them and `show_on_page` cannot point at them. Label the
    /// controls the agent should know about — the main buttons, tabs, a
    /// screen's heading:
    ///
    /// ```swift
    /// Button("Save address") { … }
    ///     .clarityLabel("Save address")
    /// Text("Delivery address").font(.title)
    ///     .clarityLabel("Delivery address", role: .heading)
    /// ```
    ///
    /// Give a button its `action` as well, and `click_element` can press it
    /// for the customer: SwiftUI offers no way to tap a button from code
    /// while no assistive technology is on.
    ///
    /// ```swift
    /// Button("Save address", action: save)
    ///     .clarityLabel("Save address", action: save)
    /// ```
    public func clarityLabel(
        _ name: String, role: ClarityElementRole = .button, url: URL? = nil, action: (() -> Void)? = nil
    ) -> some View {
        background(ClarityLabelMarker(name: name, role: role, url: url, action: action))
    }

    /// Keeps the controls in this view from being pressed by the ready-made
    /// `click_element`: the agent can still read them and point at them, and
    /// asks the customer to press them themselves.
    public func clarityNoClick() -> some View {
        background(ClarityNoClickMarker())
    }
}
#endif
#endif
