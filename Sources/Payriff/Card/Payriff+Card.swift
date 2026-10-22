import Foundation

extension Payriff {
    /// The running card payment; non-`nil` from `confirmCardPayment` until its result.
    static var activeCardFlow: CardPaymentFlow?

    /// Whether a card payment (``confirmCardPayment(_:orderId:clientSecret:from:)``) is running.
    /// While it is, another one fails with `PAYMENT_IN_PROGRESS`.
    public static var isPaymentInProgress: Bool {
        activeCardFlow != nil
    }

    /// Looks up an order with the publishable key and the order's client secret
    /// (`GET /api/v3/client/orders/{orderId}`, CONTRACT §16.10).
    ///
    /// Use it to show the amount and the merchant name before the customer pays, or to check
    /// ``PayriffClientOrder/isPayableByCard``. It does not count toward payment limits.
    ///
    /// - Parameters:
    ///   - orderId: The order id your backend created.
    ///   - clientSecret: The order's client secret (`pr_cs_…`) from your backend.
    /// - Returns: The order.
    /// - Throws: ``PayriffError``: `NOT_CONFIGURED`, `INVALID_CONFIG` (no valid
    ///   ``PayriffConfig/publishableKey``), `INVALID_ORDER` (a blank order id or a client secret
    ///   that is not `pr_cs_…`), or a Client API error such as `UNAUTHORIZED` or
    ///   `SESSION_EXPIRED` (``PayriffError/isFatal``: create a new order).
    public static func retrieveOrder(orderId: String, clientSecret: String) async throws(PayriffError) -> PayriffClientOrder {
        let context = try cardContext(orderId: orderId, clientSecret: clientSecret).get()
        return try await context.client.order(context.orderId).get()
    }

    /// Everything a card call needs, validated (CONTRACT §16.2, §16.3).
    struct CardContext: Sendable {
        let orderId: String
        let client: ClientAPIClient
        let apiHost: String
    }

    /// The configuration, the publishable key, the client secret and the order id, or the first
    /// problem: `NOT_CONFIGURED`, `INVALID_CONFIG`, then `INVALID_ORDER`. Messages never contain
    /// the keys.
    static func cardContext(orderId: String, clientSecret: String) -> Result<CardContext, PayriffError> {
        let config: PayriffConfig
        switch currentConfiguration() {
        case .failure(let error): return .failure(error)
        case .success(let value): config = value
        }
        let publishableKey: String
        switch ClientCredentials.publishableKey(config.publishableKey) {
        case .failure(let error): return .failure(error)
        case .success(let value): publishableKey = value
        }
        let secret: String
        switch ClientCredentials.clientSecret(clientSecret) {
        case .failure(let error): return .failure(error)
        case .success(let value): secret = value
        }
        let id: String
        switch ClientCredentials.orderId(orderId) {
        case .failure(let error): return .failure(error)
        case .success(let value): id = value
        }
        let client = ClientAPIClient(
            baseURL: ClientAPIHost.baseURL(for: config.environment),
            credentials: ClientCredentials(publishableKey: publishableKey, clientSecret: secret),
            appId: ClientAppID.validated(services.clientAppId()),
            transport: services.transport,
            clock: services.clock,
            logsHTTPDetails: services.isDebugBuild
        )
        return .success(CardContext(
            orderId: id,
            client: client,
            apiHost: ClientAPIHost.host(for: config.environment)
        ))
    }

    /// The `VALIDATION_FAILED` error for the invalid fields of a form (CONTRACT §16.7 step 1).
    nonisolated static func validationFailed(_ fields: [PayriffCardFieldIssue]) -> PayriffError {
        PayriffError(
            code: .validationFailed,
            message: "The card details are not valid: " + fields.map(\.field.rawValue).joined(separator: ", ") + ".",
            fields: fields
        )
    }
}
