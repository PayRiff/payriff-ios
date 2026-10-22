import Foundation

/// A card brand the native card form accepts (CONTRACT §16.4).
public enum PayriffCardBrand: String, Sendable, Hashable, Codable, CaseIterable {
    /// Visa: prefix 4, 16 digits.
    case visa
    /// Mastercard: prefixes 51–55 and 2221–2720, 16 digits.
    case mastercard
}

/// A field of ``PayriffCardForm``.
public enum PayriffCardField: String, Sendable, Hashable, Codable, CaseIterable {
    /// The card number.
    case number
    /// The expiry date (`MM / YY`).
    case expiry
    /// The 3-digit security code.
    case cvv
    /// The cardholder name: shown by default; ``PayriffCardForm/showsHolder`` can hide it.
    case holder
}

/// Why a card field is not valid (CONTRACT §16.4, `card_validation.json`).
public enum PayriffCardFieldError: String, Sendable, Hashable, Codable, CaseIterable {
    /// The field is empty.
    case required
    /// The value is a valid beginning but not complete yet.
    case incomplete
    /// The value can never become valid by typing more (bad checksum, impossible date, too long).
    case invalid
    /// The card number belongs to a brand the form does not accept.
    case unsupported
    /// The expiry date is in the past.
    case expired
}

/// A field that failed validation when a card payment was confirmed: `failed(VALIDATION_FAILED)`
/// lists them in ``PayriffError/fields``. It never contains what the customer typed.
public struct PayriffCardFieldIssue: Sendable, Hashable {
    /// The field.
    public let field: PayriffCardField
    /// The validation error.
    public let error: PayriffCardFieldError
    /// The error text shown under the field, in the form's language.
    public let message: String

    /// Creates an issue, for example to stub results in your tests.
    public init(field: PayriffCardField, error: PayriffCardFieldError, message: String) {
        self.field = field
        self.error = error
        self.message = message
    }
}

/// The result of validating one card field. `value` is the normalized value; it is internal and
/// never leaves the SDK except encrypted.
struct CardFieldValidation: Equatable, Sendable {
    let valid: Bool
    let empty: Bool
    let errorCode: PayriffCardFieldError?
    let brand: PayriffCardBrand?
    let value: String

    init(valid: Bool, empty: Bool, errorCode: PayriffCardFieldError?, brand: PayriffCardBrand? = nil, value: String) {
        self.valid = valid
        self.empty = empty
        self.errorCode = errorCode
        self.brand = brand
        self.value = value
    }
}

/// A validated expiry date: `expiryMonth` has 2 digits, `expiryYear` 4.
struct CardExpiry: Equatable, Sendable {
    let expiryMonth: String
    let expiryYear: String
}

/// The result of validating the expiry field.
struct CardExpiryValidation: Equatable, Sendable {
    let valid: Bool
    let empty: Bool
    let errorCode: PayriffCardFieldError?
    let value: CardExpiry?
}

/// Card field validation, ported 1:1 from the web SDK (`fields/validation.js`, Payriff.js 1.2.4;
/// CONTRACT §16.4). Pure functions, so `card_validation.json` tests them directly.
enum CardValidation {
    struct BrandRule: Sendable {
        let brand: PayriffCardBrand
        let ranges: [(String, String)]
        let lengths: [Int]
    }

    /// Prefix ranges are compared as equal-length digit strings, so a partial number can be
    /// classified ("22" may still become Mastercard 2-series).
    static let brands: [BrandRule] = [
        // CONTRACT §16.4: at most 16 digits for every brand (the web SDK also allows 19 for Visa).
        BrandRule(brand: .visa, ranges: [("4", "4")], lengths: [16]),
        BrandRule(brand: .mastercard, ranges: [("51", "55"), ("2221", "2720")], lengths: [16]),
    ]

    /// The most digits a card number may have (CONTRACT §16.4): typing stops here.
    static let maxPanDigits = 16
    static let maxHolderLength = 50

