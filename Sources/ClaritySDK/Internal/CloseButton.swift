#if canImport(UIKit)
import UIKit

/// The shared circular ✕ overlay used by the widget container and the image
/// preview — one construction site for its styling and geometry.
/// Main-thread confined by convention — see `MainThread`.
enum CloseButton {

    private static let diameter: CGFloat = 32
    private static let inset: CGFloat = 12
    private static let iconPointSize: CGFloat = 13
    /// Half the diameter — the button is a circle by construction, not by
    /// two constants that happen to agree.
    private static let cornerRadius: CGFloat = diameter / 2
    private static let backgroundAlpha: CGFloat = 0.4

    static func make(target: Any?, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        let image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: iconPointSize, weight: .semibold
            )
        )
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(backgroundAlpha)
        button.layer.cornerRadius = cornerRadius
        button.accessibilityLabel = "Close"
        button.addTarget(target, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Fixed size, pinned top-trailing inside `view`'s safe area.
    static func layoutConstraints(for button: UIButton, in view: UIView) -> [NSLayoutConstraint] {
        [
            button.widthAnchor.constraint(equalToConstant: diameter),
            button.heightAnchor.constraint(equalToConstant: diameter),
            button.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: inset
            ),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
        ]
    }
}
#endif
