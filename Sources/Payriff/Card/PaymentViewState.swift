import Foundation

/// The state of ``PayriffPaymentView`` and the rules that turn it into what the view shows
/// (CONTRACT §16.14): the Pay button's text and whether it is enabled, and the error line under
/// it. Free of UIKit, so `swift test` checks the rules on a Mac.
struct PaymentViewState: Equatable {
    /// The order, as `retrieveOrder` described it when the view appeared.
    enum Order: Equatable {
        /// Not loaded yet.
        case loading
        /// The order can be paid by card.
        case payable(PayriffClientOrder)
        /// The order exists, but its status or payment methods do not allow a card payment.
        case notPayable(PayriffClientOrder)
        /// `retrieveOrder` failed.
        case failed(PayriffError)
    }

    var order = Order.loading
    /// Whether every field of the card form is valid.
    var isFormComplete = false
    /// Whether a payment runs.
    private(set) var isPaying = false
    /// A payment reached a status (success, declined, cancelled or pending): the view does not pay
    /// the order again.
    private(set) var isFinished = false
    /// Why the order can no longer be paid after a payment: a fatal error or `ORDER_NOT_PAYABLE`.
    private(set) var paymentError: PayriffError?
    /// The texts, in the view's language.
    var strings: CardStrings
    /// Whether a fatal error was reported through `onResult`; it is reported once.
    private(set) var reportedFatalError = false

    init(strings: CardStrings) {
        self.strings = strings
    }

    /// The order once loaded, payable or not.
    var loadedOrder: PayriffClientOrder? {
        switch order {
        case .payable(let order), .notPayable(let order): return order
        case .loading, .failed: return nil
        }
    }

    /// The Pay button's text: `view.pay`, then the amount and the currency once the order is
    /// loaded ("Pay 1.02 AZN"); `view.pay` alone while it loads.
    var payTitle: String {
        let pay = strings.view(.pay)
        guard let order = loadedOrder, let amount = order.amount else { return pay }
        let currency = order.currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [pay, Self.amountText(amount), currency].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether Pay can be tapped: the order is payable and was not paid from this view, every
    /// field is valid and no payment runs. Otherwise the button is shown at 50% opacity.
    var isPayEnabled: Bool {
        guard case .payable = order, !isFinished, paymentError == nil else { return false }
        return isFormComplete && !isPaying
    }

    /// The error line under the button: why the order cannot be paid (`retrieveOrder`'s error
    /// message, `view.notPayable` in the view's language for an order that loaded but cannot be
    /// paid by card, or the error that ended a payment); `nil` while the order loads or can be
    /// paid (CONTRACT §16.14).
    var errorMessage: String? {
        if let paymentError { return message(of: paymentError) }
        switch order {
        case .loading, .payable:
            return nil
        case .notPayable:
            return strings.view(.notPayable)
        case .failed(let error):
            return message(of: error)
        }
    }

    /// Whether the order should be loaded (again) when the view appears: it was never loaded, or
    /// loading failed with an error that is not fatal, such as `NETWORK_ERROR`.
    var needsOrder: Bool {
        switch order {
        case .loading: return true
        case .failed(let error): return !error.isFatal
        case .payable, .notPayable: return false
        }
    }

    /// The order is about to be loaded: the button waits for it, and the error line goes.
    mutating func orderWillLoad() {
        order = .loading
        isFinished = false
        paymentError = nil
    }

    /// The view now pays another order; a fatal error of the previous one does not count.
    mutating func orderDidChange() {
        reportedFatalError = false
        orderWillLoad()
    }

    /// Takes `retrieveOrder`'s answer.
    ///
    /// - Returns: The result to report through `onResult`: a fatal error (CONTRACT §16.9), only
    ///   the first time.
    mutating func orderDidLoad(_ result: Result<PayriffClientOrder, PayriffError>) -> PayriffResult? {
        switch result {
        case .success(let loaded):
            order = loaded.isPayableByCard ? .payable(loaded) : .notPayable(loaded)
            return nil
        case .failure(let error):
            order = .failed(error)
            guard error.isFatal, !reportedFatalError else { return nil }
            reportedFatalError = true
            return .failed(error)
        }
    }

    /// Pay was tapped.
    mutating func paymentWillStart() {
        isPaying = true
    }

    /// Takes the payment's result, which the view then passes to `onResult`.
    ///
    /// A result with a status (success, declined, cancelled, pending) ends the view's payments. A
    /// fatal error or `ORDER_NOT_PAYABLE` means the order cannot be paid any more: its message
    /// goes under the button. Any other failure (an invalid form, a payment Payriff refused, a
    /// network error) leaves Pay as it was, so the customer can try again.
    mutating func paymentDidFinish(_ result: PayriffResult) {
        isPaying = false
        guard case .failed(let error) = result else {
            isFinished = true
            return
        }
        if error.isFatal || error.code == .orderNotPayable {
            paymentError = error
        }
        // Already reported through onResult with the payment's result.
        if error.isFatal { reportedFatalError = true }
    }

    /// An error's message for the error line, or `view.notPayable` when it has none.
    private func message(of error: PayriffError) -> String {
        let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? strings.view(.notPayable) : message
    }

    /// An amount as on Payriff's payment page: two decimals and `.` as the separator, without
    /// grouping (`1.02`, `10.50`, `1234.00`). Rounded half up to the cent.
    static func amountText(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
    }
}
