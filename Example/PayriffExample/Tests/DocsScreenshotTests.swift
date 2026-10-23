import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Payriff
@testable import PayriffExample

/// Takes the screenshots of the iOS docs page (`docs-site/ios`) on a simulator.
///
/// It runs only when the environment has `DOCS_SHOTS_DIR`, which the docs' `tools/shots.py` sets
/// (as `TEST_RUNNER_DOCS_SHOTS_DIR`). The test drives the example's screen and, for each scene,
/// writes `<name>.request` into that directory and waits for `<name>.done`: the script takes the
/// simulator screenshot in between. It runs once in the light and once in the dark appearance.
///
/// It never reaches Payriff: a fake transport answers the order lookup with a sample order, and
/// nothing is paid.
@MainActor
@Suite("Docs screenshots", .serialized, .enabled(if: DocsShots.directory != nil))
struct DocsScreenshotTests {
    // The docs' sample order and keys. Not real: only the fake transport below knows them.
    nonisolated static let orderId = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    nonisolated static let clientSecret = "pr_cs_v1_DocsScreenshotSampleOnly0000000000000"
    nonisolated static let publishableKey = "pr_pk_live_DocsScreenshotSampleOnly000000000"

    /// Answers `GET /api/v3/client/orders/{orderId}` with a payable 1.00 AZN order. Every other
    /// request gets HTTP 404.
    final class FakePayriff: PayriffHTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            guard let url = request.url else { throw URLError(.badURL) }
            let isOrder = request.httpMethod == "GET"
                && CertificatePinning.isPinned(host: url.host ?? "")
                && url.path == "/api/v3/client/orders/\(DocsScreenshotTests.orderId)"
            let body = isOrder
                ? #"{"code":"00000","message":"OK","payload":{"orderId":"\#(DocsScreenshotTests.orderId)","amount":1.0,"currency":"AZN","description":"Order #1042","merchantName":"Payriff Docs","status":"CREATED","language":"EN","paymentMethods":["CARD"]}}"#
                : #"{"code":"15404"}"#
            let response = HTTPURLResponse(
                url: url,
                statusCode: isOrder ? 200 : 404,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
            guard let response else { throw URLError(.badServerResponse) }
            return (Data(body.utf8), response)
        }
    }

    struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "Timed out: \(what)" }
    }

    @Test("The docs' scenes, in the current appearance")
    func screenshots() async throws {
        // The example's model reads its settings from Info.plist; shots.py builds the app with the
        // sample key, so the screen shows a configured example. The SDK then gets the fake.
        let model = ExampleModel()
        Payriff.reset()
        Payriff.services.transport = FakePayriff()
        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .production))

        let popup = DocsPopup()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: HomeWithPopup(model: model, popup: popup))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let dark = window.traitCollection.userInterfaceStyle == .dark

        // The example's screen with the order filled in.
        try await pause(1500)
        model.orderId = Self.orderId
        model.clientSecret = Self.clientSecret
        try await shot("01-home", window)

        // Pay in page: empty, filled (Visa), then a number that fails the Luhn check.
        model.presentation = .page
        var paymentView = try await loadedPaymentView(in: window)
        try await shot("02-page", window)
        try fill(paymentView.form, number: "4111111111111111")
        try await shot("03-page-filled", window)
        try type("4111111111111112", into: .number, of: paymentView.form)
        try await shot("04-page-error", window)
        try await close(model, window)

        // Pay in bottom sheet, filled with a Mastercard.
        model.presentation = .bottomSheet
        paymentView = try await loadedPaymentView(in: window)
        try await shot("05-sheet", window)
        try fill(paymentView.form, number: "5555555555554444")
        try await shot("06-sheet-filled", window)
        try await close(model, window)

        // The README's popup (the docs' `present-popup`) over the example's screen. The example's own
        // "Pay in popup" adds a close button in a container of its own.
        popup.isShown = true
        _ = try await loadedPaymentView(in: window)
        try await shot("07-popup", window)
        popup.isShown = false
        try await waitUntil("the popup to go away") { Self.paymentViews(in: window).isEmpty }

        // The custom style and the Azerbaijani view are shown in the light appearance only.
        guard !dark else { return }

        // Appearance: the view restyled through PayriffPaymentViewStyle (the docs' `.violet`).
        window.rootViewController = UIHostingController(rootView: PayriffPaymentScreen(
            orderId: Self.orderId,
            clientSecret: Self.clientSecret,
            style: .violet
        ) { _ in })
        _ = try await loadedPaymentView(in: window)
        try await shot("08-custom", window)

        // Localization: the default view in Azerbaijani.
        window.rootViewController = UIHostingController(rootView: PayriffPaymentScreen(
            orderId: Self.orderId,
            clientSecret: Self.clientSecret,
            language: .az
        ) { _ in })
        _ = try await loadedPaymentView(in: window)
        try await shot("09-az", window)
    }

    // MARK: - Steps

    /// Asks shots.py for a screenshot of the simulator and waits until it is taken.
    private func shot(_ name: String, _ window: UIWindow) async throws {
        window.endEditing(true)
        try await pause(900)
        let directory = try #require(DocsShots.directory)
        let suffix = window.traitCollection.userInterfaceStyle == .dark ? "-dark" : ""
        let request = directory.appendingPathComponent("\(name)\(suffix).request")
        let done = directory.appendingPathComponent("\(name)\(suffix).done")
        try Data().write(to: request)
        try await waitUntil("the screenshot \(name)\(suffix)", timeout: 60) {
            FileManager.default.fileExists(atPath: done.path)
        }
    }

    /// The payment view on screen once it has read the sample order: its Pay title shows the amount.
    private func loadedPaymentView(in window: UIWindow) async throws -> PayriffPaymentView {
        var found: PayriffPaymentView?
        try await waitUntil("the payment view with the sample order") {
            found = Self.paymentViews(in: window).first { $0.payButton.title.hasSuffix("1.00 AZN") }
            return found != nil
        }
        // Let the presentation and the sheet's detent settle.
        try await pause(800)
        return try #require(found)
    }

    /// Closes the example's page or sheet, as its back button or a swipe does.
    private func close(_ model: ExampleModel, _ window: UIWindow) async throws {
        model.presentation = nil
        try await waitUntil("the payment view to go away") { Self.paymentViews(in: window).isEmpty }
        try await pause(600)
    }

    /// Types the docs' card into the form: the holder, `number`, 12/30 and CVC 123.
    private func fill(_ form: PayriffCardForm, number: String) throws {
        // No focus moves, so no keyboard comes up.
        form.autoAdvance = false
        try type("AYSEL MAMMADOVA", into: .holder, of: form)
        try type(number, into: .number, of: form)
        try type("1230", into: .expiry, of: form)
        try type("123", into: .cvv, of: form)
    }

    /// Replaces the text of `field` the way typing does: through the form's text field delegate
    /// for the number, the expiry and the CVC, and as an edit of the system keyboard for the holder.
    private func type(_ text: String, into field: PayriffCardField, of form: PayriffCardForm) throws {
        let textField = try #require(form.textField(for: field))
        if field == .holder {
            textField.text = text
            textField.sendActions(for: .editingChanged)
        } else {
            let length = (textField.text ?? "").utf16.count
            _ = form.textField(textField, shouldChangeCharactersIn: NSRange(location: 0, length: length), replacementString: text)
        }
    }

    // MARK: - Helpers

    private static func paymentViews(in view: UIView) -> [PayriffPaymentView] {
        var found: [PayriffPaymentView] = []
        if let paymentView = view as? PayriffPaymentView { found.append(paymentView) }
        for subview in view.subviews { found += paymentViews(in: subview) }
        return found
    }

    private func pause(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw Timeout(what: what) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Whether the docs' popup is shown.
@MainActor
final class DocsPopup: ObservableObject {
    @Published var isShown = false
}

/// The example's screen with the docs' popup over it: the README's popup idiom, as the docs show it.
private struct HomeWithPopup: View {
    let model: ExampleModel
    @ObservedObject var popup: DocsPopup

    var body: some View {
        ContentView()
            .environmentObject(model)
            .overlay {
                if popup.isShown {
                    ZStack {
                        // The dimmed screen; a tap outside closes the popup.
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture { popup.isShown = false }
                        PayriffPaymentScreen(
                            orderId: DocsScreenshotTests.orderId,
                            clientSecret: DocsScreenshotTests.clientSecret
                        ) { _ in
                            popup.isShown = false
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 440, maxHeight: 640)
                        .padding(16)
                    }
                }
            }
    }
}

/// Where DocsScreenshotTests and shots.py exchange their request and done files: `DOCS_SHOTS_DIR`.
enum DocsShots {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["DOCS_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

// The docs' custom style (docs-site/ios, snippet `style-custom`), so that 08-custom shows what
// that code gives. Keep the two the same.
extension PayriffPaymentViewStyle {
    /// Violet, with every field in its own box.
    static var violet: PayriffPaymentViewStyle {
        let violet = UIColor(red: 0x6D / 255, green: 0x28 / 255, blue: 0xD9 / 255, alpha: 1)
        let pale = UIColor(red: 0xF5 / 255, green: 0xF3 / 255, blue: 0xFF / 255, alpha: 1)
        let lilac = UIColor(red: 0xDD / 255, green: 0xD6 / 255, blue: 0xFE / 255, alpha: 1)

        var style = PayriffPaymentViewStyle()
        style.backgroundColor = pale
        style.buttonColor = violet
        style.buttonHeight = 52
        style.buttonCornerRadius = 26
        style.showPoweredBy = false
        style.formStyle.layout = .stacked
        style.formStyle.labelTextStyle = .init(size: 12, weight: .bold, color: violet)
        style.formStyle.inputTextStyle = .init(size: 16, weight: .medium)
        style.formStyle.fieldBackgroundColor = .white
        style.formStyle.borderColor = lilac
        style.formStyle.focusedBorderColor = violet
        style.formStyle.cornerRadius = 14
        style.formStyle.holderHeight = 52
        style.formStyle.rowHeight = 52
        return style
    }
}
