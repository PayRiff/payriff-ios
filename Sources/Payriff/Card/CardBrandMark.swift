import CoreGraphics
import Foundation

/// The card brand's mark in the number field (CONTRACT §16.4): a 36×24 white badge with
/// a 1-point `#D1D1D6` border and 4-point corners holding the Visa wordmark or the Mastercard
/// circles, 26 points wide and centred, or a neutral card outline while the brand is unknown.
///
/// The geometry is free of UIKit, so `swift test` checks it on a Mac; ``CardBrandMarkView`` draws it.
enum CardBrandMark {
    /// The badge, in points.
    static let badgeSize = CGSize(width: 36, height: 24)
    /// The badge's corner radius.
    static let cornerRadius: CGFloat = 4
    /// The width of the badge's border.
    static let borderWidth: CGFloat = 1
    /// The width of a mark inside the badge.
    static let markWidth: CGFloat = 26
    /// How long a change of mark cross-fades (at most 150 ms).
    static let crossFadeDuration: TimeInterval = 0.15

    /// The colours, as `0xRRGGBB`. The badge stays white in dark mode, as card marks do.
    enum Color {
        static let badge: UInt32 = 0xFFFFFF
        static let border: UInt32 = 0xD1D1D6
        static let visa: UInt32 = 0x1A1F71
        static let mastercardLeft: UInt32 = 0xEB001B
        static let mastercardRight: UInt32 = 0xF79E1B
        static let mastercardOverlap: UInt32 = 0xFF5F00
    }

    // MARK: - Visa

    /// The Visa wordmark in a 24-unit box, from Simple Icons (CC0): absolute M/L/C/Z commands
    /// only, exactly as in CONTRACT §16.4.
    static let visaPathData = """
        M9.112 8.262 L5.97 15.758 L3.92 15.758 L2.374 9.775 C2.28 9.407 2.199 9.272 1.913 \
        9.117 C1.447 8.864 0.677 8.627 0 8.479 L0.046 8.262 L3.346 8.262 C3.792 8.262 4.171 \
        8.586 4.24 9.026 L5.057 13.364 L7.075 8.262 Z \
        M17.145 13.311 C17.153 11.332 14.409 11.223 14.428 10.339 C14.434 10.07 14.69 9.784 \
        15.25 9.711 C15.906 9.649 16.567 9.765 17.163 10.047 L17.503 8.457 C16.923 8.239 \
        16.309 8.126 15.689 8.124 C13.772 8.124 12.423 9.144 12.411 10.603 C12.399 11.682 \
        13.374 12.283 14.109 12.643 C14.865 13.01 15.119 13.246 15.115 13.574 C15.11 14.078 \
        14.513 14.299 13.955 14.308 C12.98 14.323 12.415 14.045 11.963 13.835 L11.612 15.477 \
        C12.065 15.685 12.901 15.867 13.768 15.875 C15.805 15.875 17.138 14.869 17.145 \
        13.311 \
        M22.206 15.758 L24 15.758 L22.435 8.262 L20.779 8.262 C20.417 8.259 20.09 8.477 \
        19.953 8.812 L17.044 15.758 L19.08 15.758 L19.485 14.638 L21.973 14.638 Z \
        M20.043 13.102 L21.063 10.287 L21.651 13.102 Z \
        M11.883 8.262 L10.28 15.758 L8.34 15.758 L9.945 8.262 Z
        """

    /// The side of the box ``visaPathData`` is drawn in.
    static let visaBoxSize: CGFloat = 24

    /// The Visa wordmark in its 24-unit box, filled with the non-zero rule (the hole of the "A"
    /// winds the other way). `nil` only if ``visaPathData`` could not be parsed, which a test rules out.
    static func visaWordmark() -> CGPath? {
        parsePathData(visaPathData).map(path(_:))
    }

