#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// The sheet's page: a web view with the sheet's title and close button. Loading is shown
/// natively, never with a browser-style progress bar (CONTRACT §9.1). Every page in the sheet is
/// the bank's, so the web view always sits inset on the white backdrop (CONTRACT §9.1, §16.8).
@MainActor
final class PaymentPageViewController: UIViewController {
    /// The margins of a bank page on the white backdrop (CONTRACT §9.1). Bank pages are built for
    /// a desktop popup and would otherwise run to the screen edges.
    static let bankPageInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

    let webView: WKWebView
    let titleView: SheetTitleView
    private(set) lazy var closeButton: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.onClose?()
        })
        item.accessibilityLabel = closeTitle
        return item
    }()

    /// Called when the customer taps the close button.
    var onClose: (@MainActor () -> Void)?

    /// Covers the web view until its first page has loaded, so the customer never sees a blank
    /// or half-drawn web page.
    private let loadingVeil = UIView()
    private lazy var activityItem = UIBarButtonItem(customView: {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        return indicator
    }())
    private var hasFinishedFirstLoad = false
    private let closeTitle: String
    private var observations: [NSKeyValueObservation] = []
    private(set) var overlay: UIView?
    private var hasCommittedContent = false
    /// The white backdrop behind the web view: what shows while pages load and around the page.
    private let backdrop = UIView()

    init(webView: WKWebView, strings: PayriffStrings) {
        self.webView = webView
        self.closeTitle = strings[.close]
        self.titleView = SheetTitleView(title: strings[.title])
        super.init(nibName: nil, bundle: nil)
        navigationItem.titleView = titleView
        navigationItem.rightBarButtonItem = closeButton
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Bank pages are usually white: a white backdrop avoids a coloured flash between pages,
        // and the inset page sits on it.
        backdrop.backgroundColor = .white
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(webView)

        loadingVeil.backgroundColor = .systemBackground
        loadingVeil.translatesAutoresizingMaskIntoConstraints = false
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        loadingVeil.addSubview(spinner)
        view.addSubview(loadingVeil)

        let insets = Self.bankPageInsets
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: insets.top),
            webView.leftAnchor.constraint(equalTo: backdrop.leftAnchor, constant: insets.left),
            backdrop.bottomAnchor.constraint(equalTo: webView.bottomAnchor, constant: insets.bottom),
            backdrop.rightAnchor.constraint(equalTo: webView.rightAnchor, constant: insets.right),
            backdrop.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingVeil.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            loadingVeil.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingVeil.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingVeil.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: loadingVeil.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loadingVeil.centerYAnchor),
        ])

        observations = [
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateLoading() }
            },
        ]
        updateLoading()
    }

    /// Whether the loader still covers the web view.
    var isShowingLoadingVeil: Bool { !loadingVeil.isHidden }

    /// Whether the navigation bar shows the small activity indicator of a later page load.
    var isShowingActivityIndicator: Bool { navigationItem.leftBarButtonItem === activityItem }

    /// Called when a main-frame page committed: from now on the page draws its own background.
    func contentDidCommit() {
        WebViewLook.lockZoom(webView)
        guard !hasCommittedContent else { return }
        hasCommittedContent = true
        webView.isOpaque = true
    }

    /// Shows `overlay` above the web content, or removes the current overlay.
    func setOverlay(_ newOverlay: UIView?) {
        loadViewIfNeeded()
        overlay?.removeFromSuperview()
        overlay = newOverlay
        guard let newOverlay else {
            webView.accessibilityElementsHidden = false
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            return
        }
        newOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newOverlay)
        NSLayoutConstraint.activate([
            newOverlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            newOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            newOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView.accessibilityElementsHidden = true
        UIAccessibility.post(notification: .screenChanged, argument: (newOverlay as? OverlayView)?.primaryAccessibilityElement)
    }

    /// Enables or disables the close button.
    func setCloseEnabled(_ enabled: Bool) {
        closeButton.isEnabled = enabled
    }

    /// Stops loading and detaches the web view from its delegates and observers.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// The first load is covered by the veil; later loads show a small activity indicator in
    /// the navigation bar.
    private func updateLoading() {
        if webView.isLoading {
            if hasFinishedFirstLoad { navigationItem.setLeftBarButton(activityItem, animated: true) }
            return
        }
        navigationItem.setLeftBarButton(nil, animated: true)
        // Some pages report "not loading" before anything committed (e.g. a load was replaced).
        guard hasCommittedContent || webView.url != nil else { return }
        WebViewLook.lockZoom(webView)
        guard !hasFinishedFirstLoad else { return }
        hasFinishedFirstLoad = true
        UIView.animate(withDuration: 0.2) {
            self.loadingVeil.alpha = 0
        } completion: { _ in
            self.loadingVeil.isHidden = true
        }
    }
}
#endif
