import Foundation

/// The outcome of ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)``.
///
/// Payment outcomes are returned, never thrown, and every call completes with exactly one
/// result. The result drives your UI only: fulfil an order after your backend has confirmed
/// it with Payriff. Only ``success(_:)`` means paid; ``pending(_:reason:)`` means "verify the
/// order on your backend".
///
/// ```swift
/// switch await Payriff.confirmCardPayment(form, orderId: orderId, clientSecret: clientSecret) {
/// case .success(let payment): showReceipt(payment)
/// case .declined: showDeclined()
/// case .cancelled(let payment, _): await backend.reconcile(payment?.orderId)
/// case .pending(let payment, _): await backend.verify(payment.orderId)
/// case .failed(let error): showError(error.message)
/// }
/// ```
public enum PayriffResult: Sendable, Hashable {
    /// The order status is `APPROVED` or `PREAUTH_APPROVED`.
    case success(PayriffPayment)
    /// The order status is `DECLINED`.
    case declined(PayriffPayment)
    /// The order was cancelled or expired (status `CANCELED`, `EXPIRED` or `PREAUTH_EXPIRED`).
    /// Closing the 3-D Secure sheet never gives this result: the card was already submitted, so
    /// a non-final status is ``pending(_:reason:)``.
    ///
    /// The payment is optional for parity with the other Payriff SDKs' result shape
    /// (CONTRACT §5); the card flow always sets it.
    case cancelled(PayriffPayment?, reason: PayriffCancelReason)
    /// The final status could not be confirmed. Verify the order on your backend.
    case pending(PayriffPayment, reason: PayriffPendingReason)
    /// The payment could not start or run: configuration, an invalid card form, an order that
    /// cannot be paid, or an error from Payriff's API.
    case failed(PayriffError)

    /// The payment carried by the result, if any.
    public var payment: PayriffPayment? {
        switch self {
        case .success(let payment), .declined(let payment), .pending(let payment, _):
            return payment
        case .cancelled(let payment, _):
            return payment
        case .failed:
            return nil
        }
    }

    /// The error of a ``failed(_:)`` result.
    public var error: PayriffError? {
        if case .failed(let error) = self { return error }
        return nil
    }

    /// Whether the result is ``success(_:)``, the only result that means "paid".
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// The result as a JSON object in the shape shared by every Payriff SDK (CONTRACT §5.3),
    /// ready for `JSONSerialization` or a cross-platform bridge. Every key is present and
    /// unknown values are `NSNull`; `amount` is an `NSDecimalNumber`, so it is written exactly.
    ///
    /// ```json
    /// {"type":"cancelled","reason":"userClosed","payment":null}
    /// ```
    public var jsonObject: [String: Any] {
        switch self {
        case .success(let payment), .declined(let payment):
            return ["type": type, "payment": payment.jsonObject]
        case .cancelled(let payment, let reason):
            return ["type": type, "reason": reason.rawValue, "payment": payment.map { $0.jsonObject as Any } ?? NSNull()]
        case .pending(let payment, let reason):
            return ["type": type, "reason": reason.rawValue, "payment": payment.jsonObject]
        case .failed(let error):
            return ["type": type, "error": error.jsonObject]
        }
    }

    /// The variant name used in the JSON representation: `success`, `declined`, `cancelled`,
    /// `pending` or `failed`.
    public var type: String {
        switch self {
        case .success: return "success"
        case .declined: return "declined"
        case .cancelled: return "cancelled"
        case .pending: return "pending"
        case .failed: return "failed"
        }
    }
}

/// Why a payment ended as ``PayriffResult/cancelled(_:reason:)``.
public enum PayriffCancelReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The customer closed the payment before paying. Part of the result shape shared by every
    /// Payriff SDK (CONTRACT §5); the card flow never returns it, because a close of the 3-D
    /// Secure sheet happens after the card was submitted.
    case userClosed
    /// The order status is `CANCELED`.
    case canceled
    /// The order status is `EXPIRED` or `PREAUTH_EXPIRED`.
    case expired
}

/// Why a payment ended as ``PayriffResult/pending(_:reason:)``.
public enum PayriffPendingReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The status was still non-final when polling ended (120 s), or when the customer closed
    /// the 3-D Secure sheet.
    case notFinal
    /// There is no way to verify the status. Part of the result shape shared by every Payriff
    /// SDK (CONTRACT §5); the card flow never returns it.
    case unverified
    /// Status polling stopped on an error other than a network error.
    case verificationFailed
    /// The status is final but unexpected for a new payment, such as `REFUNDED`.
    case unexpectedStatus
}

extension PayriffResult: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, reason, payment, error
    }

    /// Encodes the result in the shape shared by every Payriff SDK (CONTRACT §5.3):
    /// `{"type":"success","payment":{…}}`. Cancelled and pending results add `"reason"`;
    /// failed results carry `"error"` instead of `"payment"`. Every key of the payment and the
    /// error is present, with `null` for unknown values. ``jsonObject`` gives the same shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .success(let payment), .declined(let payment):
            try container.encode(payment, forKey: .payment)
        case .cancelled(let payment, let reason):
            try container.encode(reason, forKey: .reason)
            if let payment {
                try container.encode(payment, forKey: .payment)
            } else {
                try container.encodeNil(forKey: .payment)
            }
        case .pending(let payment, let reason):
            try container.encode(reason, forKey: .reason)
            try container.encode(payment, forKey: .payment)
        case .failed(let error):
            try container.encode(error, forKey: .error)
        }
    }
}
