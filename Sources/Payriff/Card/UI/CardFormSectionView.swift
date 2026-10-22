#if canImport(UIKit)
import UIKit

/// One section of ``PayriffCardForm`` (CONTRACT §16.4): a title, one outlined box with the
/// section's fields, and one error line under the box that is hidden while there is no error.
///
/// The first field has a row of its own; the other fields share the next row in equal parts. Rows
/// and cells are separated by 1-point lines in the border colour, and only the box's outer
/// corners are rounded. In the grouped layout's card box this gives the number (with the brand
/// mark) on top, then expiry | CVC.
///
/// Heights (CONTRACT §16.14): a box with one row is ``PayriffCardFormStyle/holderHeight`` (the
/// holder) or ``PayriffCardFormStyle/rowHeight`` tall, its outline included. The rows of a box
/// with more than one row share the line between them, as on the payment page: every row is
/// `rowHeight` tall with its lines, so the card box is `2 × rowHeight − 1`.
@MainActor
final class CardFormSectionView: UIView {
    let section: CardFormSection
    let titleLabel = UILabel()
    let box = CardFormBox()
    let errorLabel = UILabel()
    /// The rows and cells of the box, one per field, in the section's order.
    private(set) var cells: [CardFieldCell] = []
    /// The lines between the rows and the cells.
    private(set) var dividers: [UIView] = []
    private let column = UIStackView()
    private var style = PayriffCardFormStyle.default

    /// The box's outline; its colour comes from the style.
    var outline = CardFormOutline.normal {
        didSet { if outline != oldValue { updateBorder() } }
    }

    /// The space between the box and the error line.
    static let errorSpacing: CGFloat = 6
    /// The width of the lines between the rows and the cells (CONTRACT §16.4: 1 point).
    static let dividerWidth: CGFloat = 1

    /// Builds the section around the form's text fields; the number's row also holds `brandMark`.
    init(section: CardFormSection, textFields: [PayriffCardField: CardTextField], brandMark: CardBrandMarkView) {
        self.section = section
        super.init(frame: .zero)

        cells = section.fields.compactMap { field in
            textFields[field].map { CardFieldCell(textField: $0, accessory: field == .number ? brandMark : nil) }
        }
        let content = UIStackView()
        content.axis = .vertical
        content.translatesAutoresizingMaskIntoConstraints = false
        if let first = cells.first { content.addArrangedSubview(first) }
        let shared = Array(cells.dropFirst())
        if let leading = shared.first {
            content.addArrangedSubview(makeDivider(between: .vertical))
            let row = UIStackView()
            row.axis = .horizontal
            for (index, cell) in shared.enumerated() {
                if index > 0 { row.addArrangedSubview(makeDivider(between: .horizontal)) }
                row.addArrangedSubview(cell)
            }
            content.addArrangedSubview(row)
            // Equal parts (CONTRACT §16.4: expiry and CVC 50/50).
            NSLayoutConstraint.activate(shared.dropFirst().map { $0.widthAnchor.constraint(equalTo: leading.widthAnchor) })
        }

        box.clipsToBounds = true
        box.layer.cornerCurve = .continuous
        box.addSubview(content)

        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        // Each field carries its own label for VoiceOver.
        titleLabel.isAccessibilityElement = false

        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.isHidden = true
        errorLabel.isAccessibilityElement = false

        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(titleLabel)
        column.addArrangedSubview(box)
        column.addArrangedSubview(errorLabel)
        column.setCustomSpacing(Self.errorSpacing, after: box)
        addSubview(column)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A line in the border colour between two rows (`.vertical`: stacked above each other) or
    /// two cells (`.horizontal`: side by side).
    private func makeDivider(between axis: NSLayoutConstraint.Axis) -> UIView {
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        let thickness = axis == .vertical ? divider.heightAnchor : divider.widthAnchor
        thickness.constraint(equalToConstant: Self.dividerWidth).isActive = true
        dividers.append(divider)
        return divider
    }

    func apply(_ style: PayriffCardFormStyle) {
        self.style = style
        titleLabel.font = Self.scaledFont(style.labelTextStyle.font, relativeTo: .subheadline)
        titleLabel.textColor = style.labelTextStyle.color ?? PayriffCardFormStyle.Defaults.text
        titleLabel.isHidden = !style.showLabels
        column.setCustomSpacing(style.labelSpacing, after: titleLabel)
        errorLabel.font = Self.scaledFont(style.errorTextStyle.font, relativeTo: .footnote)
        errorLabel.textColor = style.errorTextStyle.color ?? style.errorColor
        box.backgroundColor = style.fieldBackgroundColor
        box.layer.cornerRadius = style.cornerRadius
        box.layer.borderWidth = style.borderWidth
        let height = rowHeight(in: style)
        for cell in cells { cell.apply(style, height: height) }
        for divider in dividers { divider.backgroundColor = style.borderColor }
        updateBorder()
    }

    /// The minimum height of each row of the box (its cells), without the lines between rows.
    func rowHeight(in style: PayriffCardFormStyle) -> CGFloat {
        guard cells.count == 1, let field = cells.first?.textField.field else {
            // The rows share the line between them: a row and that line are `rowHeight` tall.
            return max(0, style.rowHeight - Self.dividerWidth)
        }
        return field == .holder ? style.holderHeight : style.rowHeight
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
    }

    /// Shows `message` under the box, or hides the line.
    ///
    /// - Returns: Whether the line changed, so the form's height may have.
    @discardableResult
    func setError(_ message: String?) -> Bool {
        guard errorLabel.text != message || errorLabel.isHidden != (message == nil) else { return false }
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        errorLabel.isAccessibilityElement = message != nil
        return true
    }

    /// The colour of the box's outline now.
    var outlineColor: UIColor {
        switch outline {
        case .normal: return style.borderColor
        case .focused: return style.focusedBorderColor ?? tintColor
        case .error: return style.errorColor
        }
    }

    private func updateBorder() {
        box.borderUIColor = outlineColor
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateBorder()
    }

    /// `font` scaled with Dynamic Type like `textStyle`.
    static func scaledFont(_ font: UIFont, relativeTo textStyle: UIFont.TextStyle) -> UIFont {
        UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font)
    }
}

