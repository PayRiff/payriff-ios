import Foundation

/// The status of a Payriff order, normalized from the raw `paymentStatus` string.
///
/// Raw values are normalized before matching (trimmed, upper-cased, `-` and spaces replaced
/// with `_`), and a few aliases are accepted: `PAID`, `COMPLETED`, `SETTLED` and
/// `SETTLE_PENDING` mean ``approved``; `FAILED` means ``declined``; `CANCELLED` means
/// ``canceled``; `REVERSED` means ``reverse``. Anything else is ``unknown``.
public enum PayriffPaymentStatus: String, Sendable, Hashable, CaseIterable, Codable {
    /// The order exists but nothing has been paid yet.
    case created = "CREATED"
    /// The payment is being processed.
    case pending = "PENDING"
    /// The payment was accepted but is not final yet.
    case accepted = "ACCEPTED"
    /// The payment succeeded.
    case approved = "APPROVED"
    /// A pre-authorization (hold) succeeded.
    case preAuthApproved = "PREAUTH_APPROVED"
    /// The payment was declined.
    case declined = "DECLINED"
    /// The order was cancelled.
    case canceled = "CANCELED"
    /// The order expired before it was paid.
    case expired = "EXPIRED"
    /// A pre-authorization expired.
    case preAuthExpired = "PREAUTH_EXPIRED"
    /// The payment was refunded.
    case refunded = "REFUNDED"
    /// Part of the payment was refunded.
    case partialRefund = "PARTIAL_REFUND"
    /// A refund is in progress.
    case refundInProgress = "REFUND_IN_PROGRESS"
    /// The payment was reversed.
    case reverse = "REVERSE"
    /// The order was partially paid.
    case partial = "PARTIAL"
    /// The order was paid in cash.
    case cash = "CASH"
    /// The status could not be determined or is not recognised.
    case unknown = "UNKNOWN"

    private static let aliases: [String: PayriffPaymentStatus] = [
        "PAID": .approved,
        "COMPLETED": .approved,
        "SETTLED": .approved,
        "SETTLE_PENDING": .approved,
        "FAILED": .declined,
        "CANCELLED": .canceled,
        "REVERSED": .reverse,
    ]

    /// Normalizes a raw Payriff status string. `nil` gives ``unknown``.
    ///
    /// - Parameter rawStatus: The `paymentStatus` value exactly as Payriff returned it.
    public init(rawStatus: String?) {
        guard let rawStatus else {
            self = .unknown
            return
        }
        let normalized = rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        self = Self.aliases[normalized] ?? PayriffPaymentStatus(rawValue: normalized) ?? .unknown
    }

    /// Decodes a status leniently with ``init(rawStatus:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawStatus: try container.decode(String.self))
    }

    /// Encodes the canonical upper-case status string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether the status is final. Non-final statuses (`CREATED`, `PENDING`, `ACCEPTED`,
    /// `PARTIAL` and `UNKNOWN`) can still change.
    public var isFinal: Bool {
        outcome != .nonFinal
    }

    /// The outcome group of the status (CONTRACT §8.2).
    var outcome: StatusOutcome {
        switch self {
        case .approved, .preAuthApproved: return .success
        case .declined: return .declined
        case .canceled: return .cancelled(.canceled)
        case .expired, .preAuthExpired: return .cancelled(.expired)
        case .refunded, .partialRefund, .refundInProgress, .reverse, .cash: return .unexpectedFinal
        case .created, .pending, .accepted, .partial, .unknown: return .nonFinal
        }
    }
}

/// The outcome group of a payment status.
enum StatusOutcome: Equatable, Sendable {
    case success
    case declined
    case cancelled(PayriffCancelReason)
    case unexpectedFinal
    case nonFinal
}
