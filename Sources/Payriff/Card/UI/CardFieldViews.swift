#if canImport(UIKit)
import UIKit

/// A text field of the card form with the input security of CONTRACT §16.5:
/// - no autocorrection, spell checking, smart punctuation, inline predictions or writing tools;
/// - AutoFill hints for the number, the expiry and the holder only;
/// - the number allows paste but never copy, cut, share or drag; the CVV allows none of them and
///   is masked.
@MainActor
final class CardTextField: UITextField {
    let field: PayriffCardField

    init(field: PayriffCardField) {
        self.field = field
        super.init(frame: .zero)
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocapitalizationType = field == .holder ? .allCharacters : .none
        if #available(iOS 17.0, *) {
            inlinePredictionType = .no
        }
        if #available(iOS 18.0, *) {
            writingToolsBehavior = .none
        }
        switch field {
        case .number:
            keyboardType = .numberPad
            textContentType = .creditCardNumber
        case .expiry:
            keyboardType = .numberPad
            if #available(iOS 17.0, *) {
                textContentType = .creditCardExpiration
            }
        case .cvv:
            keyboardType = .numberPad
            // Masked, and never offered to AutoFill or the password manager.
            textContentType = nil
            isSecureTextEntry = true
        case .holder:
            keyboardType = .default
            if #available(iOS 17.0, *) {
                textContentType = .creditCardName
            } else {
                textContentType = .name
            }
        }
        if field == .number || field == .cvv {
            // Dragging the text out would copy it.
            textDragInteraction?.isEnabled = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// UIKit's description of a text field includes its text (`text = '…'`); this one never does,
    /// so `print`, `dump(form)`, the debugger and view-hierarchy dumps show no card data.
    override var description: String {
        "<\(type(of: self)): \(Unmanaged.passUnretained(self).toOpaque()); field = \(field.rawValue); text = <redacted>>"
    }

    override var debugDescription: String { description }

    /// The edit-menu actions the field allows. The number allows paste (and Live Text input);
    /// the CVV allows only selection.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch field {
        case .number:
            let allowed: [Selector] = [
                #selector(UIResponderStandardEditActions.paste(_:)),
                #selector(UIResponderStandardEditActions.select(_:)),
                #selector(UIResponderStandardEditActions.selectAll(_:)),
                #selector(UIResponder.captureTextFromCamera(_:)),
            ]
            return allowed.contains(action) && super.canPerformAction(action, withSender: sender)
        case .cvv:
            let allowed: [Selector] = [
                #selector(UIResponderStandardEditActions.select(_:)),
                #selector(UIResponderStandardEditActions.selectAll(_:)),
            ]
            return allowed.contains(action) && super.canPerformAction(action, withSender: sender)
        case .expiry, .holder:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) {
        guard field != .number, field != .cvv else { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard field != .number, field != .cvv else { return }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        guard field != .cvv else { return }
        super.paste(sender)
    }
}

/// The brand of the number field as its mark (CONTRACT §16.4, geometry in
/// ``CardBrandMark``): the Visa wordmark or the Mastercard circles on a 36×24 white badge, or a
/// neutral card outline while the brand is unknown. A change cross-fades in 150 ms. VoiceOver
/// reads "Visa" or "Mastercard"; the outline is not read.
@MainActor
final class CardBrandMarkView: UIView {
    /// What the view shows.
    enum Mark: CaseIterable {
        case visa
        case mastercard
        /// The neutral card outline of an unknown brand.
        case outline

        init(_ brand: PayriffCardBrand?) {
            switch brand {
            case .visa: self = .visa
            case .mastercard: self = .mastercard
            case nil: self = .outline
            }
        }
    }

    var brand: PayriffCardBrand? {
        didSet {
            guard brand != oldValue else { return }
            accessibilityLabel = Self.accessibilityName(brand)
            isAccessibilityElement = brand != nil
            showMark(animated: window != nil)
        }
    }

    /// The mark currently shown (or fading in).
    private(set) var visibleMark = Mark.outline

    private let markViews: [Mark: CardBrandMarkLayerView]

