import Foundation

/// The request and response details of the SDK's API calls (CONTRACT §11).
///
/// In debug builds every API call also logs, at `debug` level, one pretty-printed JSON object for
/// the request (`method`, `url`, `headers`, `body`) and one for the response (`status`, `method`,
/// `url`, `headers`, `body`). Release builds never log them: the Client API logs them only when
/// ``ClientAPIClient/logsHTTPDetails`` is set, which the SDK does from
/// `Payriff.Services.isDebugBuild`.
///
/// Secrets never reach these entries:
/// - `Authorization`, `X-Client-Secret` and `x-secret-key` show as `***(<length>)`, and
///   `X-Public-Key` as `pr_pk_live_***(<length>)`.
/// - The fields in ``secretFields`` show as `***(<length>)` at any depth, and the `value` of a
///   `{key, value}` form field (`clientRequest`) never shows.
/// - Card numbers (``panFields``) show only their last four digits, unless already masked.
/// - http(s) URLs, in bodies and in the logged `url`, lose their query, fragment and user info.
/// - A body that is not JSON shows as `(<n> bytes, not JSON)`; one whose redacted JSON is longer
///   than ``maximumBodyLength`` characters as `(<n> characters of JSON, too long to log)`; and,
///   on iOS only, one nested deeper than ``maximumBodyDepth`` levels as
///   `(<n> bytes of JSON, nested too deeply to log)`.
///
/// Lengths count UTF-16 code units, as in the other Payriff SDKs. The layout matches theirs
/// (2-space indentation, `"name": value`, headers sorted by name), with one unavoidable
/// difference: `JSONSerialization` does not keep the order of an object's keys, so the keys
/// inside a body are sorted by name, and numbers are written from their parsed value (`10.50`
/// as `10.5`).
enum HTTPLog {
    /// A body whose redacted JSON is longer than this many characters is not logged in full.
    static let maximumBodyLength = 16_000

    /// A body whose objects and arrays are nested deeper than this is not logged in full either
    /// (an iOS safeguard; Payriff's bodies are a few levels deep). Redacting and printing recurse
    /// once per level, and on the 512 KB stack of a Swift concurrency thread a debug build runs
    /// out of stack at about 320 levels, while `JSONSerialization` accepts 512.
    static let maximumBodyDepth = 64

    /// Headers whose values never reach the logs, lower-cased.
    static let secretHeaders: Set<String> = ["authorization", "x-client-secret", "x-secret-key"]

    /// JSON fields whose values never reach the logs, at any depth; lower-cased, matched
    /// ignoring case.
    static let secretFields: Set<String> = [
        "appkey", "app_key", "cardholder", "card_holder", "clientsecret", "client_secret", "creq",
        "cvc", "cvv", "encryptedmessage", "expirymonth", "expiryyear", "password", "secretkey",
        "secret_key", "threedsmethoddata", "threedssessiondata",
    ]

    /// Card-number fields, of which only the last four digits are logged; lower-cased.
    static let panFields: Set<String> = ["pan", "cardnumber", "card_number"]

    // MARK: - Entries

    /// The `debug` entry for `request`, logged just before it is sent.
    static func requestEntry(_ request: URLRequest) -> String {
        "HTTP request\n" + describeRequest(
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
    }

    /// The `debug` entry for `response`, the answer to `request`, with its `body`.
    static func responseEntry(_ response: HTTPURLResponse, body: Data, of request: URLRequest) -> String {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[(name.base as? String) ?? "\(name)"] = (value as? String) ?? "\(value)"
        }
        return "HTTP response\n" + describeResponse(
            status: response.statusCode,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            headers: headers,
            body: body
        )
    }

    /// The request as pretty-printed JSON: `method`, `url`, `headers`, `body`.
    static func describeRequest(method: String, url: String, headers: [String: String], body: Data?) -> String {
        JSONValue.object([
            ("method", .string(method)),
            ("url", .string(redactedURL(url))),
            ("headers", redactedHeaders(headers)),
            ("body", redactedBody(body)),
        ]).prettyPrinted
    }

    /// The response as pretty-printed JSON: `status`, `method`, `url`, `headers`, `body`.
    static func describeResponse(status: Int, method: String, url: String, headers: [String: String], body: Data?) -> String {
        JSONValue.object([
            ("status", .number(String(status))),
            ("method", .string(method)),
            ("url", .string(redactedURL(url))),
            ("headers", redactedHeaders(headers)),
            ("body", redactedBody(body)),
        ]).prettyPrinted
    }

    // MARK: - Redaction

    /// `headers` sorted by name (ignoring case), with secret headers as `***(<length>)` and the
    /// publishable key reduced to its prefix.
    static func redactedHeaders(_ headers: [String: String]) -> JSONValue {
        let sorted = headers.sorted { lhs, rhs in
            let (left, right) = (lhs.key.lowercased(), rhs.key.lowercased())
            return left == right ? lhs.key < rhs.key : left < right
        }
        return .object(sorted.map { ($0.key, .string(headerValue(name: $0.key, value: $0.value))) })
    }

    private static func headerValue(name: String, value: String) -> String {
        let lower = name.lowercased()
        if secretHeaders.contains(lower) { return redacted(value) }
        if lower == "x-public-key" {
            let prefix = ClientCredentials.publishableKeyPrefix
            return value.unicodeScalars.starts(with: prefix.unicodeScalars)
                ? "\(prefix)***(\(value.utf16.count))"
                : redacted(value)
        }
        return value
    }

