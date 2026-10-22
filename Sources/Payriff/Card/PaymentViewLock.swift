import CoreGraphics

/// The lock before the "secure" line of ``PayriffPaymentView`` (CONTRACT §16.14): a padlock the
/// SDK draws itself, a shackle over a rounded body with a keyhole dot.
///
/// Points are in a square of side `s`, with y pointing down. The geometry is free of UIKit, so
/// `swift test` checks it on a Mac; `PaymentViewLockView` draws it.
enum PaymentViewLock {
    /// The side of the square, in points.
    static let side: CGFloat = 15
    /// The colour of the lines and the keyhole, `0xRRGGBB`, in light and dark mode.
    static let color: UInt32 = 0x56BE3D

    /// The width of the lines: `0.085 × s`, drawn with round caps and joins.
    static func lineWidth(side s: CGFloat = side) -> CGFloat {
        0.085 * s
    }

    /// The shackle and the body, stroked. The shackle goes up from (0.32, 0.45) to (0.32, 0.31),
    /// over the top in a half circle of radius 0.18 around (0.5, 0.31), and down to (0.68, 0.45).
    /// The body is a rectangle from (0.17, 0.45) to (0.83, 0.92) with corners of radius 0.13. All
    /// values are multiples of `s`.
    static func outline(side s: CGFloat = side) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.32 * s, y: 0.45 * s))
        path.addLine(to: CGPoint(x: 0.32 * s, y: 0.31 * s))
        // Angles grow from +x towards +y, and y points down: from π (left) through 3π/2 (top)
        // to 2π (right).
        path.addArc(center: CGPoint(x: 0.5 * s, y: 0.31 * s), radius: 0.18 * s, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        path.addLine(to: CGPoint(x: 0.68 * s, y: 0.45 * s))
        let body = CGRect(x: 0.17 * s, y: 0.45 * s, width: (0.83 - 0.17) * s, height: (0.92 - 0.45) * s)
        path.addRoundedRect(in: body, cornerWidth: 0.13 * s, cornerHeight: 0.13 * s)
        return path
    }

    /// The keyhole, filled: a circle of radius 0.075 around (0.5, 0.665), in multiples of `s`.
    static func keyhole(side s: CGFloat = side) -> CGPath {
        let radius = 0.075 * s
        let circle = CGRect(x: 0.5 * s - radius, y: 0.665 * s - radius, width: 2 * radius, height: 2 * radius)
        return CGPath(ellipseIn: circle, transform: nil)
    }
}
