import Foundation

/// An error reported by the SDK.
///
/// ``Payriff/retrieveOrder(orderId:clientSecret:)`` throws it, and a card payment that cannot
/// start or run completes with ``PayriffResult/failed(_:)``. The ``code`` is stable and shared
/// by all Payriff SDKs; ``message`` is human-readable English text.
public struct PayriffError: Error, Sendable, Hashable, LocalizedError, CustomStringConvertible {
    /// A stable, machine-readable error code.
    public enum Code: String, Sendable, Hashable, Codable, CaseIterable {
        /// ``Payriff/configure(_:)`` was never called.
        case notConfigured = "NOT_CONFIGURED"
        /// ``PayriffConfig/publishableKey`` is missing or is not a publishable key (`pr_pk_live_…`).
        case invalidConfig = "INVALID_CONFIG"
        /// The order id is blank, or the client secret is not `pr_cs_…`; the message names the field.
        case invalidOrder = "INVALID_ORDER"
        /// Another card payment of this SDK is still running.
        case paymentInProgress = "PAYMENT_IN_PROGRESS"
        /// Payriff rejected the publishable key or this app (HTTP 401). Fatal: create a new order.
        case unauthorized = "UNAUTHORIZED"
        /// Too many requests (HTTP 429), after the SDK's retries. Fatal: create a new order.
        case rateLimited = "RATE_LIMITED"
        /// No HTTP response was received: offline, DNS, TLS or timeout. When Payriff's server
        /// certificate fails the SDK's certificate pinning (CONTRACT §16.15), for example behind a
        /// proxy, it is not retryable, the message is "Payriff's server certificate could not be
        /// verified." and nothing was sent.
        case networkError = "NETWORK_ERROR"
        /// The card form is not valid; ``PayriffError/fields`` lists the fields. No
        /// request was made.
        case validationFailed = "VALIDATION_FAILED"
        /// The order was not found or its `clientSecret` expired (HTTP 404). Fatal:
        /// create a new order.
        case sessionExpired = "SESSION_EXPIRED"
        /// The order cannot be paid by card (its status is not `CREATED` or `PENDING`,
        /// `CARD` is not one of its payment methods, or HTTP 400).
        case orderNotPayable = "ORDER_NOT_PAYABLE"
        /// Payriff rejected the request format (HTTP 400 with code `15400`), an
        /// integration problem.
        case invalidRequest = "INVALID_REQUEST"
        /// Payriff refused the payment; ``PayriffError/message`` carries its reason.
        /// The customer may try again.
        case paymentFailed = "PAYMENT_FAILED"
        /// Payriff answered with a next step the SDK cannot run safely, and the order
        /// status was not final.
        case unexpectedResponse = "UNEXPECTED_RESPONSE"
        /// The device is jailbroken, or a hooking tool such as Frida or, in an App Store or
        /// TestFlight build, a debugger was found (CONTRACT §16.16), and
        /// ``PayriffConfig/allowCompromisedDevices`` is off. Nothing was sent. Not retryable and
        /// not fatal: the order can still be paid on another device.
        case deviceCompromised = "DEVICE_COMPROMISED"
        /// Anything else. Never retryable.
        case unknown = "UNKNOWN"
    }

    /// The error code.
    public let code: Code
    /// A human-readable description. Payriff's support-ticket suffix is split off into ``supportTicket``.
    public let message: String
    /// Whether retrying the same call later may succeed. Always `false` for ``Code/unknown``.
    public let isRetryable: Bool
    /// The HTTP status code, when a response was received.
    public let httpStatus: Int?
    /// Payriff's envelope `code`, such as `"01000"`, when the response had one.
    public let payriffCode: String?
    /// The support ticket number Payriff appended to the message, if any.
    public let supportTicket: String?
    /// The underlying platform error, if any.
    public let cause: (any Error)?
    /// `true` means the order cannot be paid any more in this session; create a new order (and
    /// get a new `clientSecret`) before the customer tries again. Set for `UNAUTHORIZED`,
    /// `SESSION_EXPIRED` and `RATE_LIMITED` from the Client API (CONTRACT §16.9).
    public let isFatal: Bool
    /// The invalid fields of a `VALIDATION_FAILED` error, in form order; empty for
    /// every other error. They never contain what the customer typed.
    public let fields: [PayriffCardFieldIssue]

