import Foundation

/// The Client API host of each environment (CONTRACT §16.2).
enum ClientAPIHost {
    static let production = "https://api.payriff.com"
    /// Provisional: the backend will confirm the sandbox host (CONTRACT §16.13). Keep it this one constant.
    static let sandbox = "https://sb-api.payriff.com"

    static func baseURL(for environment: PayriffEnvironment) -> String {
        switch environment {
        case .production: return production
        case .sandbox: return sandbox
        }
    }

    /// The lower-cased host of `baseURL(for:)`, used to recognize gateway callbacks.
    static func host(for environment: PayriffEnvironment) -> String {
        URLComponents(string: baseURL(for: environment))?.host?.lowercased() ?? ""
    }
}

/// The credentials of the card flow: the publishable key and the order's client secret, both
/// validated (CONTRACT §16.2, `card_api.json` → `keys`, `clientSecrets`).
struct ClientCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let publishableKey: String
    let clientSecret: String

    static let publishableKeyPrefix = "pr_pk_live_"
    static let clientSecretPrefix = "pr_cs_"

    /// The publishable key without surrounding whitespace, or `INVALID_CONFIG`. It must start
    /// with `pr_pk_live_`, so a secret key ("App Key") is always refused.
    static func publishableKey(_ raw: String?) -> Result<String, PayriffError> {
        let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(publishableKeyPrefix), key.count > publishableKeyPrefix.count, isHeaderSafe(key) else {
            return .failure(.invalidConfig("publishableKey must be a Payriff publishable key (pr_pk_live_…). The card flow never uses the secret key."))
        }
        return .success(key)
    }

    /// The client secret without surrounding whitespace (otherwise sent as is), or `INVALID_ORDER`.
    static func clientSecret(_ raw: String) -> Result<String, PayriffError> {
        let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.hasPrefix(clientSecretPrefix), secret.count > clientSecretPrefix.count, isHeaderSafe(secret) else {
            return .failure(.invalidOrder("clientSecret must be the order's client secret (pr_cs_…) from your backend."))
        }
        return .success(secret)
    }

    /// The order id without surrounding whitespace, or `INVALID_ORDER`.
    static func orderId(_ raw: String) -> Result<String, PayriffError> {
        let orderId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orderId.isEmpty else { return .failure(.invalidOrder("orderId must not be empty.")) }
        return .success(orderId)
    }

    /// Printable ASCII only, so a header value can never be split or rewritten.
    private static func isHeaderSafe(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    var description: String { "ClientCredentials(<redacted>)" }
    var debugDescription: String { description }
    /// No children, so `dump` never shows the key or the secret.
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The app identity sent as `X-Client-App-Id` (CONTRACT §16.2): the bundle id, when it is a
/// reverse-DNS name of at most 255 characters; otherwise the header is omitted.
enum ClientAppID {
    static func validated(_ raw: String?) -> String? {
        guard let id = raw, !id.isEmpty, id.utf8.count <= 255 else { return nil }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-")
        }
        for (index, part) in parts.enumerated() {
            guard let first = part.unicodeScalars.first, part.unicodeScalars.allSatisfy(isAllowed) else { return nil }
            if index == 0, !(first.isASCII && first.properties.isAlphabetic) { return nil }
        }
        return id
    }

    /// The app's own bundle identifier.
    static var current: String? { validated(Bundle.main.bundleIdentifier) }
}

