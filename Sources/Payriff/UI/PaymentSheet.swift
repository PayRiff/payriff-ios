#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// The navigation controller presented as the 3-D Secure sheet.
@MainActor
final class PaymentNavigationController: UINavigationController {
    /// Called when the sheet disappears because the host app dismissed it.
    var onDismissedExternally: (@MainActor () -> Void)?
    /// Set before the SDK dismisses the sheet itself.
    var isDismissingFromSDK = false

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isDismissingFromSDK, isBeingDismissed || presentingViewController == nil {
            onDismissedExternally?()
        }
    }
}

/// The UIKit 3-D Secure sheet (CONTRACT §9.1, §16.8): a page sheet with a web view, overlays and
/// the close confirmation. It reports web events to its ``CardPaymentFlow`` and renders what the
/// flow decides.
@MainActor
final class PaymentSheet: NSObject {
    /// The flow the sheet shows: the 3-D Secure step of a card payment.
    weak var flow: (any SheetFlowHandling)?

    let strings: PayriffStrings
    let navigationController: PaymentNavigationController
    let rootPage: PaymentPageViewController

    private var observers: [any NSObjectProtocol] = []
    /// The scene the sheet was presented in (a `UIScene`; `AnyObject` so tests can stand in).
    weak var presentedScene: AnyObject?
    private var pendingCloseDecision: (@MainActor (Bool) -> Void)?
    private var dismissalCompletion: (@MainActor () -> Void)?
    private(set) var isTornDown = false
    /// The opaque view that hides the sheet while its scene is not active (CONTRACT §16.0 item 4).
    private(set) var privacyCover: PrivacyCoverView?

    /// - Parameters:
    ///   - language: The language of the sheet's texts.
    ///   - websiteDataStore: The payment's non-persistent website data store (CONTRACT §9.1a).
    init(language: PayriffLanguage, websiteDataStore: WKWebsiteDataStore) {
        let strings = PayriffStrings(language: language)
        self.strings = strings
        let webView = Self.makeWebView(configuration: Self.makeConfiguration(websiteDataStore: websiteDataStore))
        let rootPage = PaymentPageViewController(webView: webView, strings: strings)
        self.rootPage = rootPage
        self.navigationController = PaymentNavigationController(rootViewController: rootPage)
        super.init()
        rootPage.onClose = { [weak self] in self?.closeRequested() }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.isModalInPresentation = true
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        navigationController.presentationController?.delegate = self
        navigationController.onDismissedExternally = { [weak self] in
            self?.handleExternalDismissal()
        }
    }

    /// The configuration of the web view (CONTRACT §7.7, §16.8). No script, message handler or
    /// user agent is ever added. Website data goes to `websiteDataStore`, the payment's
    /// non-persistent store, never to the app's default store (CONTRACT §9.1a).
    static func makeConfiguration(websiteDataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    private static func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        WebViewLook.apply(to: webView)
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        return webView
    }

    /// Presents the sheet from `presenter`. Returns `false` when UIKit refused to present it.
    func present(from presenter: UIViewController) -> Bool {
        presenter.present(navigationController, animated: true)
        guard navigationController.presentingViewController != nil else {
            Log.error("UIKit did not present the 3-D Secure sheet from \(type(of: presenter)).")
            return false
        }
        presentedScene = presenter.viewIfLoaded?.window?.windowScene
        startObservingLifecycle()
        return true
    }

