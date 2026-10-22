import CoreGraphics
import Foundation
import Testing
@testable import Payriff

/// The geometry of the brand marks in the number field (CONTRACT §16.4), without UIKit.
@Suite("Card brand marks")
struct CardBrandMarkTests {
    static func isClose(_ value: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        abs(value - expected) <= tolerance
    }

    @Test("The Visa path data parses into 45 absolute commands carrying 71 points")
    func visaCommands() throws {
        #expect(CardBrandMark.visaPathData.count == 970, "the contract's data, one line")
        #expect(!CardBrandMark.visaPathData.contains("\n"))
        let commands = try #require(CardBrandMark.parsePathData(CardBrandMark.visaPathData))
        #expect(commands.count == 45)
        var counts: [String: Int] = [:]
        for command in commands {
            switch command {
            case .move: counts["M", default: 0] += 1
            case .line: counts["L", default: 0] += 1
            case .curve: counts["C", default: 0] += 1
            case .close: counts["Z", default: 0] += 1
            }
        }
        // Five subpaths: V, S, the outside and the hole of A, and I; S is left open.
        #expect(counts == ["M": 5, "L": 21, "C": 15, "Z": 4])
        #expect(commands.reduce(0) { $0 + $1.points.count } == 71)
        #expect(commands.first == .move(CGPoint(x: 9.112, y: 8.262)))
        #expect(commands[4] == .curve(CGPoint(x: 2.28, y: 9.407), CGPoint(x: 2.199, y: 9.272), CGPoint(x: 1.913, y: 9.117)))
        #expect(commands.last == .close)
    }

    @Test("The wordmark spans x 0…24 and y 8.124…15.875 of its box; in the badge it is 26 wide and centred")
    func visaBounds() throws {
        let wordmark = try #require(CardBrandMark.visaWordmark())
        let bounds = wordmark.boundingBoxOfPath
        #expect(Self.isClose(bounds.minX, 0) && Self.isClose(bounds.maxX, 24))
        #expect(Self.isClose(bounds.minY, 8.124) && Self.isClose(bounds.maxY, 15.875))
        let size = CardBrandMark.badgeSize
        #expect(size == CGSize(width: 36, height: 24))
        let placed = bounds.applying(CardBrandMark.visaTransform(bounds: bounds, in: size))
        #expect(Self.isClose(placed.width, 26))
        #expect(Self.isClose(placed.height, 7.751 * 26 / 24))
        #expect(Self.isClose(placed.midX, 18) && Self.isClose(placed.midY, 12))
        #expect(CGRect(origin: .zero, size: size).contains(placed))
        // With the non-zero rule the hole of the "A" stays empty (it winds the other way), and
        // the "I" is filled.
        #expect(!wordmark.contains(CGPoint(x: 20.9, y: 12.5), using: .winding))
        #expect(wordmark.contains(CGPoint(x: 9.5, y: 12), using: .winding))
    }

    @Test("Mastercard: circles of radius 0.309 × 26 at 0.309 and 0.691 of the centred mark; the overlap is their lens")
    func mastercard() {
        let size = CardBrandMark.badgeSize
        let (left, right) = CardBrandMark.mastercardCircles(in: size)
        let radius = 0.309 * 26
        #expect(Self.isClose(left.width / 2, radius) && Self.isClose(right.width / 2, radius))
        #expect(Self.isClose(left.midX, 5 + 0.309 * 26) && Self.isClose(right.midX, 5 + 0.691 * 26))
        #expect(Self.isClose(right.midX - left.midX, 0.382 * 26))
        #expect(Self.isClose(left.minX, 5) && Self.isClose(right.maxX, 31), "26 wide, centred in the 36-point badge")
        #expect(Self.isClose(left.midY, 12) && Self.isClose(right.midY, 12))

        // Arcs are drawn as Bézier curves, so their bounds are compared loosely.
        let lens = CardBrandMark.mastercardOverlap(in: size).boundingBoxOfPath
        let halfChord = (radius * radius - pow(0.191 * 26, 2)).squareRoot()
        #expect(Self.isClose(lens.minX, right.minX, tolerance: 0.01) && Self.isClose(lens.maxX, left.maxX, tolerance: 0.01))
        #expect(Self.isClose(lens.minY, 12 - halfChord, tolerance: 0.01) && Self.isClose(lens.maxY, 12 + halfChord, tolerance: 0.01))
        #expect(CardBrandMark.mastercardOverlap(in: size).contains(CGPoint(x: 18, y: 12)))
        #expect(!CardBrandMark.mastercardOverlap(in: size).contains(CGPoint(x: left.midX, y: 12)))
    }

    @Test("Colours and badge (CONTRACT §16.4)")
    func colours() {
        #expect(CardBrandMark.Color.badge == 0xFFFFFF)
        #expect(CardBrandMark.Color.border == 0xD1D1D6)
        #expect(CardBrandMark.Color.visa == 0x1A1F71)
        #expect(CardBrandMark.Color.mastercardLeft == 0xEB001B)
        #expect(CardBrandMark.Color.mastercardRight == 0xF79E1B)
        #expect(CardBrandMark.Color.mastercardOverlap == 0xFF5F00)
        #expect(CardBrandMark.cornerRadius == 4 && CardBrandMark.borderWidth == 1 && CardBrandMark.markWidth == 26)
        #expect(CardBrandMark.crossFadeDuration <= 0.15)
        let card = CardBrandMark.outlineCard(in: CardBrandMark.badgeSize)
        #expect(card == CGRect(x: 3, y: 2, width: 30, height: 20))
    }

    @Test("The parser reads absolute M/L/C/Z only and refuses everything else")
    func parser() {
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: y) }
        #expect(CardBrandMark.parsePathData("M1 2 L3.5 -4 C1,2 3,4 5,6 Z") == [
            .move(point(1, 2)), .line(point(3.5, -4)), .curve(point(1, 2), point(3, 4), point(5, 6)), .close,
        ])
        #expect(CardBrandMark.parsePathData("M1 2L3 4Z") == [.move(point(1, 2)), .line(point(3, 4)), .close])
        #expect(CardBrandMark.parsePathData("") == [])
        #expect(CardBrandMark.parsePathData("  \n ") == [])
        let refused = [
            "L1 2",              // no M first
            "m1 2",              // relative
            "M1 2 H3",           // another command
            "M1",                // a missing number
            "M1 2 C1 2 3 4 5",   // an incomplete curve
            "M1 2 3 4",          // implicit commands
            "M1 2 Lx 4",         // not a number
            "M1 2 Linf 4",       // not finite
            "M1 2 Z 5",          // a number without a command
        ]
        for data in refused {
            #expect(CardBrandMark.parsePathData(data) == nil, "\(data)")
        }
        let path = CardBrandMark.path([.move(point(0, 0)), .line(point(10, 0)), .line(point(10, 5)), .close])
        #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 5))
    }
}