/// Calls Payriff's Client API with the publishable key and the order's client secret
/// (CONTRACT §16.3). The merchant secret key is never used here.
///
/// - Every request sends `X-Public-Key`, `X-Client-Secret`, `X-Client-App-Id` (when known) and
///   `Accept: application/json`; never `Origin`, `X-Parent-Origin` or `Authorization`.
/// - HTTP 429 is retried 3 times after 1, 2 and 4 s; a network error on `/pay` once after 1 s.
///   A retried `/pay` resends the identical bytes with the same idempotency key.
/// - Redirects are never followed: they would carry the keys, `x-secret-key` and the encrypted
///   card to a host outside the host table. A 3xx response is a failed response.
/// - The production transport pins Payriff's certificates (CONTRACT §16.15). A refused
///   certificate is a `NETWORK_ERROR` that is not retryable ("Payriff's server certificate could
///   not be verified."); nothing was sent, and `/pay` is not retried.
/// - Nothing secret is logged. Headers and bodies are logged only in debug builds, with every
///   secret redacted (``HTTPLog``).
struct ClientAPIClient: Sendable {
    static let getTimeout: TimeInterval = 15
    static let postTimeout: TimeInterval = 30
    static let rateLimitBackoff: [TimeInterval] = [1, 2, 4]
    static let payNetworkRetryDelay: TimeInterval = 1
    static let ordersPath = "/api/v3/client/orders"
    static let successCode = "00000"
    static let invalidRequestCode = "15400"

    /// The API base URL without a trailing slash.
    let baseURL: String
    let credentials: ClientCredentials
    /// `X-Client-App-Id`, or `nil` to omit it.
    let appId: String?
    let transport: any PayriffHTTPTransport
    let clock: any PaymentClock
    /// Whether every request and response is also logged as JSON, with headers and bodies and
    /// every secret redacted (CONTRACT §11, ``HTTPLog``). The SDK sets it in debug builds only.
    var logsHTTPDetails = false

    /// `GET /api/v3/client/orders/{orderId}`.
    func order(_ orderId: String) async -> Result<PayriffClientOrder, PayriffError> {
        let requested = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return await get(orderId, suffix: "").map { body in
            Self.parseOrder(Self.payload(body), requestedOrderId: requested)
        }
    }

