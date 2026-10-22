import CoreGraphics
import Foundation
import Testing
@testable import Payriff

/// The rules of the payment view (CONTRACT §16.14) without UIKit: the Pay title, when Pay is
/// enabled, the error line, the copy and the images.
@Suite("Payment view rules")
struct PaymentViewStateTests {
    private static func order(
        amount: String? = "1.02",
        currency: String? = "AZN",
        status: PayriffPaymentStatus = .created,
        methods: [String] = ["CARD", "APPLE_PAY"]
    ) -> PayriffClientOrder {
        PayriffClientOrder(
            orderId: "o1",
            amount: amount.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) },
            currency: currency,
            status: status,
            paymentMethods: methods
        )
    }

    private static func state(_ language: PayriffLanguage = .en) -> PaymentViewState {
        PaymentViewState(strings: CardStrings(language: language))
    }

    @Test("The Pay title is view.pay while the order loads, then the amount with two decimals and the currency")
    func payTitle() {
        var state = Self.state()
        #expect(state.payTitle == "Pay")
        #expect(state.orderDidLoad(.success(Self.order())) == nil)
        #expect(state.payTitle == "Pay 1.02 AZN")
        state.strings = CardStrings(language: .az)
        #expect(state.payTitle == "Ödə 1.02 AZN")
        state.strings = CardStrings(language: .ru)
        #expect(state.payTitle == "Оплатить 1.02 AZN")

        // An order that cannot be paid still shows its amount; a missing amount or currency is left out.
        var other = Self.state()
        _ = other.orderDidLoad(.success(Self.order(amount: "10.5", currency: " usd ", status: .approved)))
        #expect(other.payTitle == "Pay 10.50 usd")
        _ = other.orderDidLoad(.success(Self.order(currency: nil)))
        #expect(other.payTitle == "Pay 1.02")
        _ = other.orderDidLoad(.success(Self.order(amount: nil)))
        #expect(other.payTitle == "Pay")
        _ = other.orderDidLoad(.failure(PayriffError(code: .networkError, message: "offline")))
        #expect(other.payTitle == "Pay")
    }

    @Test(
        "Amounts: two decimals, '.' as the separator, no grouping, rounded half up",
        arguments: [
            ("1.02", "1.02"), ("10.5", "10.50"), ("1234", "1234.00"), ("1234567.891", "1234567.89"),
            ("0.005", "0.01"), ("1.004", "1.00"), ("0", "0.00"), ("0.1", "0.10"),
        ]
    )
    func amounts(input: String, expected: String) throws {
        let amount = try #require(Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")))
        #expect(PaymentViewState.amountText(amount) == expected)
    }

    @Test("Pay is enabled only for a payable order with a complete form while no payment runs")
    func payEnabled() {
        var state = Self.state()
        state.isFormComplete = true
        #expect(!state.isPayEnabled, "the order is loading")
        _ = state.orderDidLoad(.success(Self.order()))
        #expect(state.isPayEnabled)
        state.isFormComplete = false
        #expect(!state.isPayEnabled, "the form is incomplete")
        state.isFormComplete = true
        state.paymentWillStart()
        #expect(state.isPaying)
        #expect(!state.isPayEnabled, "a payment runs")

        for order in [
            Self.order(status: .approved),
            Self.order(status: .declined),
            Self.order(methods: ["APPLE_PAY", "GOOGLE_PAY"]),
            Self.order(methods: []),
        ] {
            var notPayable = Self.state()
            notPayable.isFormComplete = true
            _ = notPayable.orderDidLoad(.success(order))
            #expect(!notPayable.isPayEnabled)
            #expect(notPayable.errorMessage == "This order cannot be paid by card")
            #expect(!notPayable.needsOrder)
        }
        var pending = Self.state()
        pending.isFormComplete = true
        _ = pending.orderDidLoad(.success(Self.order(status: .pending)))
        #expect(pending.isPayEnabled, "PENDING can be paid too")
        #expect(pending.errorMessage == nil)
    }

    @Test("An order that cannot be paid by card shows view.notPayable in the view's language")
    func notPayableLine() {
        var state = Self.state(.az)
        _ = state.orderDidLoad(.success(Self.order(status: .approved)))
        #expect(state.errorMessage == "Bu sifarişi kartla ödəmək mümkün deyil")
        state.strings = CardStrings(language: .ru)
        #expect(state.errorMessage == "Этот заказ нельзя оплатить картой", "a new language applies at once")
        state.strings = CardStrings(language: .en)
        #expect(state.errorMessage == "This order cannot be paid by card")
        for language in PayriffLanguage.allCases {
            state.strings = CardStrings(language: language)
            #expect(state.errorMessage == state.strings.view(.notPayable), "\(language)")
        }

        // An error without a message, from loading the order or from a payment, gets the same line.
        var blank = Self.state(.ru)
        _ = blank.orderDidLoad(.failure(PayriffError(code: .unknown, message: "")))
        #expect(blank.errorMessage == "Этот заказ нельзя оплатить картой")
        var paid = Self.state(.az)
        _ = paid.orderDidLoad(.success(Self.order()))
        paid.paymentWillStart()
        paid.paymentDidFinish(.failed(PayriffError(code: .orderNotPayable, message: " ")))
        #expect(paid.errorMessage == "Bu sifarişi kartla ödəmək mümkün deyil")
        paid.strings = CardStrings(language: .en)
        #expect(paid.errorMessage == "This order cannot be paid by card")
    }

    @Test("A failed load shows its message under the button; a fatal error is reported once and not loaded again")
    func loadErrors() {
        var state = Self.state()
        state.isFormComplete = true
        #expect(state.needsOrder)
        #expect(state.errorMessage == nil, "nothing while loading")

        let offline = PayriffError(code: .networkError, message: "The Internet connection appears to be offline.", isRetryable: true)
        #expect(state.orderDidLoad(.failure(offline)) == nil, "not fatal: not reported")
        #expect(state.errorMessage == offline.message)
        #expect(!state.isPayEnabled)
        #expect(state.needsOrder, "loaded again when the view appears again")

        let blank = PayriffError(code: .unknown, message: "  ")
        _ = state.orderDidLoad(.failure(blank))
        #expect(state.errorMessage == "This order cannot be paid by card", "an error without a message")

        let expired = PayriffError(code: .sessionExpired, message: "Order not found", httpStatus: 404, isFatal: true)
        #expect(state.orderDidLoad(.failure(expired)) == .failed(expired))
        #expect(state.reportedFatalError)
        #expect(state.errorMessage == "Order not found")
        #expect(!state.needsOrder, "a fatal error ends the order")
        #expect(state.orderDidLoad(.failure(expired)) == nil, "reported once")

        state.orderWillLoad()
        #expect(state.order == .loading && state.errorMessage == nil)
        #expect(state.orderDidLoad(.failure(expired)) == nil, "still once for the same order")
        state.orderDidChange()
        #expect(state.orderDidLoad(.failure(expired)) == .failed(expired), "a new order reports its own fatal error")
    }

    @Test("After a payment: a status ends the view's payments; a fatal error or ORDER_NOT_PAYABLE goes under the button; other failures keep Pay")
    func paymentResults() {
        func paid(_ result: PayriffResult) -> PaymentViewState {
            var state = Self.state()
            _ = state.orderDidLoad(.success(Self.order()))
            state.isFormComplete = true
            state.paymentWillStart()
            state.paymentDidFinish(result)
            #expect(!state.isPaying)
            return state
        }
        let payment = PayriffPayment(orderId: "o1", status: .approved)
        for result in [
            PayriffResult.success(payment),
            .declined(PayriffPayment(orderId: "o1", status: .declined)),
            .cancelled(PayriffPayment(orderId: "o1", status: .canceled), reason: .canceled),
            .pending(PayriffPayment(orderId: "o1", status: .pending), reason: .notFinal),
        ] {
            let state = paid(result)
            #expect(state.isFinished, "\(result.type)")
            #expect(!state.isPayEnabled, "\(result.type): the order is not paid twice")
            #expect(state.errorMessage == nil)
        }
        for error in [
            PayriffError(code: .paymentFailed, message: "Insufficient funds", isRetryable: true),
            PayriffError(code: .validationFailed, message: "The card details are not valid: cvv."),
            PayriffError(code: .networkError, message: "offline", isRetryable: true),
            PayriffError(code: .paymentInProgress, message: "busy"),
        ] {
            let state = paid(.failed(error))
            #expect(!state.isFinished)
            #expect(state.isPayEnabled, "\(error.code): the customer may try again")
            #expect(state.errorMessage == nil)
        }
        let notPayable = paid(.failed(PayriffError(code: .orderNotPayable, message: "The order cannot be paid by card (status PAID, payment methods CARD).")))
        #expect(!notPayable.isPayEnabled)
        #expect(notPayable.errorMessage == "The order cannot be paid by card (status PAID, payment methods CARD).")
        #expect(!notPayable.reportedFatalError)

        var expired = paid(.failed(PayriffError(code: .sessionExpired, message: "Order not found", isFatal: true)))
        #expect(!expired.isPayEnabled)
        #expect(expired.errorMessage == "Order not found")
        #expect(expired.reportedFatalError, "onResult already had it")
        #expect(expired.orderDidLoad(.failure(PayriffError(code: .sessionExpired, message: "Order not found", isFatal: true))) == nil)

        // Reading the order again starts over.
        var again = paid(.success(payment))
        again.orderWillLoad()
        #expect(!again.isFinished && again.errorMessage == nil)
        _ = again.orderDidLoad(.success(Self.order()))
        again.isFormComplete = true
        #expect(again.isPayEnabled)
    }

    @Test("view.poweredBy splits at 'Payriff', where the logo goes, in az, en and ru")
    func poweredBySplit() throws {
        let en = try #require(CardStrings(language: .en).poweredByParts)
        #expect(en.before == "Powered by " && en.after == "")
        let az = try #require(CardStrings(language: .az).poweredByParts)
        #expect(az.before == "" && az.after == " tərəfindən hazırlanıb")
        let ru = try #require(CardStrings(language: .ru).poweredByParts)
        #expect(ru.before == "При поддержке " && ru.after == "")
        for language in PayriffLanguage.allCases {
            let strings = CardStrings(language: language)
            let parts = try #require(strings.poweredByParts)
            #expect(parts.before + CardStrings.logoWord + parts.after == strings.view(.poweredBy))
        }
        #expect(CardStrings(language: .en).view(.secure) == "Proceed securely by PCI DSS")
        #expect(CardStrings(language: .az).view(.secure) == "PCI DSS ilə təhlükəsiz ödəniş")
        #expect(CardStrings(language: .ru).view(.secure) == "Безопасная оплата по PCI DSS")
    }

    // MARK: - Images

    /// The width and height in the IHDR chunk of a PNG file (any chunk order, so also Xcode's
    /// iPhone-optimized PNGs).
    private static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        func uint32(_ at: Int) -> Int {
            bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = uint32(offset)
            if bytes[offset + 4..<offset + 8].elementsEqual(Array("IHDR".utf8)), offset + 16 <= bytes.count {
                return (uint32(offset + 8), uint32(offset + 12))
            }
            offset += 12 + length
        }
        return nil
    }

    @Test("The badges and the logo ship in the SDK's bundle at 1x, 2x and 3x, at their sizes in points (CONTRACT §16.14)")
    func imagesResolve() throws {
        #expect(PaymentViewAsset.badges == [.mastercard, .visa], "only the accepted cards, no PCI logo")
        let sizes: [PaymentViewAsset: (Int, Int)] = [
            .mastercard: (43, 28), .visa: (42, 28), .payriffLogo: (82, 16),
        ]
        #expect(Set(sizes.keys) == Set(PaymentViewAsset.allCases))
        for asset in PaymentViewAsset.allCases {
            let points = try #require(sizes[asset])
            #expect(asset.size == CGSize(width: points.0, height: points.1), "\(asset)")
            for scale in 1...3 {
                let name = scale == 1 ? asset.name : "\(asset.name)@\(scale)x"
                let url = try #require(PayriffResources.bundle.url(forResource: name, withExtension: "png"), "\(name).png")
                let size = try #require(Self.pngSize(try Data(contentsOf: url)), "\(name).png is a PNG")
                #expect(size.width == points.0 * scale && size.height == points.1 * scale, "\(name).png")
            }
        }
        #expect(PaymentViewAsset.payriffLogo.accessibilityLabel == "Payriff")
        #expect(PaymentViewAsset(rawValue: "lock") == nil, "the lock is drawn in code")
    }

    private static func isClose(_ value: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        abs(value - expected) <= tolerance
    }

    @Test("The lock of the secure line is drawn in code: a shackle over a rounded body and a keyhole, 15 points, #56BE3D")
    func lock() {
        let s = PaymentViewLock.side
        #expect(s == 15)
        #expect(PaymentViewLock.color == 0x56BE3D)
        #expect(Self.isClose(PaymentViewLock.lineWidth(), 0.085 * s))

        // The body spans 0.17…0.83 across and ends at 0.92. The shackle's half circle goes over
        // the top, up to 0.31 − 0.18 = 0.13; one that went down would leave the top at 0.31.
        let outline = PaymentViewLock.outline()
        let bounds = outline.boundingBoxOfPath
        #expect(Self.isClose(bounds.minX, 0.17 * s) && Self.isClose(bounds.maxX, 0.83 * s))
        #expect(Self.isClose(bounds.minY, 0.13 * s) && Self.isClose(bounds.maxY, 0.92 * s))
        // The shackle rises from the body's top edge at 0.32 and comes down to it at 0.68.
        let stroked = outline.copy(strokingWithWidth: PaymentViewLock.lineWidth(), lineCap: .round, lineJoin: .round, miterLimit: 10)
        for point in [CGPoint(x: 0.32, y: 0.45), CGPoint(x: 0.32, y: 0.31), CGPoint(x: 0.5, y: 0.13), CGPoint(x: 0.68, y: 0.31), CGPoint(x: 0.68, y: 0.45)] {
            #expect(stroked.contains(CGPoint(x: point.x * s, y: point.y * s)), "the shackle passes \(point)")
        }
        // The body's corners are rounded with a radius of 0.13: the sharp corner stays empty.
        #expect(!stroked.contains(CGPoint(x: 0.17 * s, y: 0.92 * s)))
        #expect(stroked.contains(CGPoint(x: 0.17 * s, y: 0.68 * s)) && stroked.contains(CGPoint(x: 0.5 * s, y: 0.92 * s)))
        // With its lines, the lock fits its square.
        #expect(CGRect(x: 0, y: 0, width: s, height: s).contains(stroked.boundingBoxOfPath))

        let keyhole = PaymentViewLock.keyhole().boundingBoxOfPath
        #expect(Self.isClose(keyhole.midX, 0.5 * s) && Self.isClose(keyhole.midY, 0.665 * s))
        #expect(Self.isClose(keyhole.width, 0.15 * s) && Self.isClose(keyhole.height, 0.15 * s))
    }

    @Test("SwiftPM and CocoaPods ship the same images, where the SDK looks for them")
    func imagesArePackaged() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".process("Resources/PaymentView")"#))
        let podspec = try String(contentsOf: root.appendingPathComponent("Payriff.podspec"), encoding: .utf8)
        #expect(podspec.contains("'Payriff_PaymentView' => ['Sources/Payriff/Resources/PaymentView/*.png']"))
        let lookup = try String(contentsOf: root.appendingPathComponent("Sources/Payriff/Card/PaymentViewAssets.swift"), encoding: .utf8)
        #expect(lookup.contains(#"url(forResource: "Payriff_PaymentView", withExtension: "bundle")"#), "the pod's bundle name")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/Payriff/Resources/PaymentView").path)
        let expected = PaymentViewAsset.allCases.flatMap { asset in ["", "@2x", "@3x"].map { "\(asset.name)\($0).png" } }
        #expect(Set(files.filter { !$0.hasPrefix(".") }) == Set(expected))
    }
}