/// A row or cell of a section's box: one text field between the style's horizontal padding, at
/// least the row's height tall, with an optional trailing accessory (the brand mark). A tap
/// anywhere in the row, also beside the text, edits its field.
@MainActor
final class CardFieldCell: UIView, UIGestureRecognizerDelegate {
    let textField: CardTextField
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var minimumHeight: NSLayoutConstraint!

    /// The space between the text field and the accessory.
    static let accessorySpacing: CGFloat = 8

    init(textField: CardTextField, accessory: UIView?) {
        self.textField = textField
        super.init(frame: .zero)
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        leading = textField.leadingAnchor.constraint(equalTo: leadingAnchor)
        minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        var constraints: [NSLayoutConstraint] = [
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading,
            minimumHeight,
        ]
        if let accessory {
            // The brand's mark on the trailing side (CONTRACT §16.4); its size is its own.
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            trailing = trailingAnchor.constraint(equalTo: accessory.trailingAnchor)
            constraints += [
                accessory.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: Self.accessorySpacing),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailing,
            ]
        } else {
            trailing = trailingAnchor.constraint(equalTo: textField.trailingAnchor)
            constraints.append(trailing)
        }
        NSLayoutConstraint.activate(constraints)
        let tap = UITapGestureRecognizer(target: self, action: #selector(focusField))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    /// Edits the row's field, unless the form is locked.
    @objc func focusField() {
        guard textField.isEnabled, !textField.isFirstResponder else { return }
        textField.becomeFirstResponder()
    }

    /// Taps on the text field itself stay with the text field (caret, selection, edit menu).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view?.isDescendant(of: textField) ?? false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ style: PayriffCardFormStyle, height: CGFloat) {
        leading.constant = style.horizontalPadding
        trailing.constant = style.horizontalPadding
        minimumHeight.constant = height
    }
}

/// The outlined box of a section. Its border colour follows light and dark mode.
@MainActor
final class CardFormBox: UIView {
    var borderUIColor: UIColor = PayriffCardFormStyle.Defaults.border {
        didSet { resolveBorderColor() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (box: CardFormBox, _: UITraitCollection) in
                box.resolveBorderColor()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIKit lays views out again when the appearance changes.
        resolveBorderColor()
    }

    /// A layer's border colour is a `CGColor`: resolve the dynamic colour for the current traits.
    private func resolveBorderColor() {
        layer.borderColor = borderUIColor.resolvedColor(with: traitCollection).cgColor
    }
}
#endif