    /// `POST /api/v3/client/orders/{orderId}/pay` with `{"method":"CARD","encryptedMessage":…}`.
    func pay(_ orderId: String, card: EncryptedCard, idempotencyKey: String) async -> Result<CardNextAction, PayriffError> {
        let path: String
        switch Self.path(orderId, suffix: "/pay") {
        case .success(let value): path = value
        case .failure(let error): return .failure(error)
        }
        guard var request = makeRequest(path: path, method: "POST", timeout: Self.postTimeout) else {
            return .failure(.invalidOrder("orderId does not form a valid URL."))
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(card.wrappedKey, forHTTPHeaderField: "x-secret-key")
        request.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
        request.httpBody = Self.payBody(card)
        return await execute(request, path: path, retryNetworkOnce: true).map { body in
            CardNextAction(payload: Self.payload(body))
        }
    }

    /// `GET /api/v3/client/orders/{orderId}/three-ds`.
    func threeDS(_ orderId: String) async -> Result<CardNextAction, PayriffError> {
        await get(orderId, suffix: "/three-ds").map { CardNextAction(payload: Self.payload($0)) }
    }

    /// `GET /api/v3/client/orders/{orderId}/status`.
    func status(_ orderId: String) async -> Result<StatusSnapshot, PayriffError> {
        await get(orderId, suffix: "/status").map { body in
            let payload = Self.payload(body)
            let raw = (payload["status"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return StatusSnapshot(
                status: PayriffPaymentStatus(rawStatus: raw),
                rawStatus: raw,
                amount: ResponseParser.decimal(payload["amount"]),
                currency: ResponseParser.identifierString(payload["currency"])
            )
        }
    }

    /// The pay body. Built once per attempt, so a retry sends the identical bytes.
    static func payBody(_ card: EncryptedCard) -> Data {
        Data(JSONValue.object([("method", .string("CARD")), ("encryptedMessage", .string(card.encryptedMessage))]).serialized.utf8)
    }

    /// `/api/v3/client/orders/{orderId}{suffix}`: the id is trimmed and percent-encoded as one
    /// path segment (CONTRACT §16.3).
    static func path(_ orderId: String, suffix: String) -> Result<String, PayriffError> {
        ClientCredentials.orderId(orderId).map { ordersPath + "/" + encodePathSegment($0) + suffix }
    }

    /// Percent-encodes `segment` as a single path segment: every UTF-8 byte except ALPHA,
    /// DIGIT, `-`, `_` and `~` becomes `%XX` with upper-case hex digits, so `.` and `..` can
    /// never become dot segments.
    static func encodePathSegment(_ segment: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(segment.utf8.count)
        for byte in segment.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                encoded += "%"
                encoded += String(byte >> 4, radix: 16, uppercase: true)
                encoded += String(byte & 0x0F, radix: 16, uppercase: true)
            }
        }
        return encoded
    }

    private func get(_ orderId: String, suffix: String) async -> Result<Data, PayriffError> {
        let path: String
        switch Self.path(orderId, suffix: suffix) {
        case .success(let value): path = value
        case .failure(let error): return .failure(error)
        }
        guard let request = makeRequest(path: path, method: "GET", timeout: Self.getTimeout) else {
            return .failure(.invalidOrder("orderId does not form a valid URL."))
        }
        return await execute(request, path: path, retryNetworkOnce: false)
    }

    func makeRequest(path: String, method: String, timeout: TimeInterval) -> URLRequest? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(credentials.publishableKey, forHTTPHeaderField: "X-Public-Key")
        request.setValue(credentials.clientSecret, forHTTPHeaderField: "X-Client-Secret")
        if let appId { request.setValue(appId, forHTTPHeaderField: "X-Client-App-Id") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Sends `request`, retrying 429 (and, for `/pay`, one network error) with the same request,
    /// and returns the body of a success envelope.
    private func execute(_ request: URLRequest, path: String, retryNetworkOnce: Bool) async -> Result<Data, PayriffError> {
        let method = request.httpMethod ?? "GET"
        var rateLimitRetries = 0
        var retriedNetwork = false
        while true {
            let status: Int
            let body: Data
            do {
                if logsHTTPDetails { Log.debug(HTTPLog.requestEntry(request)) }
                let (data, response) = try await transport.sendWithoutRedirects(request)
                guard let http = response as? HTTPURLResponse else {
                    return .failure(Self.mapError(httpStatus: nil, body: Data()))
                }
                if logsHTTPDetails { Log.debug(HTTPLog.responseEntry(http, body: data, of: request)) }
                status = http.statusCode
                body = data
            } catch {
                let mapped = Self.transportError(error)
                // A refused certificate is not retryable: nothing was sent, and it would be refused again.
                if mapped.code == .networkError, mapped.isRetryable, retryNetworkOnce, !retriedNetwork, !(error is CancellationError) {
                    retriedNetwork = true
                    Log.warning("\(method) \(path) failed (\(mapped.code.rawValue)); retrying once in \(Int(Self.payNetworkRetryDelay)) s with the same idempotency key.")
                    guard await sleep(Self.payNetworkRetryDelay) else { return .failure(mapped) }
                    continue
                }
                Log.warning("\(method) \(path) failed: \(mapped.code.rawValue)")
                return .failure(mapped)
            }
            if status == 429, rateLimitRetries < Self.rateLimitBackoff.count {
                let delay = Self.rateLimitBackoff[rateLimitRetries]
                rateLimitRetries += 1
                Log.warning("\(method) \(path) -> HTTP 429; retry \(rateLimitRetries) of \(Self.rateLimitBackoff.count) in \(Int(delay)) s.")
                guard await sleep(delay) else { return .failure(Self.mapError(httpStatus: status, body: body)) }
                continue
            }
            if (200...299).contains(status), Self.envelopeCode(body) == Self.successCode {
                Log.debug("\(method) \(path) -> HTTP \(status)")
                return .success(body)
            }
            let error = Self.mapError(httpStatus: status, body: body)
            Log.warning("\(method) \(path) -> HTTP \(status): \(error.code.rawValue)\(error.payriffCode.map { " (\($0))" } ?? "")")
            return .failure(error)
        }
    }

    /// Sleeps on the injected clock; `false` when the task was cancelled.
    private func sleep(_ seconds: TimeInterval) async -> Bool {
        do {
            try await clock.sleep(for: seconds)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Parsing (CONTRACT §16.3)

    private static func jsonObject(_ body: Data) -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func envelopeCode(_ body: Data) -> String? {
        jsonObject(body)?["code"] as? String
    }

    /// The `payload` object of a success body, or an empty object.
    static func payload(_ body: Data) -> [String: Any] {
        jsonObject(body)?["payload"] as? [String: Any] ?? [:]
    }

    /// Maps a non-success response (CONTRACT §16.3, `card_api.json` → `errors`):
    ///
    /// | Response | Error | Fatal |
    /// |---|---|---|
    /// | 401 | `UNAUTHORIZED` | yes |
    /// | 404 | `SESSION_EXPIRED` | yes |
    /// | 429 (after the retries) | `RATE_LIMITED` | yes |
    /// | 400 with code `15400` | `INVALID_REQUEST` | |
    /// | other 400 | `ORDER_NOT_PAYABLE` | |
    /// | anything else | `PAYMENT_FAILED`, with the server message; the customer may try again | |
    static func mapError(httpStatus: Int?, body: Data) -> PayriffError {
        let envelope = jsonObject(body)
        let payriffCode = envelope?["code"] as? String
        let (serverMessage, ticket) = ResponseParser.splitMessage(envelope?["message"] as? String)
        func error(_ code: PayriffError.Code, _ fallback: String, retryable: Bool = false, fatal: Bool = false) -> PayriffError {
            PayriffError(
                code: code,
                message: serverMessage ?? fallback,
                isRetryable: retryable,
                httpStatus: httpStatus,
                payriffCode: payriffCode,
                supportTicket: ticket,
                isFatal: fatal
            )
        }
        switch httpStatus {
        case 401?:
            return error(.unauthorized, "Payriff rejected the publishable key or this app (HTTP 401).", fatal: true)
        case 404?:
            return error(.sessionExpired, "The order was not found or its client secret expired (HTTP 404). Create a new order.", fatal: true)
        case 429?:
            return error(.rateLimited, "Too many requests to Payriff (HTTP 429).", fatal: true)
        case 400? where payriffCode == invalidRequestCode:
            return error(.invalidRequest, "Payriff rejected the request (HTTP 400).")
        case 400?:
            return error(.orderNotPayable, "The order cannot be paid (HTTP 400).")
        default:
            let suffix = httpStatus.map { " (HTTP \($0))" } ?? ""
            return error(.paymentFailed, "The payment failed\(suffix).", retryable: true)
        }
    }

    /// No response: `NETWORK_ERROR`; an oversized body counts as a failed response. A refused
    /// server certificate (CONTRACT §16.15) is a `NETWORK_ERROR` that is not retryable.
    static func transportError(_ error: any Error) -> PayriffError {
        if let tooLarge = error as? ResponseTooLargeError {
            return mapError(httpStatus: tooLarge.httpStatus, body: Data())
        }
        if error is CertificatePinningError {
            return PayriffError(code: .networkError, message: CertificatePinning.failureMessage, isRetryable: false, cause: error)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .network("The request to Payriff timed out.", cause: urlError)
            case .cancelled:
                return .network("The request to Payriff was cancelled.", cause: urlError)
            default:
                return .network("Could not reach Payriff: \(urlError.localizedDescription)", cause: urlError)
            }
        }
        if error is CancellationError {
            return .network("The request to Payriff was cancelled.", cause: error)
        }
        return .network("Could not reach Payriff.", cause: error)
    }

    /// An order payload (`card_api.json` → `order`).
    static func parseOrder(_ payload: [String: Any], requestedOrderId: String) -> PayriffClientOrder {
        let raw = (payload["status"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let language = (payload["language"] as? String).flatMap {
            PayriffLanguage(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        }
        return PayriffClientOrder(
            orderId: ResponseParser.identifierString(payload["orderId"]) ?? requestedOrderId,
            amount: ResponseParser.decimal(payload["amount"]),
            currency: ResponseParser.identifierString(payload["currency"]),
            description: payload["description"] as? String,
            merchantName: payload["merchantName"] as? String,
            status: PayriffPaymentStatus(rawStatus: raw),
            rawStatus: raw,
            language: language,
            paymentMethods: (payload["paymentMethods"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
    }
}
