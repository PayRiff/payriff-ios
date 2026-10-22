import Foundation

/// Parsing helpers for Payriff's Client API responses (CONTRACT §16.3).
enum ResponseParser {
    /// Splits a Payriff message at its first newline: the trimmed first line, and the digits
    /// after `Support ticket:` in the rest, if any.
    static func splitMessage(_ message: String?) -> (message: String?, supportTicket: String?) {
        guard let message else { return (nil, nil) }
        // `Character.isNewline` also covers "\r\n", which Swift treats as one character.
        let newline = message.firstIndex(where: \.isNewline)
        let first = message[..<(newline ?? message.endIndex)].trimmingCharacters(in: .whitespacesAndNewlines)
        var ticket: String?
        if let newline {
            let rest = message[message.index(after: newline)...]
            if let marker = rest.range(of: "Support ticket:") {
                let digits = rest[marker.upperBound...]
                    .drop(while: { $0.isWhitespace })
                    .prefix(while: { $0.isASCII && $0.isNumber })
                ticket = digits.isEmpty ? nil : String(digits)
            }
        }
        return (first.isEmpty ? nil : first, ticket)
    }

    /// `text` without surrounding whitespace, or `nil` when it is absent or blank.
    static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// An identifier that may arrive as a string or a JSON number, as a string. Strings are
    /// trimmed and a blank one means `nil`.
    static func identifierString(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return nonBlank(text)
        case let number as NSNumber where !isBoolean(number):
            return number.stringValue
        default:
            return nil
        }
    }

    /// A decimal from a JSON number or a numeric string.
    static func decimal(_ value: Any?) -> Decimal? {
        let posix = Locale(identifier: "en_US_POSIX")
        switch value {
        case let number as NSNumber where !isBoolean(number):
            return Decimal(string: number.stringValue, locale: posix) ?? number.decimalValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDecimalLiteral(trimmed) else { return nil }
            return Decimal(string: trimmed, locale: posix)
        default:
            return nil
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Whether `text` is a plain decimal number such as `10`, `-10.50` or `1.5e3`.
    private static func isDecimalLiteral(_ text: String) -> Bool {
        var scalars = Substring(text)
        if scalars.first == "-" || scalars.first == "+" { scalars = scalars.dropFirst() }
        let integer = scalars.prefix(while: { $0.isASCII && $0.isNumber })
        guard !integer.isEmpty else { return false }
        scalars = scalars.dropFirst(integer.count)
        if scalars.first == "." {
            scalars = scalars.dropFirst()
            let fraction = scalars.prefix(while: { $0.isASCII && $0.isNumber })
            guard !fraction.isEmpty else { return false }
            scalars = scalars.dropFirst(fraction.count)
        }
        if scalars.first == "e" || scalars.first == "E" {
            scalars = scalars.dropFirst()
            if scalars.first == "-" || scalars.first == "+" { scalars = scalars.dropFirst() }
            let exponent = scalars.prefix(while: { $0.isASCII && $0.isNumber })
            guard !exponent.isEmpty else { return false }
            scalars = scalars.dropFirst(exponent.count)
        }
        return scalars.isEmpty
    }
}
