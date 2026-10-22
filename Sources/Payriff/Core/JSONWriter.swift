import Foundation

/// A minimal JSON value used to build request bodies and log entries with exact control over
/// the output.
///
/// Numbers are stored as their literal text, so they are written exactly as given.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    /// An object; keys are written in the given order.
    case object([(String, JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// The compact JSON text of the value.
    var serialized: String {
        var output = ""
        write(to: &output)
        return output
    }

    /// The JSON text of the value laid out for reading: 2-space indentation, one member or
    /// element per line, `"name": value`, and `{}` / `[]` when empty. This is the layout of Dart's
    /// `JsonEncoder.withIndent('  ')`, which the other Payriff SDKs' logs use.
    var prettyPrinted: String {
        var output = ""
        writePretty(to: &output, level: 0)
        return output
    }

    private func writePretty(to output: inout String, level: Int) {
        switch self {
        case .array(let values) where !values.isEmpty:
            output += "["
            for (index, value) in values.enumerated() {
                output += index == 0 ? "\n" : ",\n"
                Self.indent(&output, level: level + 1)
                value.writePretty(to: &output, level: level + 1)
            }
            output += "\n"
            Self.indent(&output, level: level)
            output += "]"
        case .object(let members) where !members.isEmpty:
            output += "{"
            for (index, member) in members.enumerated() {
                output += index == 0 ? "\n" : ",\n"
                Self.indent(&output, level: level + 1)
                Self.writeString(member.0, to: &output)
                output += ": "
                member.1.writePretty(to: &output, level: level + 1)
            }
            output += "\n"
            Self.indent(&output, level: level)
            output += "}"
        default:
            write(to: &output)
        }
    }

    private static func indent(_ output: inout String, level: Int) {
        output += String(repeating: "  ", count: level)
    }

    private func write(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let literal):
            output += literal
        case .string(let value):
            Self.writeString(value, to: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                Self.writeString(member.0, to: &output)
                output += ":"
                member.1.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    output += String(format: "\\u%04X", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
