#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// The UIKit side of a card payment's 3-D Secure step (CONTRACT §16.7, §16.8): the 3DS sheet and
/// the hidden web views of the 3DS method. Each payment has its own presenter.
@available(iOSApplicationExtension, unavailable)
@MainActor
final class CardFlowPresenter: CardFlowUI {
    private weak var form: PayriffCardForm?
    private weak var explicitPresenter: UIViewController?
    private let language: PayriffLanguage
    private let opener: any ExternalURLOpening
    private var sheet: PaymentSheet?
    /// The hidden web views of the 3DS method (internal for tests).
    let methodFrames = ThreeDSMethodFrames()
    /// The website data of this payment's web views (CONTRACT §9.1a): one non-persistent store,
    /// shared by the 3DS sheet and every hidden 3DS-method web view, so the method's cookies reach
    /// the challenge. It is made with the first web view; a payment without one has none. Nothing
    /// reaches the app's default store or the disk, and the data goes away with the payment.
    private(set) var websiteDataStore: WKWebsiteDataStore?

    init(form: PayriffCardForm, presenter: UIViewController?, language: PayriffLanguage, opener: any ExternalURLOpening) {
        self.form = form
        self.explicitPresenter = presenter
        self.language = language
        self.opener = opener
    }

    /// The view controller to present from: the one the integrator passed, else the top-most one
    /// of the form's window, else of the foreground scene.
    private func resolvePresenter() -> UIViewController? {
        if let explicitPresenter { return PresenterResolver.presenter(from: explicitPresenter) }
        if let window = form?.window { return PresenterResolver.presenter(in: window) }
        return PresenterResolver.presenter(from: nil)
    }

    func presentThreeDSSheet(for flow: any SheetFlowHandling) -> Bool {
        guard sheet == nil, let host = resolvePresenter() else { return false }
        let sheet = makeThreeDSSheet()
        sheet.flow = flow
        guard sheet.present(from: host) else { return false }
        self.sheet = sheet
        return true
    }

    /// A 3DS sheet whose web view keeps its website data in the payment's store.
    func makeThreeDSSheet() -> PaymentSheet {
        PaymentSheet(language: language, websiteDataStore: paymentWebsiteDataStore())
    }

    /// The payment's website data store, made on first use.
    private func paymentWebsiteDataStore() -> WKWebsiteDataStore {
        if let websiteDataStore { return websiteDataStore }
        let store = WKWebsiteDataStore.nonPersistent()
        websiteDataStore = store
        return store
    }

    func loadThreeDS(_ request: URLRequest) {
        sheet?.load(request: request)
    }

    func showThreeDSContent() {
        sheet?.showWebContent()
    }

    func showThreeDSVerifying() {
        sheet?.showVerifying()
    }

    func showThreeDSPageLoadError() {
        sheet?.showPageLoadError()
    }

    func stopThreeDSLoading() {
        sheet?.stopLoading()
    }

    func confirmThreeDSClose(_ decision: @escaping @MainActor (Bool) -> Void) {
        guard let sheet else {
            decision(false)
            return
        }
        sheet.confirmClose(decision)
    }

    func dismissThreeDS(_ completion: @escaping @MainActor () -> Void) {
        guard let sheet else {
            completion()
            return
        }
        self.sheet = nil
        sheet.dismiss(completion)
    }

    func openExternally(_ url: URL) {
        opener.open(url)
    }

    func startMethodFrames(_ requests: [URLRequest], apiHost: String) {
        let window = form?.window ?? resolvePresenter()?.viewIfLoaded?.window
        methodFrames.start(requests, apiHost: apiHost, websiteDataStore: paymentWebsiteDataStore(), in: window)
    }

    func stopMethodFrames() {
        methodFrames.stop()
    }
}

/// The hidden web views of the 3DS method (CONTRACT §16.7): attached to the window so WebKit runs
/// them normally, but invisible, without interaction and hidden from VoiceOver. They follow the
/// §16.8 navigation rules, never open other apps or windows, and never show JavaScript dialogs.
@MainActor
final class ThreeDSMethodFrames: NSObject, WKNavigationDelegate {
    /// The running hidden web views (internal for tests).
    private(set) var webViews: [WKWebView] = []
    private var navigators: [ObjectIdentifier: ThreeDSNavigator] = [:]

    /// The number of running hidden web views (tests).
    var count: Int { webViews.count }

    /// Loads each request in a hidden web view of its own. Their website data goes to
    /// `websiteDataStore`, the payment's store, which the 3DS sheet shares (CONTRACT §9.1a).
    func start(_ requests: [URLRequest], apiHost: String, websiteDataStore: WKWebsiteDataStore, in window: UIWindow?) {
        stop()
        for request in requests {
            let configuration = PaymentSheet.makeConfiguration(websiteDataStore: websiteDataStore)
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            webView.alpha = 0
            webView.isUserInteractionEnabled = false
            webView.isAccessibilityElement = false
            webView.accessibilityElementsHidden = true
            webView.navigationDelegate = self
            navigators[ObjectIdentifier(webView)] = ThreeDSNavigator(apiHost: apiHost)
            window?.addSubview(webView)
            webViews.append(webView)
            webView.load(request)
        }
    }

