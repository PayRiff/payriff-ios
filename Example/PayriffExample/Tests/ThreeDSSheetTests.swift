import Foundation
import os
import Testing
import UIKit
@testable import Payriff

/// Presents the real 3-D Secure sheet in a window of the example app. The network is a fake:
/// the Client API is answered in-process, and the bank page is on WebKit's restricted port 9,
/// which WebKit refuses before connecting, so nothing reaches Payriff or a bank.
@MainActor
@Suite("3-D Secure sheet (app-hosted)", .serialized)
struct ThreeDSSheetTests {
    nonisolated static let publishableKey = "pr_pk_live_EXAMPLETEST"
    nonisolated static let clientSecret = "pr_cs_EXAMPLETEST"

    /// Answers the Client API: the order, a REDIRECT to the bank page, and `status`.
    final class FakeClientAPI: PayriffHTTPTransport {
        let status: String
        private let log = OSAllocatedUnfairLock(initialState: [String]())

        init(status: String) {
            self.status = status
        }

        var requests: [String] { log.withLock { $0 } }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            log.withLock { $0.append("\(method) \(path)") }
            let payload: String
            if method == "POST" {
                payload = #"{"orderId":"o1","nextAction":"REDIRECT","redirectUrl":"https://127.0.0.1:9/acs"}"#
            } else if path.hasSuffix("/status") {
                payload = #"{"orderId":"o1","status":"\#(status)","amount":1.5,"currency":"AZN"}"#
            } else {
                payload = #"{"orderId":"o1","amount":1.5,"currency":"AZN","status":"CREATED","paymentMethods":["CARD"]}"#
            }
            let body = #"{"code":"00000","message":"OK","payload":\#(payload)}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    /// A window of its own on the app's scene.
    @MainActor
    final class TestWindow {
        let window: UIWindow
        let root = UIViewController()

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.rootViewController = root
            window.makeKeyAndVisible()
        }

        func close() {
            window.isHidden = true
        }
    }

    private func configure(status: String) -> FakeClientAPI {
        Payriff.reset()
        let transport = FakeClientAPI(status: status)
        Payriff.services.transport = transport
        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox))
        return transport
    }

    /// A form in `host`'s view with a valid card typed in.
    private func filledForm(in host: TestWindow) throws -> PayriffCardForm {
        let form = PayriffCardForm(showsHolder: false, language: .en)
        host.root.view.addSubview(form)
        for (field, text) in [(PayriffCardField.number, "4111111111111111"), (.expiry, "1230"), (.cvv, "123")] {
            let textField = try #require(form.textField(for: field))
            _ = form.textField(textField, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: text)
        }
        #expect(form.isComplete)
        return form
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func sheet(of root: UIViewController) -> PaymentNavigationController? {
        root.presentedViewController as? PaymentNavigationController
    }

    @Test("confirmCardPayment presents the sheet; a swipe-down asks first; the host dismissing it delivers one result")
    func presentation() async throws {
        let transport = configure(status: "PENDING")
        let host = try TestWindow()
        defer { host.close() }
        let form = try filledForm(in: host)

        var results: [PayriffResult] = []
        Payriff.confirmCardPayment(form, orderId: "o1", clientSecret: Self.clientSecret, from: host.root) { results.append($0) }
        #expect(Payriff.isPaymentInProgress)
        try await waitUntil { sheet(of: host.root)?.isBeingPresented == false }
        let navigation = try #require(sheet(of: host.root))
        #expect(navigation.sheetPresentationController?.detents.map(\.identifier) == [.large])
        let second = await Payriff.confirmCardPayment(form, orderId: "o1", clientSecret: Self.clientSecret, from: host.root)
        #expect(second.error?.code == .paymentInProgress)

        // A swipe-down attempt asks for confirmation; nothing happens until the customer answers.
        let presentationController = try #require(navigation.presentationController)
        presentationController.delegate?.presentationControllerDidAttemptToDismiss?(presentationController)
        try await waitUntil { navigation.presentedViewController is UIAlertController }
        let alert = try #require(navigation.presentedViewController as? UIAlertController)
        let strings = PayriffStrings(language: .en)
        #expect(alert.title == strings[.cancelConfirmTitle])
        #expect(alert.message == strings[.cancelConfirmMessage])
        #expect(alert.actions.map(\.title) == [strings[.cancelConfirmNo], strings[.cancelConfirmYes]])
        #expect(results.isEmpty)

        // The host app dismissing the sheet: one status check without UI, then the result.
        host.root.dismiss(animated: false)
        try await waitUntil { !results.isEmpty }
        #expect(results == [.pending(PayriffPayment(
            orderId: "o1", status: .pending, rawStatus: "PENDING", amount: Decimal(string: "1.5"), currency: "AZN"
        ), reason: .notFinal)])
        #expect(transport.requests.filter { $0.hasSuffix("/status") }.count == 1)
        #expect(!transport.requests.contains { !$0.contains("/api/v3/client/orders/") }, "only the Client API is called")
        #expect(!Payriff.isPaymentInProgress)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(results.count == 1, "delivered exactly once")
    }

    @Test("Screen protection: the presented sheet is covered while its scene is inactive")
    func privacyCoverOnSceneDeactivation() async throws {
        _ = configure(status: "APPROVED")
        let host = try TestWindow()
        defer { host.close() }
        let form = try filledForm(in: host)

        var results: [PayriffResult] = []
        Payriff.confirmCardPayment(form, orderId: "o1", clientSecret: Self.clientSecret, from: host.root) { results.append($0) }
        try await waitUntil { sheet(of: host.root)?.isBeingPresented == false }
        let navigation = try #require(sheet(of: host.root))
        let scene = try #require(host.window.windowScene)
        func cover() -> UIView? { navigation.view.subviews.last { $0 is PrivacyCoverView } }
        #expect(cover() == nil)

        // What UIKit posts when the app switcher, Control Center or another app takes over.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        let shown = try #require(cover())
        #expect(navigation.view.subviews.last === shown, "above the page and the navigation bar")
        #expect(shown.isOpaque)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(cover() == nil)

        host.root.dismiss(animated: false)
        try await waitUntil { !results.isEmpty }
        #expect(results.first?.isSuccess == true)
    }
}
