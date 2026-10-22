#if canImport(UIKit) && canImport(WebKit)
import Foundation
import os
import Testing
import UIKit
import WebKit
@testable import Payriff

/// The UIKit 3-D Secure sheet: presentation settings, chrome, overlays and accessibility
/// (CONTRACT §9.1, §16.8).
@MainActor
@Suite("3-D Secure sheet", .serialized)
struct PaymentSheetTests {
    @Test("Page sheet with a large detent, grabber, modal presentation and a delegate")
    func sheetConfiguration() throws {
        let sheet = PaymentSheet(language: .az, websiteDataStore: .nonPersistent())
        let navigation = sheet.navigationController
        #expect(navigation.modalPresentationStyle == .pageSheet)
        #expect(navigation.isModalInPresentation)
        let presentation = try #require(navigation.sheetPresentationController)
        #expect(presentation.detents.map(\.identifier) == [.large])
        #expect(presentation.prefersGrabberVisible)
        #expect(!presentation.prefersScrollingExpandsWhenScrolledToEdge)
        #expect(navigation.presentationController?.delegate === sheet)
    }

    @Test("Chrome: only the localized title (no address or padlock), close button with a VoiceOver label")
    func chrome() throws {
        let sheet = PaymentSheet(language: .az, websiteDataStore: .nonPersistent())
        let page = sheet.rootPage
        page.loadViewIfNeeded()
        #expect(page.navigationItem.titleView === page.titleView)
        #expect(page.titleView.title == "Ödəniş")
        #expect(page.titleView.accessibilityLabel == "Ödəniş")
        #expect(page.titleView.accessibilityTraits.contains(.header))
        #expect(page.navigationItem.rightBarButtonItem === page.closeButton)
        #expect(page.closeButton.accessibilityLabel == "Bağla")
        // A native loader covers the web view until the first page has loaded.
        #expect(page.isShowingLoadingVeil)
        #expect(!page.isShowingActivityIndicator)
    }

    @Test("The web view feels native: no zoom, bounce, scroll indicators, link previews or swipe navigation")
    func webViewLook() {
        let sheet = PaymentSheet(language: .en, websiteDataStore: .nonPersistent())
        let webView = sheet.rootPage.webView
        #expect(!webView.allowsLinkPreview)
        #expect(!webView.allowsBackForwardNavigationGestures)
        #expect(!webView.scrollView.bounces)
        #expect(!webView.scrollView.showsVerticalScrollIndicator)
        #expect(!webView.scrollView.showsHorizontalScrollIndicator)
        #expect(webView.scrollView.minimumZoomScale == webView.scrollView.maximumZoomScale)
        #expect(webView.scrollView.pinchGestureRecognizer?.isEnabled != true)
    }

    @Test("The web view runs no injected script, keeps the system user agent and keeps its website data in the payment's store")
    func webViewConfiguration() {
        let store = WKWebsiteDataStore.nonPersistent()
        let sheet = PaymentSheet(language: .en, websiteDataStore: store)
        let configuration = sheet.rootPage.webView.configuration
        // The payment's non-persistent store, never the app's default one (CONTRACT §9.1a).
        #expect(configuration.websiteDataStore === store)
        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(configuration.userContentController.userScripts.isEmpty)
        #expect(!configuration.limitsNavigationsToAppBoundDomains)
        #expect(sheet.rootPage.webView.customUserAgent == nil || sheet.rootPage.webView.customUserAgent == "")
        #expect(!sheet.rootPage.webView.allowsBackForwardNavigationGestures)
        #expect(sheet.rootPage.webView.navigationDelegate === sheet)
        #expect(sheet.rootPage.webView.uiDelegate === sheet)
    }

    @Test("Overlays: checking and the page-load error with the shared strings")
    func overlays() throws {
        let sheet = PaymentSheet(language: .ru, websiteDataStore: .nonPersistent())
        let page = sheet.rootPage
        page.loadViewIfNeeded()

        sheet.showVerifying()
        #expect((page.overlay as? ProgressOverlayView)?.message == "Проверяем платёж…")
        #expect(!page.closeButton.isEnabled, "close is ignored while verifying")

        sheet.showPageLoadError()
        let pageError = try #require(page.overlay as? ErrorOverlayView)
        #expect(Self.labels(in: pageError) == ["Не удалось загрузить страницу. Проверьте подключение к интернету."])
        #expect(Self.buttons(in: pageError) == ["Повторить", "Закрыть"])
        #expect(page.closeButton.isEnabled)

        sheet.showWebContent()
        #expect(page.overlay == nil)
        #expect(!page.webView.accessibilityElementsHidden)
    }

