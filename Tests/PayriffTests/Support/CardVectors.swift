import Foundation
@testable import Payriff

// Typed models of `spec/vectors/card_*.json` (CONTRACT §16).

struct CardValidationVectors: Decodable, Sendable {
    struct Brand: Decodable, Sendable {
        let brand: String
        let ranges: [[String]]
        let lengths: [Int]
    }

    struct FieldCase: Decodable, Sendable, CustomStringConvertible {
        let input: String
        let valid: Bool
        let empty: Bool
        let errorCode: String?
        let brand: String?
        let value: String
        var description: String { input.debugDescription }
    }

    struct DetectBrandCase: Decodable, Sendable, CustomStringConvertible {
        let digits: String
        let brand: String?
        let maxLength: Int
        var description: String { digits.debugDescription }
    }

    struct ExpiryValue: Decodable, Sendable {
        let expiryMonth: String
        let expiryYear: String
    }

    struct ExpiryCase: Decodable, Sendable, CustomStringConvertible {
        let input: String
        let valid: Bool
        let empty: Bool
        let errorCode: String?
        let value: ExpiryValue?
        var description: String { input.debugDescription }
    }

    struct Expiry: Decodable, Sendable {
        struct Now: Decodable, Sendable {
            let year: Int
            let month: Int
        }

        let now: Now
        let cases: [ExpiryCase]
    }

    struct VisibleErrorCase: Decodable, Sendable, CustomStringConvertible {
        let errorCode: String?
        let focused: Bool
        let touched: Bool
        let submitted: Bool
        let expected: String?
        var description: String { "\(errorCode ?? "nil") focused=\(focused) touched=\(touched) submitted=\(submitted)" }
    }

    struct LuhnCase: Decodable, Sendable, CustomStringConvertible {
        let digits: String
        let valid: Bool
        var description: String { digits.debugDescription }
    }

    let brands: [Brand]
    let maxPanDigits: Int
    let maxHolderLength: Int
    let number: [FieldCase]
    let detectBrand: [DetectBrandCase]
    let expiry: Expiry
    let cvv: [FieldCase]
    let holder: [FieldCase]
    let visibleError: [VisibleErrorCase]
    let luhn: [LuhnCase]
}

struct CardFormatVectors: Decodable, Sendable {
    struct Case: Decodable, Sendable, CustomStringConvertible {
        let input: String
        let expected: String
        var description: String { input.debugDescription }
    }

    struct ExpiryCase: Decodable, Sendable, CustomStringConvertible {
        let input: String
        let inserting: Bool
        let expected: String
        var description: String { "\(input.debugDescription) inserting=\(inserting)" }
    }

    let number: [Case]
    let expiry: [ExpiryCase]
    let cvv: [Case]
    let holder: [Case]
}

struct CardCryptoVectors: Decodable, Sendable {
    struct Card: Decodable, Sendable {
        let pan: String
        let cardHolder: String
        let expiryYear: String
        let expiryMonth: String
        let cvv: String
    }

    struct AESCase: Decodable, Sendable, CustomStringConvertible {
        let card: Card
        let cardJson: String
        let encryptedMessage: String
        var description: String { card.cardHolder }
    }

    let testPublicKeySpki: String
    let testPrivateKeyPkcs8: String
    let aesKey: String
    let iv: String
    let keyIv: String
    let rsaWrappedKeyIv: String
    let aesGcm: [AESCase]
    let payriffPublicKeySpki: String
    let payriffPublicKeySha256: String
}

struct CardNextActionVector: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let payload: JSONAny
    let expected: JSONAny
    var description: String { name }
}

struct ThreeDSNavigationVector: Decodable, Sendable, CustomStringConvertible {
    struct Step: Decodable, Sendable {
        let url: String
        let isMainFrame: Bool
        let expected: String
    }

    let name: String
    let apiBase: String
    let steps: [Step]
    var description: String { name }
}

struct CardAPIVectors: Decodable, Sendable {
    struct ResponseCase: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let httpStatus: Int
        let body: String
        let expect: JSONAny
        var description: String { name }
    }

    struct RequestCase: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let method: String
        let path: String
        let headers: [String: String]?
        let absentHeaders: [String]?
        let requiredHeaders: [String]?
        let body: JSONAny?
        let orderId: String?
        var description: String { name }
    }

    struct KeyCase: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let value: String
        let valid: Bool
        let sent: String?
        var description: String { name }
    }

    struct HostCase: Decodable, Sendable, CustomStringConvertible {
        let region: String
        let environment: String
        let apiBaseUrl: String
        let warning: String?
        var description: String { "\(region) \(environment)" }
    }

    struct Hosts: Decodable, Sendable {
        let defaultRegion: String
        let cases: [HostCase]
    }

    let order: [ResponseCase]
    let errors: [ResponseCase]
    let status: [ResponseCase]
    let requests: [RequestCase]
    let keys: [KeyCase]
    let clientSecrets: [KeyCase]
    let hosts: Hosts
}

enum CardVectors {
    private static func decode<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Vectors.data(name))
    }

    private struct CaseFile<Case: Decodable>: Decodable {
        let cases: [Case]
    }

    static let validation = decode("card_validation", as: CardValidationVectors.self)
    static let format = decode("card_format", as: CardFormatVectors.self)
    static let crypto = decode("card_crypto", as: CardCryptoVectors.self)
    static let api = decode("card_api", as: CardAPIVectors.self)
    static let nextAction = decode("card_next_action", as: CaseFile<CardNextActionVector>.self)?.cases ?? []
    static let navigation = decode("card_3ds_navigation", as: CaseFile<ThreeDSNavigationVector>.self)?.cases ?? []
    static let strings: [String: [String: [String: String]]] = {
        struct File: Decodable { let messages: [String: [String: [String: String]]] }
        return decode("card_strings", as: File.self)?.messages ?? [:]
    }()

    // Parameterized test arguments (empty when a file does not decode; the coverage test then fails).
    static var numberCases: [CardValidationVectors.FieldCase] { validation?.number ?? [] }
    static var cvvCases: [CardValidationVectors.FieldCase] { validation?.cvv ?? [] }
    static var holderCases: [CardValidationVectors.FieldCase] { validation?.holder ?? [] }
    static var expiryCases: [CardValidationVectors.ExpiryCase] { validation?.expiry.cases ?? [] }
    static var detectBrandCases: [CardValidationVectors.DetectBrandCase] { validation?.detectBrand ?? [] }
    static var visibleErrorCases: [CardValidationVectors.VisibleErrorCase] { validation?.visibleError ?? [] }
    static var luhnCases: [CardValidationVectors.LuhnCase] { validation?.luhn ?? [] }
    static var aesCases: [CardCryptoVectors.AESCase] { crypto?.aesGcm ?? [] }
    static var orderCases: [CardAPIVectors.ResponseCase] { api?.order ?? [] }
    static var errorCases: [CardAPIVectors.ResponseCase] { api?.errors ?? [] }
    static var statusCases: [CardAPIVectors.ResponseCase] { api?.status ?? [] }
    static var requestCases: [CardAPIVectors.RequestCase] { api?.requests ?? [] }
    static var keyCases: [CardAPIVectors.KeyCase] { api?.keys ?? [] }
    static var clientSecretCases: [CardAPIVectors.KeyCase] { api?.clientSecrets ?? [] }
    static var hostCases: [CardAPIVectors.HostCase] { api?.hosts.cases ?? [] }
}

extension PayriffCardFieldError {
    /// The error of a vector (`null` is `nil`).
    init?(vector: String?) {
        guard let vector else { return nil }
        self.init(rawValue: vector)
    }
}