    /// A JSON `body` with secrets redacted, card numbers masked and URL queries stripped:
    /// `null` when empty, and a short description when it is not JSON or too long.
    static func redactedBody(_ body: Data?) -> JSONValue {
        guard let body, !body.isEmpty else { return .null }
        // Fragments too: a JSON body may be a single string or number.
        guard let parsed = try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed) else {
            return .string("(\(body.count) bytes, not JSON)")
        }
        guard let value = jsonValue(parsed) else {
            return .string("(\(body.count) bytes of JSON, nested too deeply to log)")
        }
        let shown = redact(value, key: nil)
        let length = shown.serialized.utf16.count
        return length <= maximumBodyLength ? shown : .string("(\(length) characters of JSON, too long to log)")
    }

    /// `value` with secrets redacted, card numbers masked and URL queries stripped. `key` is the
    /// name of the member that holds it; an array passes its own name on to its elements.
    static func redact(_ value: JSONValue, key: String?) -> JSONValue {
        switch value {
        case .object(let members):
            // A form field for the bank (`clientRequest`: creq, session data): its name is
            // shown, its value never.
            let isFormField = members.contains { $0.0 == "key" && $0.1.isString } && members.contains { $0.0 == "value" }
            return .object(members.map { name, member in
                if isFormField, name == "value" {
                    return (name, member == .null ? .null : .string(redacted(text(of: member))))
                }
                return (name, redact(member, key: name))
            })
        case .array(let elements):
            return .array(elements.map { redact($0, key: key) })
        case .null:
            return .null
        case .bool, .number, .string:
            if let lower = key?.lowercased() {
                if secretFields.contains(lower) { return .string(redacted(text(of: value))) }
                if panFields.contains(lower) { return .string(maskedPAN(text(of: value))) }
            }
            if case .string(let text) = value, isHTTPURL(text) { return .string(redactedURL(text)) }
            return value
        }
    }

    /// A secret as `***(<length>)`.
    static func redacted(_ secret: String) -> String {
        "***(\(secret.utf16.count))"
    }

    /// `****` and the last four digits of `pan`; `pan` itself when it is already masked (contains
    /// `*`), and `***(<length>)` when it has four digits or fewer.
    static func maskedPAN(_ pan: String) -> String {
        if pan.contains("*") { return pan }
        let digits = pan.unicodeScalars.filter { ("0"..."9").contains($0) }
        guard digits.count > 4 else { return redacted(pan) }
        return "****" + String(String.UnicodeScalarView(digits.suffix(4)))
    }

    /// `url` as it may be logged (CONTRACT §11): an http(s) or relative URL without its query,
    /// fragment and user info (`user:password@`), as ``Log/redactedURL(_:)`` logs it; a URL with
    /// any other scheme only as `<scheme>:…`.
    static func redactedURL(_ url: String) -> String {
        let scalars = url.unicodeScalars
        // Where the part after the scheme starts.
        var rest = scalars.startIndex
        if let colon = scalars.firstIndex(of: ":"), isScheme(scalars[..<colon]) {
            let scheme = String(scalars[..<colon])
            let lower = scheme.lowercased()
            if lower != "http", lower != "https" { return scheme + ":…" }
            rest = scalars.index(after: colon)
        }
        let end = scalars.firstIndex { $0 == "?" || $0 == "#" } ?? scalars.endIndex
        // The authority follows `//`, after the scheme or at the start of a relative URL, and
        // ends at the next `/`. Its user info runs up to its last `@`.
        let head = scalars[rest..<end]
        guard head.starts(with: "//".unicodeScalars) else { return String(scalars[..<end]) }
        let authority = head.index(head.startIndex, offsetBy: 2)
        let authorityEnd = head[authority...].firstIndex(of: "/") ?? head.endIndex
        guard let at = head[authority..<authorityEnd].lastIndex(of: "@") else { return String(scalars[..<end]) }
        return String(scalars[..<authority]) + String(scalars[scalars.index(after: at)..<end])
    }

    // MARK: - Helpers

    /// A value from `JSONSerialization` as a ``JSONValue``, with the keys of every object sorted;
    /// `nil` when its objects and arrays are nested deeper than ``maximumBodyDepth``.
    static func jsonValue(_ object: Any, depth: Int = 0) -> JSONValue? {
        switch object {
        case let dictionary as [String: Any]:
            guard depth < maximumBodyDepth else { return nil }
            var members: [(String, JSONValue)] = []
            members.reserveCapacity(dictionary.count)
            for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
                guard let member = jsonValue(value, depth: depth + 1) else { return nil }
                members.append((key, member))
            }
            return .object(members)
        case let array as [Any]:
            guard depth < maximumBodyDepth else { return nil }
            var elements: [JSONValue] = []
            elements.reserveCapacity(array.count)
            for value in array {
                guard let element = jsonValue(value, depth: depth + 1) else { return nil }
                elements.append(element)
            }
            return .array(elements)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            if !(number is NSDecimalNumber), type == "d" || type == "f" {
                return .number(number.doubleValue.description)
            }
            return .number(number.stringValue)
        default:
            return .null
        }
    }

    /// The text whose length a redacted value shows: a string as is, a number or a boolean as
    /// written, an object or an array as compact JSON.
    private static func text(of value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let literal): return literal
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array, .object: return value.serialized
        }
    }

    /// Whether `text` starts with `http://` or `https://`, ignoring case.
    private static func isHTTPURL(_ text: String) -> Bool {
        let head = String(text.unicodeScalars.prefix(8)).lowercased()
        return head.hasPrefix("http://") || head.hasPrefix("https://")
    }

    /// An RFC 3986 scheme: a letter, then letters, digits, `+`, `-` and `.`.
    private static func isScheme(_ scalars: Substring.UnicodeScalarView) -> Bool {
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }
        guard let first = scalars.first, isLetter(first) else { return false }
        return scalars.dropFirst().allSatisfy {
            isLetter($0) || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == "."
        }
    }
}

private extension JSONValue {
    var isString: Bool {
        if case .string = self { return true }
        return false
    }
}
