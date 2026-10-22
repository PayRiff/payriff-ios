import Foundation
@testable import Payriff

/// A JSON value from a vector file. Numbers are compared as decimals.
enum JSONAny: Decodable, Sendable, Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONAny])
    case object([String: JSONAny])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            // Swift prints the shortest representation that round-trips ("0.01"), which
            // parses back to an exact decimal on every OS version.
            self = .number(Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value))
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONAny].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONAny].self))
        }
    }

    static func parse(_ data: Data) throws -> JSONAny {
        try JSONDecoder().decode(JSONAny.self, from: data)
    }

    /// The value as a Foundation JSON object (`NSNull`, `NSDecimalNumber`, …).
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return NSDecimalNumber(decimal: value)
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let members): return members.mapValues(\.foundationObject)
        }
    }

    /// The value serialized as JSON text.
    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundationObject, options: [.fragmentsAllowed, .sortedKeys])
    }

    var objectValue: [String: JSONAny]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var decimalValue: Decimal? {
        if case .number(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return NSDecimalNumber(decimal: value).intValue }
        return nil
    }

    var isNull: Bool { self == .null }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return "\(value)"
        case .number(let value): return "\(value)"
        case .string(let value): return "\"\(value)\""
        case .array(let values): return "[" + values.map(\.description).joined(separator: ",") + "]"
        case .object(let members):
            return "{" + members.keys.sorted().map { "\"\($0)\":\(members[$0]!.description)" }.joined(separator: ",") + "}"
        }
    }
}

struct StatusVector: Decodable, Sendable, CustomStringConvertible {
    let raw: String?
    let status: String
    let outcome: String
    let cancelReason: String?
    var description: String { raw.map { "\"\($0)\"" } ?? "null" }
}

struct LanguageVector: Decodable, Sendable, CustomStringConvertible {
    let locale: String
    let expected: String
    var description: String { locale.isEmpty ? "<empty>" : locale }
}

/// `result_json.json` (CONTRACT §5.3).
struct ResultJSONVector: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let json: JSONAny
    var description: String { name }
}

enum VectorError: Error {
    case missing(String)
}

/// Loads the shared test vectors copied from `spec/vectors` (never edited here).
enum Vectors {
    /// Every vector file and the top-level keys this suite asserts. A new file or section in
    /// `spec/vectors` fails ``VectorTests/everySectionIsCovered()`` until it is tested here.
    /// The hosted-flow files (`api`, `navigation`, `payment_url_order_id`, `amount`) were archived
    /// by CONTRACT revision 5 and are no longer synced; bundling one again fails the coverage test.
    static let coveredSections: [String: Set<String>] = [
        "status": ["description", "cases"],
        "language": ["description", "cases"],
        "result_json": ["description", "cases"],
        "strings": ["description", "strings"],
        // The native card flow (CONTRACT §16), asserted by CardVectorTests.
        "card_3ds_navigation": ["description", "cases"],
        "card_api": ["description", "order", "errors", "status", "requests", "keys", "clientSecrets"],
        "card_crypto": [
            "description", "testPublicKeySpki", "testPrivateKeyPkcs8", "aesKey", "iv", "keyIv",
            "rsaWrappedKeyIv", "aesGcm", "payriffPublicKeySpki", "payriffPublicKeySha256",
        ],
        "card_format": ["description", "number", "expiry", "cvv", "holder"],
        "card_next_action": ["description", "cases"],
        "card_strings": ["description", "messages"],
        "card_validation": [
            "description", "brands", "maxPanDigits", "maxHolderLength", "number", "detectBrand",
            "expiry", "cvv", "holder", "visibleError", "luhn",
        ],
        // Certificate pinning (CONTRACT §16.15), asserted by CertificatePinningTests.
        "tls_pins": ["description", "hosts", "pins", "trustAnchors", "currentChain", "interceptedChain"],
    ]

    /// Vector files that no code in this package implements yet. Their sections are pinned here
    /// so that a change to them is noticed, and ``VectorTests/everySectionIsCovered()`` checks
    /// that each one still has cases. A file listed here and in ``coveredSections`` fails the
    /// coverage test. Every file is covered today.
    static let pendingSections: [String: Set<String>] = [:]

    static var fileNames: [String] { coveredSections.keys.sorted() }

    /// Every vector file this suite knows: covered or pending.
    static var knownFileNames: [String] { Set(coveredSections.keys).union(pendingSections.keys).sorted() }

