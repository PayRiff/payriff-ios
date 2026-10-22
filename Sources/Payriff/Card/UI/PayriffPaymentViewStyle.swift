#if canImport(UIKit)
import UIKit

/// The look of ``PayriffPaymentView`` and ``PayriffPaymentScreen`` (CONTRACT §16.14).
///
/// Every property has a default, and the defaults reproduce the card part of Payriff's hosted
/// payment page (pay.payriff.com) in the system font, in light and dark mode. Change only what you
/// need:
///
/// ```swift
/// var style = PayriffPaymentViewStyle()
/// style.buttonColor = .systemIndigo
/// style.buttonCornerRadius = 8
/// style.showPoweredBy = false
/// style.formStyle.cornerRadius = 8
///
/// let paymentView = PayriffPaymentView(orderId: orderId, clientSecret: clientSecret, style: style)
/// ```
///
/// Colours you set are used as they are; pass a dynamic `UIColor` (a system colour or
/// `UIColor(dynamicProvider:)`) to follow the appearance. Any font works, including Inter, which
/// the page uses; fonts scale with Dynamic Type.
public struct PayriffPaymentViewStyle: Sendable, Equatable {
    /// The background of the whole view. Defaults to `#FCFCFD`, and `#222224` in dark mode.
    public var backgroundColor: UIColor

    /// The space around the content. The view adds the safe area to it, and the part of the
    /// keyboard that covers the view. Defaults to 20 points on every side.
    public var padding: UIEdgeInsets

    /// The fill of the Pay button. Defaults to Payriff's brand colour `#4DBDC6`.
    public var buttonColor: UIColor

    /// The Pay button's title ("Pay 1.02 AZN"). Defaults to 16 pt semibold; a `nil` colour is
    /// white. The spinner shown while paying takes the same colour.
    public var buttonTextStyle: PayriffCardFormStyle.TextStyle

    /// The height of the Pay button. Defaults to 44; the button grows with large Dynamic Type
    /// sizes.
    public var buttonHeight: CGFloat

    /// The corner radius of the Pay button. Defaults to 16.
    public var buttonCornerRadius: CGFloat

    /// The colour of the "Proceed securely by PCI DSS" line and the "Powered by Payriff" footer.
    /// Defaults to `#76787F`.
    public var secondaryTextColor: UIColor

    /// Whether to show the Mastercard and Visa badges under the Pay button. Defaults to `true`.
    public var showBadges: Bool

    /// Whether to show the lock and "Proceed securely by PCI DSS". Defaults to `true`.
    public var showSecureNote: Bool

    /// Whether to show "Powered by" and the Payriff logo at the bottom. Defaults to `true`.
    public var showPoweredBy: Bool

    /// The card form inside the view (``PayriffCardForm/style``). Its error colour and error text
    /// style are also used for the view's error line under the Pay button. Set
    /// ``PayriffCardFormStyle/showLabels`` to `false` to hide "Card holder" and "Card
    /// information".
    public var formStyle: PayriffCardFormStyle

    /// Creates a style. Every argument defaults to the look of Payriff's hosted payment page.
    public init(
        backgroundColor: UIColor = Defaults.background,
        padding: UIEdgeInsets = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20),
        buttonColor: UIColor = Defaults.button,
        buttonTextStyle: PayriffCardFormStyle.TextStyle = PayriffCardFormStyle.TextStyle(size: 16, weight: .semibold),
        buttonHeight: CGFloat = 44,
        buttonCornerRadius: CGFloat = 16,
        secondaryTextColor: UIColor = Defaults.secondaryText,
        showBadges: Bool = true,
        showSecureNote: Bool = true,
        showPoweredBy: Bool = true,
        formStyle: PayriffCardFormStyle = PayriffCardFormStyle()
    ) {
        self.backgroundColor = backgroundColor
        self.padding = padding
        self.buttonColor = buttonColor
        self.buttonTextStyle = buttonTextStyle
        self.buttonHeight = buttonHeight
        self.buttonCornerRadius = buttonCornerRadius
        self.secondaryTextColor = secondaryTextColor
        self.showBadges = showBadges
        self.showSecureNote = showSecureNote
        self.showPoweredBy = showPoweredBy
        self.formStyle = formStyle
    }

    /// The look of Payriff's hosted payment page; the same as `PayriffPaymentViewStyle()`.
    public static let `default` = PayriffPaymentViewStyle()

    /// The default colours of the payment page (CONTRACT §16.14), shared instances so that two
    /// default styles are equal.
    @usableFromInline
    enum Defaults {
        /// The page: `#FCFCFD`, dark `#222224`.
        @usableFromInline static let background = UIColor(light: 0xFCFCFD, dark: 0x222224)
        /// Payriff's brand colour, also the form's focus colour.
        @usableFromInline static let button = PayriffCardFormStyle.Defaults.focus
        /// The secure line and the footer.
        @usableFromInline static let secondaryText = UIColor(rgb: 0x76787F)
        /// The Pay button's title and spinner.
        static let buttonText = UIColor.white
    }
}
#endif