    func stop() {
        for webView in webViews {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        webViews.removeAll()
        navigators.removeAll()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let id = ObjectIdentifier(webView)
        guard var navigator = navigators[id], !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            return
        }
        let action = navigator.decide(navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
        navigators[id] = navigator
        decisionHandler(action == .allow || action == .allowCallback ? .allow : .cancel)
    }
}

@available(iOSApplicationExtension, unavailable)
@MainActor
extension Payriff {
    /// Pays an order with the card in `form` (CONTRACT §16.7), using the publishable key and the
    /// order's client secret. Your server created the order and gave the app both values.
    ///
    /// 1. The device is checked (CONTRACT §16.16). On a jailbroken device, or when a hooking tool
    ///    such as Frida or, in an App Store or TestFlight build, a debugger is found, the call
    ///    returns `.failed` with `DEVICE_COMPROMISED` and nothing is sent, unless
    ///    ``PayriffConfig/allowCompromisedDevices`` is on in a debug build.
    /// 2. The form is validated. Invalid fields show their errors and the call returns
    ///    `.failed` with `VALIDATION_FAILED` and ``PayriffError/fields``; nothing is sent.
    /// 3. The order is loaded; it must be payable by card (`ORDER_NOT_PAYABLE` otherwise).
    /// 4. The device is checked again, then the card is encrypted on the device and sent over a
    ///    pinned connection (CONTRACT §16.15). The form is locked and shows progress.
    /// 5. 3-D Secure runs in Payriff's sheet (or in the background for the 3DS method), then the
    ///    status is polled every 2.5 s for up to 120 s.
    ///
    /// The result drives your UI only; fulfil the order after your backend confirms it.
    /// ``PayriffResult/success(_:)`` means paid. A close of the 3DS sheet gives `pending(notFinal)`
    /// unless the status is final, because the card was already submitted. On `.failed`,
    /// ``PayriffError/isFatal`` means "create a new order"; otherwise the customer may try again.
    /// The form's values are cleared after every result except a non-fatal failure.
    ///
    /// - Parameters:
    ///   - form: The card form the customer filled in.
    ///   - orderId: The order your server created.
    ///   - clientSecret: The order's client secret (`pr_cs_…`) from your backend.
    ///   - presenter: The view controller to present the 3DS sheet from. `nil` uses the top-most
    ///     view controller of the form's window.
    /// - Returns: The payment result.
    public static func confirmCardPayment(
        _ form: PayriffCardForm,
        orderId: String,
        clientSecret: String,
        from presenter: UIViewController? = nil
    ) async -> PayriffResult {
        await withCheckedContinuation { continuation in
            startCardPayment(form, orderId: orderId, clientSecret: clientSecret, from: presenter) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Completion-handler variant of ``confirmCardPayment(_:orderId:clientSecret:from:)``.
    ///
    /// - Parameters:
    ///   - form: The card form the customer filled in.
    ///   - orderId: The order your backend created.
    ///   - clientSecret: The order's client secret (`pr_cs_…`).
    ///   - presenter: The view controller to present the 3DS sheet from, or `nil`.
    ///   - completion: Called exactly once on the main actor.
    public static func confirmCardPayment(
        _ form: PayriffCardForm,
        orderId: String,
        clientSecret: String,
        from presenter: UIViewController? = nil,
        completion: @escaping @MainActor (PayriffResult) -> Void
    ) {
        startCardPayment(form, orderId: orderId, clientSecret: clientSecret, from: presenter, completion: completion)
    }

    /// Validates everything, then runs a ``CardPaymentFlow``. Early failures are delivered
    /// asynchronously so the completion never runs inside this call.
    @discardableResult
    static func startCardPayment(
        _ form: PayriffCardForm,
        orderId: String,
        clientSecret: String,
        from presenter: UIViewController?,
        opener: (any ExternalURLOpening)? = nil,
        completion: @escaping @MainActor (PayriffResult) -> Void
    ) -> CardPaymentFlow? {
        func fail(_ error: PayriffError) -> CardPaymentFlow? {
            Log.error("The card payment could not start: \(error.code.rawValue): \(error.message)")
            Task { @MainActor in completion(.failed(error)) }
            return nil
        }

        guard activeCardFlow == nil, !form.isProcessing else { return fail(.paymentInProgress) }
        // CONTRACT §16.16: the device is checked before anything is sent, and again right before
        // the card is encrypted, with the configuration the payment started with.
        let allowsCompromisedDevices = configuration?.allowCompromisedDevices ?? false
        if let refusal = deviceIntegrityError(allowCompromisedDevices: allowsCompromisedDevices) {
            return fail(refusal)
        }
        let context: CardContext
        switch cardContext(orderId: orderId, clientSecret: clientSecret) {
        case .failure(let error): return fail(error)
        case .success(let value): context = value
        }
        let card: CardDetails
        switch form.collectForPayment() {
        case .failure(let failure): return fail(validationFailed(failure.issues))
        case .success(let value): card = value
        }
        let ui = CardFlowPresenter(
            form: form,
            presenter: presenter,
            language: form.effectiveLanguage,
            opener: opener ?? ApplicationURLOpener()
        )
        let flow = CardPaymentFlow(
            orderId: context.orderId,
            card: card,
            apiHost: context.apiHost,
            dependencies: CardPaymentFlow.Dependencies(
                client: context.client,
                clock: services.clock,
                checkDevice: { deviceIntegrityError(allowCompromisedDevices: allowsCompromisedDevices) }
            ),
            ui: ui
        )
        activeCardFlow = flow
        form.setProcessing(true)
        Task { @MainActor in
            let result = await flow.run()
            activeCardFlow = nil
            form.paymentDidFinish(result)
            completion(result)
        }
        return flow
    }
}
#endif
