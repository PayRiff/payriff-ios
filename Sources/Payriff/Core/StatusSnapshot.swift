import Foundation

/// An order status from `GET /api/v3/client/orders/{orderId}/status` (CONTRACT §16.7 step 5).
struct StatusSnapshot: Equatable, Sendable {
    let status: PayriffPaymentStatus
    let rawStatus: String?
    let amount: Decimal?
    let currency: String?

    init(status: PayriffPaymentStatus, rawStatus: String?, amount: Decimal? = nil, currency: String? = nil) {
        self.status = status
        self.rawStatus = rawStatus
        self.amount = amount
        self.currency = currency
    }
}