    /// Maps the wordmark into a badge of `size`: scaled from its 24-unit box to ``markWidth``
    /// and centred on its own bounds (`bounds`, the wordmark's `boundingBoxOfPath`).
    static func visaTransform(bounds: CGRect, in size: CGSize) -> CGAffineTransform {
        let scale = markWidth / visaBoxSize
        return CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
            ty: (size.height - bounds.height * scale) / 2 - bounds.minY * scale
        )
    }

    // MARK: - Mastercard

    /// The two circles in a badge of `size`: radius `0.309 × w`, centred at `x = 0.309 × w` and
    /// `x = 0.691 × w` of the centred mark (`w` = ``markWidth``), so `0.382 × w` apart.
    static func mastercardCircles(in size: CGSize) -> (left: CGRect, right: CGRect) {
        let radius = 0.309 * markWidth
        let originX = (size.width - markWidth) / 2
        let centerY = size.height / 2
        func circle(centerX: CGFloat) -> CGRect {
            CGRect(x: centerX - radius, y: centerY - radius, width: 2 * radius, height: 2 * radius)
        }
        return (circle(centerX: originX + 0.309 * markWidth), circle(centerX: originX + 0.691 * markWidth))
    }

    /// Where the circles overlap (the `#FF5F00` lens): the right arc of the left circle and the
    /// left arc of the right circle, between the circles' two intersection points.
    static func mastercardOverlap(in size: CGSize) -> CGPath {
        let (left, right) = mastercardCircles(in: size)
        let radius = left.width / 2
        let halfDistance = (right.midX - left.midX) / 2
        let angle = acos(min(1, halfDistance / radius))
        let path = CGMutablePath()
        // Angles grow from +x towards +y; `clockwise: false` goes the way they grow.
        path.addArc(center: CGPoint(x: left.midX, y: left.midY), radius: radius, startAngle: -angle, endAngle: angle, clockwise: false)
        path.addArc(center: CGPoint(x: right.midX, y: right.midY), radius: radius, startAngle: .pi - angle, endAngle: .pi + angle, clockwise: false)
        path.closeSubpath()
        return path
    }

    // MARK: - Unknown brand

    /// The neutral outline while the brand is unknown: a 30×20 card with 4-point corners, drawn
    /// with a 1.5-point line, and a 3-point magnetic stripe 6 points below its top.
    static func outlineCard(in size: CGSize) -> CGRect {
        CGRect(x: (size.width - 30) / 2, y: (size.height - 20) / 2, width: 30, height: 20)
    }

    static let outlineLineWidth: CGFloat = 1.5
    static let outlineStripeWidth: CGFloat = 3
    static let outlineStripeOffset: CGFloat = 6

    // MARK: - Path data

    /// One command of absolute SVG path data.
    enum PathCommand: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        /// A cubic Bézier curve: two control points, then the end point.
        case curve(CGPoint, CGPoint, CGPoint)
        case close

        /// The points the command carries.
        var points: [CGPoint] {
            switch self {
            case .move(let point), .line(let point): return [point]
            case .curve(let control1, let control2, let end): return [control1, control2, end]
            case .close: return []
            }
        }
    }

    /// Parses absolute SVG path data made of `M`, `L`, `C` and `Z` commands, with numbers
    /// separated by white space or commas. Returns `nil` for anything else: another or a relative
    /// command, a missing, malformed or non-finite number, or data that does not start with `M`.
    static func parsePathData(_ data: String) -> [PathCommand]? {
        var tokens: [String] = []
        var token = ""
        for character in data {
            if character.isWhitespace || character == "," {
                if !token.isEmpty { tokens.append(token) }
                token = ""
            } else if "MLCZ".contains(character) {
                if !token.isEmpty { tokens.append(token) }
                tokens.append(String(character))
                token = ""
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { tokens.append(token) }

        var commands: [PathCommand] = []
        var index = 0
        func number() -> CGFloat? {
            guard index < tokens.count, let value = Double(tokens[index]), value.isFinite else { return nil }
            index += 1
            return CGFloat(value)
        }
        func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            if commands.isEmpty, command != "M" { return nil }
            switch command {
            case "M":
                guard let point = point() else { return nil }
                commands.append(.move(point))
            case "L":
                guard let point = point() else { return nil }
                commands.append(.line(point))
            case "C":
                guard let control1 = point(), let control2 = point(), let end = point() else { return nil }
                commands.append(.curve(control1, control2, end))
            case "Z":
                commands.append(.close)
            default:
                return nil
            }
        }
        return commands
    }

    /// The path of parsed commands.
    static func path(_ commands: [PathCommand]) -> CGPath {
        let path = CGMutablePath()
        for command in commands {
            switch command {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .curve(let control1, let control2, let end): path.addCurve(to: end, control1: control1, control2: control2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}
