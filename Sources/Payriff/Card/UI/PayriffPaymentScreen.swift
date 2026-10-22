#if canImport(UIKit) && canImport(WebKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// Payriff's ready-made card payment screen for SwiftUI (CONTRACT §16.14): ``PayriffPaymentView``
/// as a SwiftUI view.
///
/// It shows the card form, a Pay button with the order's amount, the card badges, "Proceed
/// securely by PCI DSS" and "Powered by Payriff", like the card part of Payriff's hosted payment
/// page. It reads the order when it appears; Pay runs
/// ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)`` and passes the result to
/// `onResult`, which also gets a fatal error that ends the order, once.
///
/// Show it as a whole screen, for example as a navigation destination or in a sheet. It fills the
/// screen, pads the safe area itself and scrolls when the keyboard is up:
///
/// ```swift
/// PayriffPaymentScreen(orderId: order.id, clientSecret: order.clientSecret) { result in
///     self.result = result   // fulfil the order on your server
///     path.removeLast()
/// }
/// .navigationBarTitleDisplayMode(.inline)
/// ```
///
/// A new `orderId` or `clientSecret` makes the screen read the new order; a new `style` or
/// `language` applies at once and keeps what the customer typed.
@available(iOSApplicationExtension, unavailable)
@MainActor
public struct PayriffPaymentScreen: View {
    let orderId: String
    let clientSecret: String
    let language: PayriffLanguage?
    let style: PayriffPaymentViewStyle
    let onResult: @MainActor (PayriffResult) -> Void

    /// Creates the payment screen for an order your server created.
    ///
    /// - Parameters:
    ///   - orderId: The order's id.
    ///   - clientSecret: The order's client secret (`pr_cs_…`).
    ///   - language: The language of the screen, or `nil` for the configured or device language.
    ///   - style: The look. Defaults to the card part of Payriff's hosted payment page.
    ///   - onResult: Called with each payment's result, and once with a fatal error
    ///     (``PayriffError/isFatal``). The result drives your UI only: fulfil the order after your
    ///     server confirms it.
    public init(
        orderId: String,
        clientSecret: String,
        language: PayriffLanguage? = nil,
        style: PayriffPaymentViewStyle = PayriffPaymentViewStyle(),
        onResult: @escaping @MainActor (PayriffResult) -> Void
    ) {
        self.orderId = orderId
        self.clientSecret = clientSecret
        self.language = language
        self.style = style
        self.onResult = onResult
    }

    public var body: some View {
        PaymentViewRepresentable(screen: self)
            // The view adds the safe area to its padding and makes room for the keyboard itself,
            // so its background reaches the screen's edges.
            .ignoresSafeArea()
    }

    /// A payment view for this screen.
    func makeView() -> PayriffPaymentView {
        PayriffPaymentView(orderId: orderId, clientSecret: clientSecret, language: language, style: style, onResult: onResult)
    }

    /// Gives `view` this screen's order, language, style and result handler.
    func configure(_ view: PayriffPaymentView) {
        view.setOrder(orderId: orderId, clientSecret: clientSecret)
        view.language = language
        view.style = style
        view.onResult = onResult
    }
}

@available(iOSApplicationExtension, unavailable)
@MainActor
private struct PaymentViewRepresentable: UIViewRepresentable {
    let screen: PayriffPaymentScreen

    func makeUIView(context: Context) -> PayriffPaymentView {
        screen.makeView()
    }

    func updateUIView(_ view: PayriffPaymentView, context: Context) {
        screen.configure(view)
    }
}
#endif
