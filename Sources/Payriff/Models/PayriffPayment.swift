import Foundation

/// What the SDK knows about the payment when a flow ends.
public struct PayriffPayment: Sendable, Hashable, Codable {
    /// The Payriff order id: the order passed to
    /// ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)``. Your backend decides what
    /// to fulfil: see "Fulfil on your server" in the README.
    public let orderId: String

    /// The normalized status. ``PayriffPaymentStatus/unknown`` when nothing was resolved.
    public let status: PayriffPaymentStatus

    /// The status string exactly as Payriff returned it.
    public let rawStatus: String?

    /// The order amount, from the order's status.
    public let amount: Decimal?

    /// The order currency, from the order's status.
    public let currency: String?

    /// A transaction id. Part of the result shape shared by every Payriff SDK (CONTRACT §5.1);
    /// the card flow leaves it `nil`.
    public let transactionId: String?

    /// The order id a payment started with when it switched to another order. Part of the
    /// result shape shared by every Payriff SDK (CONTRACT §16.9); the card flow pays exactly the
    /// order it was given and leaves it `nil`.
    public let originalOrderId: String?

    /// Creates a payment value, for example to stub results in your tests.
    public init(
        orderId: String,
        status: PayriffPaymentStatus,
        rawStatus: String? = nil,
        amount: Decimal? = nil,
        currency: String? = nil,
        transactionId: String? = nil,
        originalOrderId: String? = nil
    ) {
        self.orderId = orderId
        self.status = status
        self.rawStatus = rawStatus
        self.amount = amount
        self.currency = currency
        self.transactionId = transactionId
        self.originalOrderId = originalOrderId
    }

    private enum CodingKeys: String, CodingKey {
        case orderId, status, rawStatus, amount, currency, transactionId, originalOrderId
    }

    /// Encodes the payment with every key present; unknown values are `null` (CONTRACT §5.3).
    /// `status` is the canonical upper-case string and `amount` a JSON number.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(orderId, forKey: .orderId)
        try container.encode(status, forKey: .status)
        try container.encode(rawStatus, forKey: .rawStatus)
        try container.encode(amount, forKey: .amount)
        try container.encode(currency, forKey: .currency)
        try container.encode(transactionId, forKey: .transactionId)
        try container.encode(originalOrderId, forKey: .originalOrderId)
    }

    /// The payment as a JSON object (`NSNull` for unknown values), as in ``PayriffResult/jsonObject``.
    var jsonObject: [String: Any] {
        [
            "orderId": orderId,
            "status": status.rawValue,
            "rawStatus": rawStatus.map { $0 as Any } ?? NSNull(),
            "amount": amount.map { NSDecimalNumber(decimal: $0) as Any } ?? NSNull(),
            "currency": currency.map { $0 as Any } ?? NSNull(),
            "transactionId": transactionId.map { $0 as Any } ?? NSNull(),
            "originalOrderId": originalOrderId.map { $0 as Any } ?? NSNull(),
        ]
    }
}