    /// The ASCII digits of `text`, in order (JavaScript `replace(/\D+/g, '')`).
    static func digitsOnly(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }))
    }

    /// The Luhn checksum; an empty string is not valid.
    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for scalar in digits.unicodeScalars.reversed() {
            var digit = Int(scalar.value) - 48
            if double {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
            double.toggle()
        }
        return !digits.isEmpty && sum % 10 == 0
    }

    private static func prefixMatch(_ digits: String, _ low: String, _ high: String, full: Bool) -> Bool {
        if full, digits.count < low.count { return false }
        let length = min(digits.count, low.count)
        let prefix = String(digits.prefix(length))
        return prefix >= String(low.prefix(length)) && prefix <= String(high.prefix(length))
    }

    /// The brand once enough digits are typed to be certain, else `nil`.
    static func detectBrand(_ digits: String) -> PayriffCardBrand? {
        brands.first { rule in rule.ranges.contains { prefixMatch(digits, $0.0, $0.1, full: true) } }?.brand
    }

    private static func candidates(_ digits: String) -> [BrandRule] {
        brands.filter { rule in rule.ranges.contains { prefixMatch(digits, $0.0, $0.1, full: false) } }
    }

    /// The longest number the typed digits can still become.
    static func maxPanLength(_ digits: String) -> Int {
        candidates(digits).flatMap(\.lengths).max() ?? maxPanDigits
    }

    static func validateNumber(_ raw: String) -> CardFieldValidation {
        let digits = digitsOnly(raw)
        guard !digits.isEmpty else {
            return CardFieldValidation(valid: false, empty: true, errorCode: .required, value: "")
        }
        let brand = detectBrand(digits)
        let possible = candidates(digits)
        guard !possible.isEmpty else {
            return CardFieldValidation(valid: false, empty: false, errorCode: .unsupported, value: digits)
        }
        let lengths = brand.flatMap { brand in brands.first { $0.brand == brand }?.lengths } ?? possible.flatMap(\.lengths)
        let maximum = lengths.max() ?? maxPanDigits
        if digits.count > maximum {
            return CardFieldValidation(valid: false, empty: false, errorCode: .invalid, brand: brand, value: digits)
        }
        guard brand != nil, lengths.contains(digits.count) else {
            return CardFieldValidation(valid: false, empty: false, errorCode: .incomplete, brand: brand, value: digits)
        }
        guard luhn(digits) else {
            return CardFieldValidation(valid: false, empty: false, errorCode: .invalid, brand: brand, value: digits)
        }
        return CardFieldValidation(valid: true, empty: false, errorCode: nil, brand: brand, value: digits)
    }

    /// Accepts `MM/YY` with any separator. The card is valid through the last day of its
    /// expiry month and at most 20 years ahead.
    ///
    /// - Parameters:
    ///   - raw: The field text.
    ///   - year: The current year.
    ///   - month: The current month, 1–12.
    static func validateExpiry(_ raw: String, year: Int, month: Int) -> CardExpiryValidation {
        let digits = digitsOnly(raw)
        guard !digits.isEmpty else {
            return CardExpiryValidation(valid: false, empty: true, errorCode: .required, value: nil)
        }
        if digits.count < 4 { return CardExpiryValidation(valid: false, empty: false, errorCode: .incomplete, value: nil) }
        if digits.count > 4 { return CardExpiryValidation(valid: false, empty: false, errorCode: .invalid, value: nil) }
        let expiryMonth = Int(digits.prefix(2)) ?? 0
        let expiryYear = 2000 + (Int(digits.suffix(2)) ?? 0)
        guard (1...12).contains(expiryMonth) else {
            return CardExpiryValidation(valid: false, empty: false, errorCode: .invalid, value: nil)
        }
        let nowIndex = year * 12 + (month - 1)
        let expiryIndex = expiryYear * 12 + (expiryMonth - 1)
        if expiryIndex < nowIndex { return CardExpiryValidation(valid: false, empty: false, errorCode: .expired, value: nil) }
        if expiryIndex > nowIndex + 20 * 12 { return CardExpiryValidation(valid: false, empty: false, errorCode: .invalid, value: nil) }
        let monthText = expiryMonth < 10 ? "0\(expiryMonth)" : String(expiryMonth)
        return CardExpiryValidation(
            valid: true,
            empty: false,
            errorCode: nil,
            value: CardExpiry(expiryMonth: monthText, expiryYear: String(expiryYear))
        )
    }

    /// ``validateExpiry(_:year:month:)`` against the device's current Gregorian year and month.
    static func validateExpiry(_ raw: String, now: Date = Date()) -> CardExpiryValidation {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        return validateExpiry(raw, year: components.year ?? 2000, month: components.month ?? 1)
    }

    static func validateCvv(_ raw: String, length: Int = 3) -> CardFieldValidation {
        let digits = digitsOnly(raw)
        guard !digits.isEmpty else { return CardFieldValidation(valid: false, empty: true, errorCode: .required, value: "") }
        if digits.count < length { return CardFieldValidation(valid: false, empty: false, errorCode: .incomplete, value: digits) }
        if digits.count > length { return CardFieldValidation(valid: false, empty: false, errorCode: .invalid, value: digits) }
        return CardFieldValidation(valid: true, empty: false, errorCode: nil, value: digits)
    }

    /// JavaScript's `\s` (and the characters `String.prototype.trim` removes).
    static func isJavaScriptWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Trims the name and collapses every run of whitespace to one space
    /// (`trim().replace(/\s+/g, ' ')`).
    static func normalizeHolder(_ raw: String) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if isJavaScriptWhitespace(scalar) {
                pendingSpace = !output.isEmpty
                continue
            }
            if pendingSpace {
                output.append(" ")
                pendingSpace = false
            }
            output.append(scalar)
        }
        return String(output)
    }

    /// At most 50 UTF-16 code units (JavaScript `length`), no control characters, no `<` or `>`.
    static func validateHolder(_ raw: String) -> CardFieldValidation {
        let name = normalizeHolder(raw)
        guard !name.isEmpty else { return CardFieldValidation(valid: false, empty: true, errorCode: .required, value: "") }
        let forbidden = name.unicodeScalars.contains { $0.value <= 0x1F || $0 == "<" || $0 == ">" }
        if name.utf16.count > maxHolderLength || forbidden {
            return CardFieldValidation(valid: false, empty: false, errorCode: .invalid, value: name)
        }
        return CardFieldValidation(valid: true, empty: false, errorCode: nil, value: name)
    }

    /// The error the customer should see now (CONTRACT §16.4). Definite errors show at once;
    /// `incomplete` after the field lost focus once or a payment was attempted; `required` only
    /// after a payment was attempted; nothing while the customer is typing in the field.
    ///
    /// - Parameters:
    ///   - code: The validator's error.
    ///   - focused: Whether the field has focus.
    ///   - touched: Whether the field lost focus at least once.
    ///   - submitted: Whether a payment was attempted.
    static func visibleError(_ code: PayriffCardFieldError?, focused: Bool, touched: Bool, submitted: Bool) -> PayriffCardFieldError? {
        guard let code else { return nil }
        switch code {
        case .invalid, .unsupported, .expired:
            return code
        case .required, .incomplete:
            if focused, !submitted { return nil }
            if code == .required { return submitted ? code : nil }
            return touched || submitted ? code : nil
        }
    }
}