    @Test("While the close check runs, the close button is disabled and dimmed and a swipe-down is ignored (CONTRACT §9.1)")
    func closeDisabledWhileVerifying() async throws {
        let harness = SheetHarness(status: "APPROVED")
        harness.start()
        try await waitUntil(timeout: 20, "3DS sheet") { harness.ui.sheet.flow != nil }
        let sheet = harness.ui.sheet
        let close = sheet.rootPage.closeButton
        #expect(close.isEnabled)

        harness.flow.requestClose()
        #expect(sheet.rootPage.overlay is ProgressOverlayView)
        #expect(!close.isEnabled, "disabled (and therefore dimmed by UIKit) while checking")
        // A swipe-down attempt runs the close path, which ignores the close while checking.
        let presentation = try #require(sheet.navigationController.presentationController)
        sheet.presentationControllerDidAttemptToDismiss(presentation)
        #expect(harness.result == nil)

        harness.statusGate.open()
        try await waitUntil(timeout: 20, "result") { harness.result != nil }
        #expect(harness.result?.isSuccess == true)
        #expect(sheet.isTornDown)
    }

    @Test("WKWebView's content-process termination reaches the flow: the page-load error, Try again shows the page again")
    func contentProcessTerminationHook() async throws {
        let harness = SheetHarness(status: "PENDING")
        harness.start()
        try await waitUntil(timeout: 20, "3DS sheet") { harness.ui.sheet.flow != nil }
        let sheet = harness.ui.sheet
        sheet.webViewWebContentProcessDidTerminate(sheet.rootPage.webView)
        #expect(sheet.rootPage.overlay is ErrorOverlayView)
        harness.flow.retry()
        #expect(sheet.rootPage.overlay == nil)
        harness.statusGate.open()
        harness.flow.sheetWasDismissedExternally()
        try await waitUntil(timeout: 20, "result") { harness.result != nil }
        #expect(harness.result?.type == "pending")
    }

    @Test("Without a window the close confirmation keeps paying instead of hanging")
    func confirmationWithoutWindow() {
        let sheet = PaymentSheet(language: .en, websiteDataStore: .nonPersistent())
        var answers: [Bool] = []
        sheet.confirmClose { answers.append($0) }
        #expect(answers == [false])
    }

    @Test("A disconnected scene finishes the flow without UI, exactly once")
    func sceneDisconnect() async throws {
        let harness = SheetHarness(status: "PENDING")
        harness.statusGate.open()
        harness.start()
        try await waitUntil(timeout: 20, "3DS sheet") { harness.ui.sheet.flow != nil }
        let sheet = harness.ui.sheet
        let scene = NSObject()
        sheet.presentedScene = scene
        sheet.sceneDidDisconnect(NSObject())
        sheet.sceneDidDisconnect(nil)
        #expect(!sheet.isTornDown, "another scene's disconnection is ignored")

        sheet.sceneDidDisconnect(scene)
        #expect(sheet.isTornDown)
        try await waitUntil(timeout: 20, "result") { harness.result != nil }
        guard case .pending(let payment, .notFinal)? = harness.result else {
            Issue.record("expected pending(notFinal), got \(String(describing: harness.result))")
            return
        }
        #expect(payment.orderId == "o1" && payment.status == .pending)
        #expect(harness.statusRequests == 1, "one status check, as for a close")
        sheet.sceneDidDisconnect(scene)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(harness.statusRequests == 1)
    }