    private func startObservingLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] notification in
            let scene = notification.object as? UIScene
            MainActor.assumeIsolated { self?.sceneDidActivate(scene) }
        })
        // The app switcher, Control Center or another app take over: cover the sheet before
        // iOS takes its snapshot. Entering the background is a backup.
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIScene
                MainActor.assumeIsolated { self?.sceneWillDeactivate(scene) }
            })
        }
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] notification in
            let scene = notification.object as? UIScene
            MainActor.assumeIsolated { self?.sceneDidDisconnect(scene) }
        })
    }

    /// Whether a scene notification concerns the sheet's scene. A notification without a
    /// scene, or a sheet whose scene is not known, counts as its own.
    private func isOwnScene(_ scene: AnyObject?) -> Bool {
        let ownScene: AnyObject? = navigationController.viewIfLoaded?.window?.windowScene ?? presentedScene
        guard let ownScene, let scene else { return true }
        return scene === ownScene
    }

    func sceneDidActivate(_ scene: AnyObject?) {
        guard !isTornDown, isOwnScene(scene) else { return }
        hidePrivacyCover()
    }

    /// The sheet's scene resigns active (CONTRACT §16.0 item 4): an opaque cover hides the page,
    /// so app-switcher snapshots and screenshots of the inactive app show nothing the customer
    /// typed. It stays until the scene is active again.
    func sceneWillDeactivate(_ scene: AnyObject?) {
        guard !isTornDown, isOwnScene(scene) else { return }
        showPrivacyCover()
    }

    private func showPrivacyCover() {
        guard privacyCover == nil else { return }
        // Above the navigation bar, the page and its overlays.
        privacyCover = PrivacyCoverView.cover(navigationController.view)
    }

    private func hidePrivacyCover() {
        privacyCover?.removeFromSuperview()
        privacyCover = nil
    }

    /// The scene the sheet was presented in was disconnected (an iPad window was closed, or the
    /// system reclaimed a background scene). Its views go away without a dismissal or
    /// `viewDidDisappear`, so the flow is finished here; otherwise `confirmCardPayment` would
    /// never return and every later payment would fail with `PAYMENT_IN_PROGRESS`.
    func sceneDidDisconnect(_ scene: AnyObject?) {
        guard !isTornDown, let scene, scene === presentedScene else { return }
        Log.warning("The 3-D Secure sheet's scene was disconnected; resolving the result without UI.")
        navigationController.isDismissingFromSDK = true
        handleExternalDismissal()
    }

    /// The sheet went away without the SDK dismissing it. The flow still resolves and delivers
    /// its result, without UI.
    private func handleExternalDismissal() {
        guard !isTornDown else { return }
        tearDown()
        flow?.sheetWasDismissedExternally()
    }

    // MARK: - Overlays

    /// Shows `overlay` on the page. A pending close confirmation is withdrawn only when the flow
    /// has moved past the point where closing needs one (`endsConfirmation`).
    private func showOverlay(_ overlay: UIView?, closeEnabled: Bool = true, endsConfirmation: Bool) {
        if endsConfirmation { withdrawCloseConfirmation(dismissAlert: true) }
        rootPage.setOverlay(overlay)
        rootPage.setCloseEnabled(closeEnabled)
    }

    // MARK: - Dialogs

    private var topPresenter: UIViewController {
        var top: UIViewController = navigationController
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Presents `alert` on top of the sheet. Returns `false` when it cannot be shown (the sheet
    /// is not on screen, another alert is up, or UIKit refused the presentation).
    @discardableResult
    private func presentAlert(_ alert: UIAlertController) -> Bool {
        guard !isTornDown, navigationController.viewIfLoaded?.window != nil else { return false }
        let presenter = topPresenter
        guard !(presenter is UIAlertController) else { return false }
        presenter.present(alert, animated: true)
        return alert.presentingViewController != nil
    }

    /// Withdraws the close confirmation: its completion runs with "continue". With
    /// `dismissAlert`, a visible alert is dismissed too; the final dismissal skips that because
    /// it removes everything at once.
    private func withdrawCloseConfirmation(dismissAlert: Bool) {
        let decision = pendingCloseDecision
        pendingCloseDecision = nil
        if dismissAlert,
           let alert = navigationController.presentedViewController as? UIAlertController,
           !alert.isBeingDismissed {
            alert.dismiss(animated: true)
        }
        decision?(false)
    }

    private func tearDown() {
        guard !isTornDown else { return }
        withdrawCloseConfirmation(dismissAlert: false)
        isTornDown = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // Without its observers nothing would remove the cover; a sheet that UIKit keeps on
        // screen must stay closable.
        hidePrivacyCover()
        rootPage.tearDown()
    }

    /// The close button or a swipe-down attempt. A sheet whose flow already ended (which only
    /// happens if UIKit refused to dismiss it) simply goes away.
    private func closeRequested() {
        if isTornDown || flow?.isFinished != false {
            navigationController.presentingViewController?.dismiss(animated: true)
            return
        }
        flow?.requestClose()
    }

    // MARK: - Dismissal

    /// How often and how long to wait for a running UIKit transition before dismissing.
    private static let transitionPollInterval: UInt64 = 50_000_000
    private static let transitionPollAttempts = 40

    /// Dismisses the sheet once no presentation transition is running, then calls the stored
    /// completion exactly once. UIKit ignores a dismissal requested during another transition
    /// (for example while the sheet is still animating in), so this waits and verifies.
    private func attemptDismissal(remainingPolls: Int) {
        guard dismissalCompletion != nil else { return }
        guard let presenter = navigationController.presentingViewController else {
            completeDismissal()
            return
        }
        let presented = navigationController.presentedViewController
        let isTransitioning = navigationController.isBeingPresented || navigationController.isBeingDismissed
            || presented?.isBeingPresented == true || presented?.isBeingDismissed == true
        if isTransitioning, remainingPolls > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.transitionPollInterval)
                self?.attemptDismissal(remainingPolls: remainingPolls - 1)
            }
            return
        }
        presenter.dismiss(animated: remainingPolls > 0) { [weak self] in
            self?.completeDismissal()
        }
        // Verify that UIKit performed the dismissal; retry once without animation, then deliver.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.dismissalCompletion != nil else { return }
            if self.navigationController.presentingViewController != nil, remainingPolls > 0 {
                Log.warning("The 3-D Secure sheet did not dismiss; retrying without animation.")
                self.attemptDismissal(remainingPolls: 0)
            } else {
                if self.navigationController.presentingViewController != nil {
                    Log.error("UIKit kept the 3-D Secure sheet on screen; delivering the result anyway.")
                }
                self.completeDismissal()
            }
        }
    }

    private func completeDismissal() {
        guard let completion = dismissalCompletion else { return }
        dismissalCompletion = nil
        completion()
    }
}

