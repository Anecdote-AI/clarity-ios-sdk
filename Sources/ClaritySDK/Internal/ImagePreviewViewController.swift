#if canImport(UIKit)
import UIKit
import WebKit

/// Full-screen viewer for image attachments tapped inside the chat. In the
/// browser widget the HOST page renders the lightbox outside the iframe;
/// inside the SDK there is no parent frame, so the page sends `openImage`
/// over the bridge and this controller plays that role — the iOS port of
/// Android's ClarityImagePreviewActivity.
///
/// Renders through its own throwaway WKWebView rather than a native image
/// pipeline: attachment URLs are session-authenticated and the preview
/// shares the widget's process pool + default website data store
/// (WebViewFactory.baseConfiguration), so the image loads with the chat's
/// cookies for free — plus WebKit gives pinch-to-zoom natively. The page is
/// loaded with the attachment's origin as base URL so the image request is
/// first-party (ITP would drop cookies for a null-origin document).
///
/// Loading UX: black backdrop, native spinner while the image downloads (a
/// tiny in-page script reports img load/error over the `clarityPreview`
/// handler), failures surface a retry state instead of an eternal black
/// screen.
final class ImagePreviewViewController: UIViewController {

    static let bridgeName = "clarityPreview"

    private enum PreviewState { case loading, loaded, failed }

    private let imageUrl: String
    private var webView: WKWebView?
    private let language: String?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failedStack = UIStackView()

    init(imageUrl: String, language: String?) {
        self.imageUrl = imageUrl
        self.language = language
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        makeImageWebView()
        makeSpinner()
        makeFailedStack()
        let closeButton = CloseButton.make(
            target: self,
            action: #selector(closeTapped),
            accessibilityLabel: NativeStrings.text(.close, language: language)
        )
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failedStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            failedStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ] + CloseButton.layoutConstraints(for: closeButton, in: view))

        apply(state: .loading)
        load()
    }

    /// The throwaway WebView on the widget's shared configuration (process
    /// pool + default data store → the chat session's cookies for free).
    private func makeImageWebView() {
        let configuration = WebViewFactory.baseConfiguration()
        configuration.userContentController.add(
            WeakScriptMessageProxy(target: self), name: Self.bridgeName
        )
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        self.webView = webView
    }

    private func makeSpinner() {
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
    }

    private func makeFailedStack() {
        let failedLabel = UILabel()
        failedLabel.text = NativeStrings.text(.imageLoadFailed, language: language)
        failedLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        failedLabel.font = .systemFont(ofSize: Self.textFontSize)
        let retryButton = UIButton(type: .system)
        retryButton.setTitle(NativeStrings.text(.imageRetry, language: language), for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: Self.textFontSize, weight: .semibold)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        failedStack.axis = .vertical
        failedStack.alignment = .center
        failedStack.spacing = Self.failedStackSpacing
        failedStack.addArrangedSubview(failedLabel)
        failedStack.addArrangedSubview(retryButton)
        failedStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failedStack)
    }

    private func load() {
        apply(state: .loading)
        // Base URL = the attachment's origin, so the img request is
        // first-party and carries the chat session's cookies (a null-origin
        // document would make WebKit omit exactly the cookies this preview
        // exists to send).
        let baseURL = URL(string: imageUrl)?.originURL
        webView?.loadHTMLString(Self.previewHtml(imageUrl), baseURL: baseURL)
    }

    private func apply(state: PreviewState) {
        state == .loading ? spinner.startAnimating() : spinner.stopAnimating()
        failedStack.isHidden = state != .failed
    }

    @objc private func retryTapped() { load() }

    @objc private func closeTapped() { dismiss(animated: true) }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        // Throwaway by design — tear the WebView down with the controller,
        // and release the holder slot deterministically instead of relying
        // on dealloc timing (autorelease pools would otherwise keep the
        // weak reference alive for an unpredictable beat).
        webView?.stopLoading()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.bridgeName)
        webView?.removeFromSuperview()
        webView = nil
        if WidgetHolder.presentedPreview === self {
            WidgetHolder.presentedPreview = nil
        }
    }

    private static let textFontSize: CGFloat = 15
    private static let failedStackSpacing: CGFloat = 4
    /// Embedded in emitted HTML — kept as Strings because numeric
    /// interpolation would render "5.0" and change the page bytes.
    private static let maxZoomScale = "5"
    private static let imageFadeDuration = "0.18s"

    private static func previewHtml(_ url: String) -> String {
        let safeUrl = url
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=\(Self.maxZoomScale), user-scalable=yes">
        <style>
          html, body { margin: 0; height: 100%; background: #000; }
          body { display: flex; align-items: center; justify-content: center; }
          img { max-width: 100%; max-height: 100%; object-fit: contain;
                opacity: 0; transition: opacity \(Self.imageFadeDuration) ease; }
          img.ready { opacity: 1; }
        </style>
        </head><body><img src="\(safeUrl)" alt="">
        <script>
        (function () {
          var img = document.querySelector('img');
          function post(m) {
            try { webkit.messageHandlers.\(bridgeName).postMessage(m); } catch (e) {}
          }
          function ok() { img.className = 'ready'; post('loaded'); }
          function bad() { post('failed'); }
          if (img.complete && img.naturalWidth > 0) { ok(); return; }
          img.addEventListener('load', ok);
          img.addEventListener('error', bad);
        })();
        </script>
        </body></html>
        """
    }
}

extension ImagePreviewViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.bridgeName, let body = message.body as? String else { return }
        MainThread.run { [weak self] in
            switch body {
            case "loaded": self?.apply(state: .loaded)
            case "failed": self?.apply(state: .failed)
            default: break
            }
        }
    }
}
#endif