    @Test("Screen protection: an opaque cover hides the sheet while its scene is inactive (CONTRACT §16.0 item 4)")
    func privacyCover() throws {
        let sheet = PaymentSheet(language: .en, websiteDataStore: .nonPersistent())
        let container: UIView = sheet.navigationController.view
        container.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let scene = NSObject()
        sheet.presentedScene = scene
        #expect(sheet.privacyCover == nil)

        // Another scene's notifications are ignored.
        sheet.sceneWillDeactivate(NSObject())
        #expect(sheet.privacyCover == nil)

        sheet.sceneWillDeactivate(scene)
        let cover = try #require(sheet.privacyCover)
        #expect(cover.superview === container)
        #expect(container.subviews.last === cover, "above the navigation bar and the page")
        #expect(cover.frame == container.bounds)
        #expect(cover.isOpaque && cover.backgroundColor == .systemBackground)
        #expect(cover.accessibilityElementsHidden)
        sheet.sceneWillDeactivate(scene)
        #expect(container.subviews.filter { $0 is PrivacyCoverView }.count == 1, "one cover at a time")

        sheet.sceneDidActivate(NSObject())
        #expect(sheet.privacyCover != nil, "another scene's activation does not uncover the sheet")
        sheet.sceneDidActivate(scene)
        #expect(sheet.privacyCover == nil)
        #expect(!container.subviews.contains { $0 is PrivacyCoverView })

        // Tearing the sheet down removes a cover, so a sheet UIKit keeps on screen stays usable.
        sheet.sceneWillDeactivate(scene)
        sheet.dismiss {}
        #expect(sheet.privacyCover == nil)
        sheet.sceneWillDeactivate(scene)
        #expect(sheet.privacyCover == nil, "nothing after teardown")
    }

    @Test("Every page sits inset on the white backdrop: 16 pt at the sides, 12 pt at the top and bottom (CONTRACT §9.1)")
    func bankPageInset() throws {
        let sheet = PaymentSheet(language: .en, websiteDataStore: .nonPersistent())
        let page = sheet.rootPage
        page.loadViewIfNeeded()
        page.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let backdrop = try #require(page.webView.superview)
        #expect(backdrop.backgroundColor == .white)
        func layOut() { page.view.setNeedsLayout(); page.view.layoutIfNeeded() }
        layOut()
        let inset = backdrop.bounds.inset(by: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        #expect(page.webView.frame == inset)
        // Payriff's gateway callback is shown inset too: every page of the sheet is the bank's.
        page.contentDidCommit()
        layOut()
        #expect(page.webView.frame == inset)
    }

    @Test("Dismissing a sheet that is not presented completes at once")
    func dismissNotPresented() {
        let sheet = PaymentSheet(language: .en, websiteDataStore: .nonPersistent())
        var completed = 0
        sheet.dismiss { completed += 1 }
        #expect(completed == 1)
        #expect(sheet.isTornDown)
    }

    // MARK: Helpers

    static func labels(in view: UIView) -> [String] {
        var result: [String] = []
        for subview in view.subviews {
            if let label = subview as? UILabel, let text = label.text { result.append(text) }
            if !(subview is UIButton) { result += labels(in: subview) }
        }
        return result
    }

    static func buttons(in view: UIView) -> [String] {
        var result: [String] = []
        for subview in view.subviews {
            if let button = subview as? UIButton {
                result.append(button.configuration?.title ?? "")
            } else {
                result += buttons(in: subview)
            }
        }
        return result
    }
}

/// A card payment whose 3-D Secure challenge runs in a real ``PaymentSheet`` that is not
/// presented (the package test runner has no window scene). Nothing is loaded and nothing
/// reaches the network: the Client API is a fake whose `/status` waits for ``statusGate``.
@MainActor
final class SheetHarness {
    /// Forwards the card flow's UI calls to the sheet; the close confirmation answers "close".
    @MainActor
    final class SheetUI: CardFlowUI {
        let sheet = PaymentSheet(language: .en, websiteDataStore: .nonPersistent())

        func presentThreeDSSheet(for flow: any SheetFlowHandling) -> Bool {
            sheet.flow = flow
            sheet.rootPage.loadViewIfNeeded()
            return true
        }

