import Foundation

/// An order as the Client API returns it to the app (`GET /api/v3/client/orders/{orderId}`,
/// CONTRACT §16.10), from ``Payriff/retrieveOrder(orderId:clientSecret:)``.
public struct PayriffClientOrder: Sendable, Hashable {
    /// The order id.
    public let orderId: String
    /// The amount, compared and written exactly.
    public let amount: Decimal?
    /// The ISO currency code, such as `AZN`.
    public let currency: String?
    /// The order description.
    public let description: String?
    /// The merchant's display name.
    public let merchantName: String?
    /// The normalized order status.
    public let status: PayriffPaymentStatus
    /// The status string exactly as Payriff returned it.
    public let rawStatus: String?
    /// The order's language, when Payriff returned a supported one.
    public let language: PayriffLanguage?
    /// The payment methods the order accepts, such as `CARD`, `APPLE_PAY` or `GOOGLE_PAY`.
    public let paymentMethods: [String]

    /// Whether the order can be paid by card now: its status is `CREATED` or `PENDING` and
    /// `CARD` is one of its payment methods. ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)``
    /// returns `failed(ORDER_NOT_PAYABLE)` otherwise.
    public var isPayableByCard: Bool {
        (status == .created || status == .pending) && paymentMethods.contains("CARD")
    }

    /// Creates an order value, for example to stub lookups in your tests.
    public init(
        orderId: String,
        amount: Decimal? = nil,
        currency: String? = nil,
        description: String? = nil,
        merchantName: String? = nil,
        status: PayriffPaymentStatus,
        rawStatus: String? = nil,
        language: PayriffLanguage? = nil,
        paymentMethods: [String] = []
    ) {
        self.orderId = orderId
        self.amount = amount
        self.currency = currency
        self.description = description
        self.merchantName = merchantName
        self.status = status
        self.rawStatus = rawStatus
        self.language = language
        self.paymentMethods = paymentMethods
    }
}