    override init(frame: CGRect) {
        markViews = Dictionary(uniqueKeysWithValues: Mark.allCases.map { ($0, CardBrandMarkLayerView(mark: $0)) })
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityTraits = .image
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        for mark in Mark.allCases {
            guard let view = markViews[mark] else { continue }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.alpha = mark == visibleMark ? 1 : 0
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize { CardBrandMark.badgeSize }

    private static func accessibilityName(_ brand: PayriffCardBrand?) -> String? {
        switch brand {
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case nil: return nil
        }
    }

    /// Cross-fades to the brand's mark: the old one fades out while the new one fades in.
    private func showMark(animated: Bool) {
        visibleMark = Mark(brand)
        guard animated else {
            applyVisibleMark()
            return
        }
        UIView.animate(
            withDuration: CardBrandMark.crossFadeDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) { [weak self] in
            self?.applyVisibleMark()
        }
    }

    private func applyVisibleMark() {
        for (mark, view) in markViews {
            view.alpha = mark == visibleMark ? 1 : 0
        }
    }
}

/// One mark of ``CardBrandMarkView``, drawn in the 36×24 badge at the screen's scale.
@MainActor
private final class CardBrandMarkLayerView: UIView {
    let mark: CardBrandMarkView.Mark

    /// The Visa wordmark in its 24-unit box, parsed once.
    private static let visaWordmark = CardBrandMark.visaWordmark()

    init(mark: CardBrandMarkView.Mark) {
        self.mark = mark
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        let size = CardBrandMark.badgeSize
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        guard let context = UIGraphicsGetCurrentContext(), scale > 0 else { return }
        context.translateBy(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        switch mark {
        case .visa:
            drawBadge(in: context, size: size)
            guard let wordmark = Self.visaWordmark else { return }
            context.saveGState()
            context.concatenate(CardBrandMark.visaTransform(bounds: wordmark.boundingBoxOfPath, in: size))
            context.addPath(wordmark)
            context.setFillColor(UIColor(rgb: CardBrandMark.Color.visa).cgColor)
            context.fillPath(using: .winding)
            context.restoreGState()
        case .mastercard:
            drawBadge(in: context, size: size)
            let circles = CardBrandMark.mastercardCircles(in: size)
            context.setFillColor(UIColor(rgb: CardBrandMark.Color.mastercardLeft).cgColor)
            context.fillEllipse(in: circles.left)
            context.setFillColor(UIColor(rgb: CardBrandMark.Color.mastercardRight).cgColor)
            context.fillEllipse(in: circles.right)
            context.addPath(CardBrandMark.mastercardOverlap(in: size))
            context.setFillColor(UIColor(rgb: CardBrandMark.Color.mastercardOverlap).cgColor)
            context.fillPath()
        case .outline:
            // The placeholder grey of the light or dark appearance; UIKit calls `draw(_:)` again
            // when the appearance changes.
            let color = UIColor.systemGray2.resolvedColor(with: traitCollection).cgColor
            let card = CardBrandMark.outlineCard(in: size)
            context.setStrokeColor(color)
            context.setLineWidth(CardBrandMark.outlineLineWidth)
            context.addPath(CGPath(roundedRect: card, cornerWidth: CardBrandMark.cornerRadius, cornerHeight: CardBrandMark.cornerRadius, transform: nil))
            context.strokePath()
            context.setLineWidth(CardBrandMark.outlineStripeWidth)
            context.move(to: CGPoint(x: card.minX, y: card.minY + CardBrandMark.outlineStripeOffset))
            context.addLine(to: CGPoint(x: card.maxX, y: card.minY + CardBrandMark.outlineStripeOffset))
            context.strokePath()
        }
    }

    /// The white badge with its 1-point border inside the edge; white in dark mode too.
    private func drawBadge(in context: CGContext, size: CGSize) {
        let radius = CardBrandMark.cornerRadius
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(UIColor(rgb: CardBrandMark.Color.badge).cgColor)
        context.fillPath()
        let inset = CardBrandMark.borderWidth / 2
        let border = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        context.addPath(CGPath(roundedRect: border, cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil))
        context.setStrokeColor(UIColor(rgb: CardBrandMark.Color.border).cgColor)
        context.setLineWidth(CardBrandMark.borderWidth)
        context.strokePath()
    }
}
#endif