/// Display formatting of the card fields (web SDK `fields/format.js`). Formatting never changes
/// the validated value of the number, the expiry and the CVV: validators strip non-digits
/// themselves. The holder is upper-cased, and the upper-cased name is what is validated.
enum CardFormatting {
    /// Groups of 4 digits, cut at the longest length the typed brand allows.
    static func formatNumber(_ raw: String) -> String {
        let all = CardValidation.digitsOnly(raw)
        let digits = Array(all.prefix(CardValidation.maxPanLength(all)))
        var output = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, index % 4 == 0 { output.append(" ") }
            output.append(digit)
        }
        return output
    }

    /// `MM / YY`. While typing (`inserting`), a first digit above 1 becomes `0d / ` and two digits
    /// get the separator at once; while deleting, the separator goes away with the backspace.
    static func formatExpiry(_ raw: String, inserting: Bool) -> String {
        let digits = String(CardValidation.digitsOnly(raw).prefix(4))
        if digits.count == 1, digits > "1", inserting { return "0\(digits) / " }
        if digits.count == 2, inserting { return "\(digits) / " }
        if digits.count > 2 { return "\(digits.prefix(2)) / \(digits.dropFirst(2))" }
        return digits
    }

    /// At most 3 digits.
    static func formatCvv(_ raw: String) -> String {
        String(CardValidation.digitsOnly(raw).prefix(3))
    }

    /// The cardholder name in upper case, like the name printed on the card (CONTRACT §16.4).
    /// `uppercased()` is the locale-independent Unicode mapping (`i` → `I`, `ı` → `I`, `ə` → `Ə`).
    /// Never use the device locale's (`uppercased(with:)`, `localizedUppercase`): in Azerbaijani
    /// or Turkish it turns `i` into `İ`. Nothing else changes: spaces, apostrophes, hyphens and
    /// digits stay. The length can change (`ß` → `SS`), so the 50-character cap counts the result.
    static func formatHolder(_ raw: String) -> String {
        raw.uppercased()
    }
}