// MARK: - What the card flow shows

extension PaymentSheet {
    /// Shows the "Checking payment…" overlay. The close button is disabled and dimmed while it
    /// is visible (CONTRACT §9.1).
    func showVerifying() {
        showOverlay(ProgressOverlayView(message: strings[.verifying]), closeEnabled: false, endsConfirmation: true)
    }

    /// Hides every overlay and shows the web content.
    func showWebContent() {
        showOverlay(nil, endsConfirmation: false)
    }

    /// Shows `page_load_error` with "Try again" and "Close" (CONTRACT §16.8).
    func showPageLoadError() {
        showOverlay(ErrorOverlayView(
            message: strings[.pageLoadError],
            strings: strings,
            onRetry: { [weak self] in self?.flow?.retry() },
            onClose: { [weak self] in self?.flow?.requestClose() }
        ), endsConfirmation: false)
    }

    /// Loads `request` in the web view: a GET, or the form POST of a 3-D Secure challenge
    /// (CONTRACT §16.7). The SDK never builds HTML for it.
    func load(request: URLRequest) {
        guard !isTornDown else { return }
        rootPage.loadViewIfNeeded()
        rootPage.webView.load(request)
    }

    /// Stops loading in the web view.
    func stopLoading() {
        rootPage.webView.stopLoading()
    }

    /// Asks the customer to confirm closing (`cancel_confirm_*`); calls `decision` exactly once.
    /// When nothing can show the dialog, the answer is "continue".
    func confirmClose(_ decision: @escaping @MainActor (Bool) -> Void) {
        resolveCloseConfirmation(false)
        let alert = UIAlertController(
            title: strings[.cancelConfirmTitle],
            message: strings[.cancelConfirmMessage],
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: strings[.cancelConfirmNo], style: .cancel) { [weak self] _ in
            self?.resolveCloseConfirmation(false)
        })
        alert.addAction(UIAlertAction(title: strings[.cancelConfirmYes], style: .destructive) { [weak self] _ in
            self?.resolveCloseConfirmation(true)
        })
        pendingCloseDecision = decision
        if !presentAlert(alert) {
            resolveCloseConfirmation(false)
        }
    }

    private func resolveCloseConfirmation(_ confirmed: Bool) {
        guard let decision = pendingCloseDecision else { return }
        pendingCloseDecision = nil
        decision(confirmed)
    }

    /// Dismisses the sheet and calls `completion` exactly once afterwards.
    func dismiss(_ completion: @escaping @MainActor () -> Void) {
        tearDown()
        navigationController.isDismissingFromSDK = true
        guard dismissalCompletion == nil else { return }
        dismissalCompletion = completion
        attemptDismissal(remainingPolls: Self.transitionPollAttempts)
    }
}

// MARK: - WKNavigationDelegate

extension PaymentSheet: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard !isTornDown, let flow, webView === rootPage.webView else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            Log.debug("Blocked a download: \(Log.redactedURL(navigationAction.request.url))")
            decisionHandler(.cancel)
            return
        }
        // A nil target frame would open a new window, which the sheet never does.
        let response = flow.decideNavigation(
            to: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            inPopup: navigationAction.targetFrame == nil
        )
        decisionHandler(response == .allow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        // Backup for redirects; decidePolicyFor normally sees them first.
        guard !isTornDown, let flow, webView === rootPage.webView else { return }
        if flow.decideNavigation(to: webView.url, isMainFrame: true, inPopup: false) == .cancel {
            webView.stopLoading()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isTornDown, let flow, webView === rootPage.webView else { return }
        rootPage.contentDidCommit()
        // Backup: a committed URL that should have been stopped is still handled.
        if flow.decideNavigation(to: webView.url, isMainFrame: true, inPopup: false) == .cancel {
            webView.stopLoading()
            return
        }
        flow.pageDidCommit(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isTornDown, webView === rootPage.webView else { return }
        flow?.pageDidFinish(webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        pageDidFail(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        pageDidFail(webView, error: error)
    }

    private func pageDidFail(_ webView: WKWebView, error: any Error) {
        guard !isTornDown, webView === rootPage.webView else { return }
        let userInfo = (error as NSError).userInfo
        let failingURL = userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? (userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        flow?.pageDidFail(error, failingURL: failingURL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isTornDown, webView === rootPage.webView else { return }
        flow?.webContentProcessDidTerminate()
    }
}

// MARK: - WKUIDelegate

extension PaymentSheet: WKUIDelegate {
    /// The sheet never opens a window (CONTRACT §16.8); the flow hands a bank-app URL to iOS.
    /// JavaScript `alert`, `confirm` and `prompt` are not implemented, so WebKit answers them at
    /// once with their default (OK, Cancel, no text) and the page never blocks.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard !isTornDown else { return nil }
        flow?.windowRequested(to: navigationAction.request.url)
        return nil
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension PaymentSheet: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        closeRequested()
    }
}
#endif