        func loadThreeDS(_ request: URLRequest) {}
        func showThreeDSContent() { sheet.showWebContent() }
        func showThreeDSVerifying() { sheet.showVerifying() }
        func showThreeDSPageLoadError() { sheet.showPageLoadError() }
        func stopThreeDSLoading() { sheet.stopLoading() }
        func confirmThreeDSClose(_ decision: @escaping @MainActor (Bool) -> Void) { decision(true) }
        func dismissThreeDS(_ completion: @escaping @MainActor () -> Void) { sheet.dismiss(completion) }
        func openExternally(_ url: URL) {}
        func startMethodFrames(_ requests: [URLRequest], apiHost: String) {}
        func stopMethodFrames() {}
    }

    /// Lets `/status` answer once it is open.
    final class Gate: Sendable {
        private let isOpen = OSAllocatedUnfairLock(initialState: false)

        func open() { isOpen.withLock { $0 = true } }

        func wait() async throws {
            while !isOpen.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    let ui = SheetUI()
    let statusGate = Gate()
    let flow: CardPaymentFlow
    private let transport: FakeTransport
    private(set) var result: PayriffResult?

    init(status: String) {
        let gate = statusGate
        transport = FakeTransport { request in
            func reply(_ reply: RoutedClientAPI.Reply) -> (Int, Data) {
                if case .json(let code, let body) = reply { return (code, Data(body.utf8)) }
                return (500, Data())
            }
            switch RoutedClientAPI.route(of: request) {
            case .order?: return reply(CardBodies.order())
            case .pay?: return reply(CardBodies.challenge)
            case .status?:
                try await gate.wait()
                return reply(CardBodies.status(status))
            default: return (500, Data("{}".utf8))
            }
        }
        let client = ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_SHEET", clientSecret: "pr_cs_SHEET"),
            appId: nil,
            transport: transport,
            clock: SystemPaymentClock()
        )
        flow = CardPaymentFlow(
            orderId: "o1",
            card: CardFlowHarness.card,
            apiHost: "api.payriff.com",
            dependencies: CardPaymentFlow.Dependencies(
                client: client,
                clock: SystemPaymentClock(),
                encrypt: { _ in CardFlowHarness.encrypted },
                makeIdempotencyKey: { CardFlowHarness.idempotencyKey },
                checkDevice: { nil }
            ),
            ui: ui
        )
    }

    var statusRequests: Int {
        transport.requests.filter { RoutedClientAPI.route(of: $0) == .status }.count
    }

    func start() {
        Task { @MainActor in
            self.result = await self.flow.run()
        }
    }
}

extension GlobalStateTests {
    /// Card payments through the public API that fail before anything is sent; nested here
    /// because they configure the SDK. Real presentation in a window is tested by the example
    /// app's hosted tests (`Example/PayriffExample/Tests`), because the package test runner has
    /// no window scene.
    @MainActor
    @Suite("Card payment entry")
    struct CardPaymentEntry {
        @Test("confirmCardPayment returns early failures as results, never throws, and sends nothing")
        func earlyFailures() async throws {
            Payriff.reset()
            defer { Payriff.reset() }
            let transport = FakeTransport(status: 500, body: "{}")
            Payriff.services.transport = transport
            let form = PayriffCardForm(showsHolder: false, language: .en)
            func code(orderId: String = "o1", clientSecret: String = GlobalStateTests.clientSecret) async -> PayriffError.Code? {
                await Payriff.confirmCardPayment(form, orderId: orderId, clientSecret: clientSecret).error?.code
            }
            #expect(await code() == .notConfigured)
            Payriff.configure(PayriffConfig(environment: .sandbox))
            #expect(await code() == .invalidConfig, "no publishable key")
            Payriff.configure(PayriffConfig(publishableKey: GlobalStateTests.publishableKey, environment: .sandbox))
            #expect(await code(clientSecret: "cs_x") == .invalidOrder)
            #expect(await code(orderId: " ") == .invalidOrder)
            // The empty form: every field shows its error, and the fields are listed.
            let result = await Payriff.confirmCardPayment(form, orderId: "o1", clientSecret: GlobalStateTests.clientSecret)
            #expect(result.error?.code == .validationFailed)
            #expect(result.error?.fields.map(\.field) == [.number, .expiry, .cvv])
            #expect(transport.requests.isEmpty)
            #expect(!Payriff.isPaymentInProgress)
            #expect(!form.isProcessing)
        }
    }
}
#endif