    /// The names of the vector files bundled with the tests.
    static func bundledFileNames() throws -> [String] {
        guard let directory = Bundle.module.url(forResource: "vectors", withExtension: nil) else {
            throw VectorError.missing("vectors")
        }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    /// The top-level keys of a vector file.
    static func topLevelKeys(_ name: String) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: data(name)) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "vectors") else {
            throw VectorError.missing(name)
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    private struct CaseFile<Case: Decodable>: Decodable {
        let cases: [Case]
    }

    private static func cases<Case: Decodable>(_ name: String, as type: Case.Type) -> [Case] {
        (try? JSONDecoder().decode(CaseFile<Case>.self, from: data(name)).cases) ?? []
    }

    /// The number of entries of `key` in a vector file, read without the typed models, so a
    /// decoding problem cannot silently shrink a parameterized test.
    static func rawCount(_ name: String, key: String) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data(name)) as? [String: Any]
        return (object?[key] as? [Any])?.count ?? -1
    }

    static let status = cases("status", as: StatusVector.self)
    static let language = cases("language", as: LanguageVector.self)
    static let resultJSON = cases("result_json", as: ResultJSONVector.self)
    static let strings: [String: [String: String]] = {
        struct File: Decodable { let strings: [String: [String: String]] }
        return (try? JSONDecoder().decode(File.self, from: data("strings")).strings) ?? [:]
    }()
}

extension JSONAny {
    /// A `result_json.json` result with the revision-4 payment key `originalOrderId`
    /// (CONTRACT §16.0 item 2: always present) added as `null` where the case predates it.
    var addingNullOriginalOrderId: JSONAny {
        guard case .object(var members) = self, case .object(var payment)? = members["payment"] else { return self }
        if payment["originalOrderId"] == nil { payment["originalOrderId"] = .null }
        members["payment"] = .object(payment)
        return .object(members)
    }
}

extension JSONAny {
    /// The error codes that only the removed hosted flow produced (CONTRACT revision 5).
    static let removedErrorCodes: Set<String> = ["API_ERROR", "INVALID_RESPONSE", "PRESENTATION_FAILED"]

    /// A `result_json.json` result whose error code was removed by CONTRACT revision 5, with the
    /// card flow's `PAYMENT_FAILED` (a failed Payriff response) in its place; every other key and
    /// value is unchanged, so the case still asserts the shared JSON shape.
    var replacingRemovedErrorCode: JSONAny {
        guard case .object(var members) = self, case .object(var error)? = members["error"],
              let code = error["code"]?.stringValue, Self.removedErrorCodes.contains(code) else { return self }
        error["code"] = .string(PayriffError.Code.paymentFailed.rawValue)
        members["error"] = .object(error)
        return .object(members)
    }
}

extension Optional {
    func orThrow(_ what: String) throws -> Wrapped {
        guard let self else { throw VectorError.missing(what) }
        return self
    }
}

extension PayriffResult {
    /// Builds the result a `result_json.json` case describes (CONTRACT §5.3).
    init(vectorJSON json: JSONAny) throws {
        let members = try json.objectValue.orThrow("result object")
        func string(_ fields: [String: JSONAny], _ key: String) throws -> String {
            guard let value = fields[key]?.stringValue else { throw VectorError.missing(key) }
            return value
        }
        func payment(_ value: JSONAny?) throws -> PayriffPayment? {
            guard let fields = value?.objectValue else { return nil }
            return PayriffPayment(
                orderId: try string(fields, "orderId"),
                status: try PayriffPaymentStatus(rawValue: string(fields, "status")).orThrow("status"),
                rawStatus: fields["rawStatus"]?.stringValue,
                amount: fields["amount"]?.decimalValue,
                currency: fields["currency"]?.stringValue,
                transactionId: fields["transactionId"]?.stringValue,
                originalOrderId: fields["originalOrderId"]?.stringValue
            )
        }
        switch try string(members, "type") {
        case "success":
            self = .success(try payment(members["payment"]).orThrow("payment"))
        case "declined":
            self = .declined(try payment(members["payment"]).orThrow("payment"))
        case "cancelled":
            let reason = try PayriffCancelReason(rawValue: string(members, "reason")).orThrow("reason")
            self = .cancelled(try payment(members["payment"]), reason: reason)
        case "pending":
            let reason = try PayriffPendingReason(rawValue: string(members, "reason")).orThrow("reason")
            self = .pending(try payment(members["payment"]).orThrow("payment"), reason: reason)
        case "failed":
            let fields = try (members["error"]?.objectValue).orThrow("error")
            self = .failed(PayriffError(
                code: try PayriffError.Code(rawValue: string(fields, "code")).orThrow("code"),
                message: try string(fields, "message"),
                isRetryable: try (fields["isRetryable"]?.boolValue).orThrow("isRetryable"),
                httpStatus: fields["httpStatus"]?.intValue,
                payriffCode: fields["payriffCode"]?.stringValue,
                supportTicket: fields["supportTicket"]?.stringValue
            ))
        case let other:
            throw VectorError.missing("result type \(other)")
        }
    }
}
