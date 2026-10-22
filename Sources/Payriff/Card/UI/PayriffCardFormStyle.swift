#if canImport(UIKit)
import UIKit

/// The look of ``PayriffCardForm``: fonts, colours, sizes and the layout (CONTRACT §16.4).
///
/// Every property has a default, and the defaults reproduce the card form of Payriff's hosted
/// payment page (pay.payriff.com, CONTRACT §16.14): a "Card holder" field, then one "Card
/// information" box with the card number on top and the expiry and the CVC side by side, in the
/// page's colours and sizes. Change only what you need:
///
/// ```swift
/// var style = PayriffCardFormStyle()
/// style.cornerRadius = 16
/// style.focusedBorderColor = .systemIndigo
/// style.labelTextStyle = .init(size: 13, weight: .bold, color: .secondaryLabel)
/// let form = PayriffCardForm(style: style)
/// ```
///
/// The default colours follow light and dark mode. Colours you set are used as they are; pass a
/// dynamic `UIColor` (a system colour or `UIColor(dynamicProvider:)`) to follow the appearance.
/// The default font is the system font; any font works, including Inter, which the page uses.
/// Fonts scale with Dynamic Type, and rows grow with them.
public struct PayriffCardFormStyle: Sendable, Equatable {
    /// A font and a colour for one kind of text in the form.
    public struct TextStyle: Sendable, Equatable {
        /// The font at the default text size. The form scales it with the customer's Dynamic
        /// Type setting.
        public var font: UIFont
        /// The colour, or `nil` for the form's default colour of this text.
        public var color: UIColor?

        /// A text style with any font, for example your app's own typeface.
        public init(font: UIFont, color: UIColor? = nil) {
            self.font = font
            self.color = color
        }

        /// A text style in the system font.
        public init(size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor? = nil) {
            self.init(font: .systemFont(ofSize: size, weight: weight), color: color)
        }
    }

    // MARK: Text and labels

    /// The titles above the sections ("Card holder", "Card information"), and above every field
    /// in the stacked layout. Defaults to 14 pt semibold; a `nil` colour is `#34363A`
    /// (`#E1E4E8` in dark mode).
    public var labelTextStyle: TextStyle

    /// What the customer types. Defaults to 14 pt regular; a `nil` colour is `#4D4F54`
    /// (`#8E8E93` in dark mode).
    public var inputTextStyle: TextStyle

    /// The placeholders (`Card holder`, `1234 1234 1234 1234`, `MM / YY`, `CVC`); they use the
    /// font of ``inputTextStyle``. Defaults to `#76787F` (`#5F6167` in dark mode).
    public var placeholderColor: UIColor

    /// The error lines. Defaults to 13 pt regular; a `nil` colour is ``errorColor``.
    public var errorTextStyle: TextStyle

    /// Whether the titles are shown. Defaults to `true`. Without them the fields keep their
    /// VoiceOver labels.
    public var showLabels: Bool

    /// The title above the cardholder name, or `nil` (the default) for the form's language:
    /// "Card holder", "Kart sahibinin adı", "Владелец карты".
    public var holderLabel: String?

    /// The title above the card box of the ``PayriffCardFormLayout/grouped`` layout, or `nil`
    /// (the default) for the form's language: "Card information", "Kart məlumatları",
    /// "Информация о карте".
    public var cardLabel: String?

    // MARK: Colours

    /// The background of the fields. Defaults to transparent: the fields show the background
    /// behind the form, as on the payment page.
    public var fieldBackgroundColor: UIColor

    /// The outlines, and the lines between the rows and cells of the card box. Defaults to
    /// `#ECEEF0`, and `#3F4145` in dark mode.
    public var borderColor: UIColor

    /// The outline of the section the customer is typing in, and the caret. Defaults to Payriff's
    /// brand colour `#4DBDC6`. `nil` uses the form's `tintColor`, your app's accent colour unless
    /// you set another.
    public var focusedBorderColor: UIColor?

    /// The outline of a section that shows an error, and the error text unless
    /// ``errorTextStyle`` has a colour. Defaults to `#EC4D3D` (`#EC5545` in dark mode).
    public var errorColor: UIColor

    // MARK: Sizes and spacing, in points

    /// The width of the outlines. Defaults to 1. The lines inside the card box are 1 point.
    public var borderWidth: CGFloat

    /// The corner radius of the boxes; the card box rounds its outer corners only. Defaults to 12.
    public var cornerRadius: CGFloat