    /// Creates an error.
    ///
    /// An ``Code/unknown`` error is never retryable, so `isRetryable` is ignored for it.
    public init(
        code: Code,
        message: String,
        isRetryable: Bool = false,
        httpStatus: Int? = nil,
        payriffCode: String? = nil,
        supportTicket: String? = nil,
        cause: (any Error)? = nil,
        isFatal: Bool = false,
        fields: [PayriffCardFieldIssue] = []
    ) {
        self.code = code
        self.message = message
        self.isRetryable = code == .unknown ? false : isRetryable
        self.httpStatus = httpStatus
        self.payriffCode = payriffCode
        self.supportTicket = supportTicket
        self.cause = cause
        self.isFatal = isFatal
        self.fields = fields
    }

    /// The ``message``, for `LocalizedError`.
    public var errorDescription: String? { message }

    /// A one-line description including the code and the HTTP details.
    public var description: String {
        var parts = ["\(code.rawValue): \(message)"]
        if let httpStatus { parts.append("HTTP \(httpStatus)") }
        if let payriffCode { parts.append("payriffCode \(payriffCode)") }
        if let supportTicket { parts.append("ticket \(supportTicket)") }
        if isFatal { parts.append("fatal") }
        if !fields.isEmpty { parts.append("fields " + fields.map { "\($0.field.rawValue)=\($0.error.rawValue)" }.joined(separator: ",")) }
        return "PayriffError(" + parts.joined(separator: ", ") + ")"
    }

    /// Errors are equal when every field except ``cause`` is equal.
    public static func == (lhs: PayriffError, rhs: PayriffError) -> Bool {
        lhs.code == rhs.code
            && lhs.message == rhs.message
            && lhs.isRetryable == rhs.isRetryable
            && lhs.httpStatus == rhs.httpStatus
            && lhs.payriffCode == rhs.payriffCode
            && lhs.supportTicket == rhs.supportTicket
            && lhs.isFatal == rhs.isFatal
            && lhs.fields == rhs.fields
    }

    /// Hashes every field except ``cause``.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
        hasher.combine(message)
        hasher.combine(isRetryable)
        hasher.combine(httpStatus)
        hasher.combine(payriffCode)
        hasher.combine(supportTicket)
        hasher.combine(isFatal)
        hasher.combine(fields)
    }
}

extension PayriffError: Encodable {
    private enum CodingKeys: String, CodingKey {
        case code, message, isRetryable, httpStatus, payriffCode, supportTicket
    }

    /// Encodes the fields of the shared result JSON (CONTRACT §5.3): every key is present and
    /// unknown values are `null`. ``cause``, ``isFatal`` and ``fields`` are not part of it.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(isRetryable, forKey: .isRetryable)
        try container.encode(httpStatus, forKey: .httpStatus)
        try container.encode(payriffCode, forKey: .payriffCode)
        try container.encode(supportTicket, forKey: .supportTicket)
    }

    /// The error as a JSON object (`NSNull` for unknown values), as in ``PayriffResult/jsonObject``.
    var jsonObject: [String: Any] {
        [
            "code": code.rawValue,
            "message": message,
            "isRetryable": isRetryable,
            "httpStatus": httpStatus.map { $0 as Any } ?? NSNull(),
            "payriffCode": payriffCode.map { $0 as Any } ?? NSNull(),
            "supportTicket": supportTicket.map { $0 as Any } ?? NSNull(),
        ]
    }
}

extension PayriffError {
    static func notConfigured(_ message: String = "Payriff is not configured. Call Payriff.configure(_:) first.") -> PayriffError {
        PayriffError(code: .notConfigured, message: message)
    }

    static func invalidConfig(_ message: String) -> PayriffError {
        PayriffError(code: .invalidConfig, message: message)
    }

    static func invalidOrder(_ message: String) -> PayriffError {
        PayriffError(code: .invalidOrder, message: message)
    }

    static let paymentInProgress = PayriffError(
        code: .paymentInProgress,
        message: "Another Payriff card payment is still running."
    )

    /// A compromised device (CONTRACT §16.16): not retryable, not fatal.
    static let deviceCompromised = PayriffError(
        code: .deviceCompromised,
        message: "Card payments are not available on this device."
    )

    static func network(_ message: String, cause: (any Error)? = nil) -> PayriffError {
        PayriffError(code: .networkError, message: message, isRetryable: true, cause: cause)
    }
}
