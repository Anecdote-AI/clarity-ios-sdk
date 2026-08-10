#if canImport(UIKit)
import UIKit

/// The widget failed to load and a `Clarity.show` was waiting on it. Without
/// this nothing is presented at all, so an integrator who has not set a
/// `ClarityListener` sees a dead Help button and no clue — the failure exists
/// only in the Xcode console.
///
/// **Shown to DEVELOPERS ONLY** — `DiagnosticGate` keeps it out of Release
/// builds (overridable via `ClarityConfig.showDiagnosticsOnFailure`). A
/// customer's shipped app behaves exactly as before: nothing is presented.
///
/// Deliberately plain, monospaced and untranslated. It is a developer tool and
/// looking like one is the point: it must never be mistaken for customer-facing
/// copy, and localizing it would imply end users are meant to read it.
///
/// No WebView is involved — the rule that the widget is never presented in a
/// half-loaded state still holds. Port of Android's
/// `ClarityDiagnosticActivity`.
final class ClarityDiagnosticViewController: UIViewController {

    private let kindText: String
    private let code: Int
    private let message: String

    init(kind: String, code: Int, message: String) {
        self.kindText = kind
        self.code = code
        self.message = message
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this controller is created in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 0.95)

        let stack = UIStackView(arrangedSubviews: [
            label("Clarity — Debug builds only", size: 12, alpha: 0.6, mono: true),
            label("The support widget did not load.", size: 17, alpha: 1.0, mono: false),
            label("\(kindText) (code \(code))\n\n\(message)", size: 13, alpha: 0.85, mono: true),
            label(
                "Your users see nothing in a Release build. Handle "
                    + "ClarityListener.onError to decide what they see instead.",
                size: 12,
                alpha: 0.6,
                mono: true
            ),
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(close)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            close.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20),
            close.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func label(_ text: String, size: CGFloat, alpha: CGFloat, mono: Bool) -> UILabel {
        let view = UILabel()
        view.text = text
        view.numberOfLines = 0
        view.textColor = UIColor(white: 1, alpha: alpha)
        view.font = mono
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        return view
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}
#endif