    /// The height of the cardholder-name field, its outline included. Defaults to 46. It grows
    /// with large Dynamic Type sizes.
    public var holderHeight: CGFloat

    /// The height of a row of the card box: the number row and the expiry | CVC row (in the
    /// stacked layout, the number, expiry and CVV fields). Defaults to 40. A row's height
    /// includes its lines, and the rows of a box share the line between them, as on the payment
    /// page: the card box is 2 × 40 − 1 = 79 points tall. Rows grow with large Dynamic Type sizes.
    public var rowHeight: CGFloat

    /// The space between a box's edge and its text. Defaults to 14.
    public var horizontalPadding: CGFloat

    /// The space between a title and its box. Defaults to 10.
    public var labelSpacing: CGFloat

    /// The space between the holder section and the card section (in the stacked layout,
    /// between the rows of fields). Defaults to 16.
    public var sectionSpacing: CGFloat

    // MARK: Layout

    /// How the fields are arranged. Defaults to ``PayriffCardFormLayout/grouped``, the look of
    /// Payriff's hosted payment page.
    public var layout: PayriffCardFormLayout

    /// Creates a style. Every argument defaults to the look of Payriff's hosted payment page.
    public init(
        labelTextStyle: TextStyle = TextStyle(size: 14, weight: .semibold),
        inputTextStyle: TextStyle = TextStyle(size: 14),
        placeholderColor: UIColor = Defaults.placeholder,
        errorTextStyle: TextStyle = TextStyle(size: 13),
        showLabels: Bool = true,
        holderLabel: String? = nil,
        cardLabel: String? = nil,
        fieldBackgroundColor: UIColor = Defaults.fieldBackground,
        borderColor: UIColor = Defaults.border,
        focusedBorderColor: UIColor? = Defaults.focus,
        errorColor: UIColor = Defaults.error,
        borderWidth: CGFloat = 1,
        cornerRadius: CGFloat = 12,
        holderHeight: CGFloat = 46,
        rowHeight: CGFloat = 40,
        horizontalPadding: CGFloat = 14,
        labelSpacing: CGFloat = 10,
        sectionSpacing: CGFloat = 16,
        layout: PayriffCardFormLayout = .grouped
    ) {
        self.labelTextStyle = labelTextStyle
        self.inputTextStyle = inputTextStyle
        self.placeholderColor = placeholderColor
        self.errorTextStyle = errorTextStyle
        self.showLabels = showLabels
        self.holderLabel = holderLabel
        self.cardLabel = cardLabel
        self.fieldBackgroundColor = fieldBackgroundColor
        self.borderColor = borderColor
        self.focusedBorderColor = focusedBorderColor
        self.errorColor = errorColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.holderHeight = holderHeight
        self.rowHeight = rowHeight
        self.horizontalPadding = horizontalPadding
        self.labelSpacing = labelSpacing
        self.sectionSpacing = sectionSpacing
        self.layout = layout
    }

    /// The look of Payriff's hosted payment page; the same as `PayriffCardFormStyle()`.
    public static let `default` = PayriffCardFormStyle()

    /// The default colours of the payment page (CONTRACT §16.14), shared instances so that two
    /// default styles are equal.
    @usableFromInline
    enum Defaults {
        /// The titles: `#34363A`, dark `#E1E4E8`.
        @usableFromInline static let text = UIColor(light: 0x34363A, dark: 0xE1E4E8)
        /// What the customer types: `#4D4F54`, dark `#8E8E93`.
        @usableFromInline static let input = UIColor(light: 0x4D4F54, dark: 0x8E8E93)
        @usableFromInline static let placeholder = UIColor(light: 0x76787F, dark: 0x5F6167)
        @usableFromInline static let error = UIColor(light: 0xEC4D3D, dark: 0xEC5545)
        /// Transparent: the fields show the page background.
        @usableFromInline static let fieldBackground = UIColor.clear
        @usableFromInline static let border = UIColor(light: 0xECEEF0, dark: 0x3F4145)
        /// Payriff's brand colour.
        @usableFromInline static let focus = UIColor(rgb: 0x4DBDC6)
    }
}

extension UIColor {
    /// An opaque colour from `0xRRGGBB`.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A colour that is `light` in the light appearance and `dark` in the dark one, both
    /// `0xRRGGBB`.
    convenience init(light: UInt32, dark: UInt32) {
        let lightColor = UIColor(rgb: light)
        let darkColor = UIColor(rgb: dark)
        self.init { traits in traits.userInterfaceStyle == .dark ? darkColor : lightColor }
    }
}
#endif
