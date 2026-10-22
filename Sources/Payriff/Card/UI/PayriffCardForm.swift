#if canImport(UIKit)
import UIKit

/// Payriff's native card form (CONTRACT §16.4): the cardholder name, then the card number (at most
/// 16 digits) with the brand's mark, the expiry and the CVC. ``showsHolder`` can hide the
/// cardholder name.
///
/// By default it looks like the card form of Payriff's hosted payment page: the cardholder name
/// first, then one "Card information" box with the number on top and the expiry and the CVC side
/// by side, with one error line under each. ``style`` changes the fonts, colours, sizes and the
/// layout (``PayriffCardFormStyle``).
///
/// Pay with ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)``. The form never exposes
/// what the customer typed: values leave the SDK only encrypted, ``onChange`` reports validity,
/// errors and the brand only, and the values are cleared after a final result.
///
/// ```swift
/// let form = PayriffCardForm()
/// form.onChange = { change in payButton.isEnabled = change.isComplete }
/// view.addSubview(form)
///
/// let result = await Payriff.confirmCardPayment(form, orderId: orderId, clientSecret: clientSecret)
/// ```
///
/// Input security (CONTRACT §16.5): numeric keyboards; no autocorrection, suggestions or inline
/// predictions; AutoFill hints for the number, the expiry and the holder only; the number and
/// the CVV cannot be copied, cut or dragged; the CVV is masked. While the app is inactive (app
/// switcher, Control Center) an opaque cover hides the form, so snapshots show no card data.
/// The form follows the system light and dark appearance and Dynamic Type.
@MainActor
public final class PayriffCardForm: UIView {
    /// Whether the form has a cardholder-name field. `true` by default, as on Payriff's hosted
    /// payment page. Without it, the name is sent as `Unknown`.
    public let showsHolder: Bool

    /// The language of the labels, placeholders and errors. `nil` uses
    /// ``PayriffConfig/language``, then the device language.
    public var language: PayriffLanguage? {
        didSet { applyLanguage() }
    }

    /// Whether focus moves number → expiry → CVV when a field becomes valid while typing at its
    /// end. Defaults to `true`.
    public var autoAdvance = true

    /// The look of the form: fonts, colours, sizes and the layout (CONTRACT §16.4). Defaults to
    /// the card form of Payriff's hosted payment page. A new style applies at once; a new
    /// ``PayriffCardFormStyle/layout`` rearranges the fields and keeps what the customer typed.
    public var style: PayriffCardFormStyle {
        didSet {
            guard style != oldValue else { return }
            if style.layout != oldValue.layout { buildSections() }
            applyStyle()
        }
    }

    /// Called on the main actor when a field's validity, visible error or brand changes, and when
    /// focus changes. It never carries field values.
    public var onChange: (@MainActor (PayriffCardFormChange) -> Void)?

    /// Whether every field is valid.
    public var isComplete: Bool { model.isComplete }

    /// The brand of the number typed so far.
    public var brand: PayriffCardBrand? { model.brand }

    /// Whether a payment is running; the form is locked and shows progress meanwhile.
    public private(set) var isProcessing = false

    /// Whether the form dims itself and shows a spinner while a payment runs. ``PayriffPaymentView``
    /// turns it off: its Pay button shows the progress, and the form is only locked.
    var showsProcessingOverlay = true

    private var model: CardFormModel
    private var textFields: [PayriffCardField: CardTextField] = [:]
    private let brandMark = CardBrandMarkView()
    /// The sections, top to bottom and leading to trailing.
    private(set) var sectionViews: [CardFormSectionView] = []
    private let stack = UIStackView()
    private let processingOverlay = UIView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var lastChanges: [PayriffCardField: PayriffCardFormChange] = [:]
    private var privacyCover: PrivacyCoverView?
    private var observers: [any NSObjectProtocol] = []

    /// The space between sections side by side (the stacked layout's expiry and CVV).
    static let columnSpacing: CGFloat = 12

    /// Creates a card form.
    ///
    /// - Parameters:
    ///   - showsHolder: Whether to show the cardholder-name field. Defaults to `true`, as on
    ///     Payriff's hosted payment page. Pass `false` to hide it; the name is then sent as `Unknown`.
    ///   - language: The form's language, or `nil` for the configured or device language.
    ///   - style: The form's look. Defaults to the card form of Payriff's hosted payment page.
    public init(showsHolder: Bool = true, language: PayriffLanguage? = nil, style: PayriffCardFormStyle = PayriffCardFormStyle()) {
        self.showsHolder = showsHolder
        self.language = language
        self.style = style
        self.model = CardFormModel(showsHolder: showsHolder, language: language ?? .en)
        super.init(frame: .zero)
        buildViews()
        buildSections()
        applyLanguage()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Public actions

    /// Clears every field, the errors and the "payment attempted" state.
    public func clear() {
        model.clear()
        for textField in textFields.values { textField.text = "" }
        for field in model.fields { render(field) }
        for field in model.fields { emitChange(field) }
    }

    /// Moves focus to `field`.
    ///
    /// - Returns: Whether the field became first responder.
    @discardableResult
    public func focus(_ field: PayriffCardField = .number) -> Bool {
        textFields[field]?.becomeFirstResponder() ?? false
    }

    // MARK: - SDK interface

    /// Step 1 of a card payment (CONTRACT §16.7): shows every error and returns the card, or the
    /// invalid fields.
    func collectForPayment() -> Result<CardDetails, CardFieldIssues> {
        applyLanguage()
        let result = model.collect()
        for field in model.fields {
            render(field)
            emitChange(field)
        }
        if case .failure(let failure) = result {
            // VoiceOver announces the error nearest the top of the form.
            let order = style.layout.visualOrder(showsHolder: showsHolder)
            let position = { (issue: PayriffCardFieldIssue) in order.firstIndex(of: issue.field) ?? order.count }
            if let first = failure.issues.min(by: { position($0) < position($1) }) {
                UIAccessibility.post(notification: .announcement, argument: first.message)
            }
        }
        return result
    }

    /// Locks the form and shows progress while a payment runs.
    func setProcessing(_ processing: Bool) {
        isProcessing = processing
        if processing { endEditing(true) }
        for textField in textFields.values { textField.isEnabled = !processing }
        let showsOverlay = processing && showsProcessingOverlay
        processingOverlay.isHidden = !showsOverlay
        if showsOverlay {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        accessibilityElementsHidden = false
        guard showsProcessingOverlay else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: processing ? activityIndicator : nil)
    }

    /// The payment ended. Values are cleared after a final result: every result except a
    /// non-fatal failure the customer can fix or retry (CONTRACT §16.5).
    func paymentDidFinish(_ result: PayriffResult) {
        setProcessing(false)
        if case .failed(let error) = result, !error.isFatal { return }
        clear()
    }

    /// The form's effective language.
    var effectiveLanguage: PayriffLanguage {
        language ?? Payriff.configuration?.language ?? Payriff.services.deviceLanguage()
    }

    // MARK: - Layout

    private func buildViews() {
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for field in model.fields {
            let textField = CardTextField(field: field)
            textField.borderStyle = .none
            textField.adjustsFontForContentSizeCategory = true
            textField.delegate = self
            textField.addAction(UIAction { [weak self] _ in self?.textDidChange(field) }, for: .editingChanged)
            textField.addAction(UIAction { [weak self] _ in self?.focusDidChange(field, focused: true) }, for: .editingDidBegin)
            textField.addAction(UIAction { [weak self] _ in self?.focusDidChange(field, focused: false) }, for: .editingDidEnd)
            textFields[field] = textField
        }
        brandMark.translatesAutoresizingMaskIntoConstraints = false

        processingOverlay.translatesAutoresizingMaskIntoConstraints = false
        processingOverlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
        processingOverlay.isHidden = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        processingOverlay.addSubview(activityIndicator)
        addSubview(processingOverlay)

        NSLayoutConstraint.activate([
            brandMark.widthAnchor.constraint(equalToConstant: CardBrandMark.badgeSize.width),
            brandMark.heightAnchor.constraint(equalToConstant: CardBrandMark.badgeSize.height),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            processingOverlay.topAnchor.constraint(equalTo: topAnchor),
            processingOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            processingOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            processingOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: processingOverlay.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: processingOverlay.centerYAnchor),
        ])
    }

    /// Arranges the fields in the sections of ``PayriffCardFormStyle/layout`` (CONTRACT §16.4).
    /// The text fields, and what they hold, stay; only their containers are new.
    private func buildSections() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        sectionViews = []
        for row in style.layout.rows(showsHolder: showsHolder) {
            let views = row.map { CardFormSectionView(section: $0, textFields: textFields, brandMark: brandMark) }
            sectionViews += views
            if views.count == 1, let only = views.first {
                stack.addArrangedSubview(only)
            } else {
                let columns = UIStackView(arrangedSubviews: views)
                columns.axis = .horizontal
                columns.spacing = Self.columnSpacing
                columns.distribution = .fillEqually
                columns.alignment = .top
                stack.addArrangedSubview(columns)
            }
        }
    }

    private func applyLanguage() {
        model.strings = CardStrings(language: effectiveLanguage)
        applyTexts()
        for field in model.fields { render(field) }
    }

    private func applyStyle() {
        stack.spacing = style.sectionSpacing
        let font = CardFormSectionView.scaledFont(style.inputTextStyle.font, relativeTo: .body)
        for textField in textFields.values {
            textField.font = font
            textField.textColor = style.inputTextStyle.color ?? PayriffCardFormStyle.Defaults.input
            // `nil` inherits the tint colour, the app's accent.
            textField.tintColor = style.focusedBorderColor
        }
        for section in sectionViews { section.apply(style) }
        applyTexts()
        for field in model.fields { render(field) }
    }

    /// The titles, the placeholders and the VoiceOver labels: the form's language, and the
    /// style's titles and placeholder colour.
    private func applyTexts() {
        for (field, textField) in textFields {
            textField.accessibilityLabel = label(of: field)
            textField.attributedPlaceholder = NSAttributedString(
                string: model.strings.placeholder(field),
                attributes: [.foregroundColor: style.placeholderColor]
            )
        }
        for section in sectionViews {
            switch section.section.title {
            case .cardInformation: section.setTitle(style.cardLabel ?? model.strings.cardInformation)
            case .field(let field): section.setTitle(label(of: field))
            }
        }
        invalidateIntrinsicContentSize()
    }

    /// The field's label: the title above it in the stacked layout, and its VoiceOver label.
    private func label(of field: PayriffCardField) -> String {
        field == .holder ? style.holderLabel ?? model.strings.label(.holder) : model.strings.label(field)
    }

    // MARK: - Events

    private func textDidChange(_ field: PayriffCardField) {
        // Edits that bypass the delegate (AutoFill) are formatted here, and so is every holder
        // edit, which the system keyboard applies itself.
        guard textFields[field] != nil else { return }
        syncText(field)
        render(field)
        emitChange(field)
    }

    /// Formats what the field shows into the model and shows the result. The holder is
    /// upper-cased (CONTRACT §16.4), but not while the keyboard composes text (marked text):
    /// replacing the text would break the composition. Its caret stays where it was unless
    /// upper-casing changed the length (`ß` → `SS`); then it goes to the end.
    private func syncText(_ field: PayriffCardField) {
        guard let textField = textFields[field] else { return }
        let text = textField.text ?? ""
        guard text != model.text(field) else { return }
        let formatted = model.setText(field, text)
        guard formatted != text else { return }
        guard field == .holder else {
            textField.text = formatted
            return
        }
        guard textField.markedTextRange == nil else { return }
        let caret = textField.selectedTextRange.map { textField.offset(from: textField.beginningOfDocument, to: $0.end) } ?? (text as NSString).length
        textField.text = formatted
        let offset = CardFormModel.holderCaret(caret, from: text, to: formatted)
        if let position = textField.position(from: textField.beginningOfDocument, offset: offset) {
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }
    }

    private func focusDidChange(_ field: PayriffCardField, focused: Bool) {
        // A composition the keyboard committed without an edit event is upper-cased on blur.
        if !focused, field == .holder { syncText(field) }
        model.setFocused(field, focused)
        render(field)
        emitChange(field)
    }

    /// Shows the field's state: its VoiceOver hint, the brand mark, and its section's error line
    /// and outline (CONTRACT §16.4).
    private func render(_ field: PayriffCardField) {
        guard let textField = textFields[field] else { return }
        textField.accessibilityHint = model.visibleError(field).map { model.strings.message(field, $0) }
        if field == .number { brandMark.brand = model.brand }
        for section in sectionViews where section.section.fields.contains(field) {
            // A shown or hidden error line changes the form's height (SwiftUI asks again).
            if section.setError(model.sectionError(section.section)?.message) { invalidateIntrinsicContentSize() }
            section.outline = model.outline(section.section)
        }
    }

    private func emitChange(_ field: PayriffCardField) {
        let change = model.change(field)
        guard lastChanges[field] != change else { return }
        lastChanges[field] = change
        onChange?(change)
    }

    // MARK: - Screen protection (CONTRACT §16.0 item 4)

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        hidePrivacyCover()
        guard window != nil else { return }
        applyLanguage()
        let center = NotificationCenter.default
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIScene
                MainActor.assumeIsolated { self?.sceneWillDeactivate(scene) }
            })
        }
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] notification in
            let scene = notification.object as? UIScene
            MainActor.assumeIsolated { self?.sceneDidActivate(scene) }
        })
    }

    private func isOwnScene(_ scene: AnyObject?) -> Bool {
        guard let scene, let own = window?.windowScene else { return true }
        return scene === own
    }

    /// Covers the form while its scene is inactive, so app-switcher snapshots show no card data.
    func sceneWillDeactivate(_ scene: AnyObject?) {
        guard isOwnScene(scene), privacyCover == nil else { return }
        privacyCover = PrivacyCoverView.cover(self)
    }

    func sceneDidActivate(_ scene: AnyObject?) {
        guard isOwnScene(scene) else { return }
        hidePrivacyCover()
    }

    private func hidePrivacyCover() {
        privacyCover?.removeFromSuperview()
        privacyCover = nil
    }

    /// Whether the privacy cover is shown (tests).
    var isShowingPrivacyCover: Bool { privacyCover != nil }

    /// The text field of `field` (tests).
    func textField(for field: PayriffCardField) -> UITextField? { textFields[field] }

    /// The brand mark of the number field (tests).
    var brandMarkView: CardBrandMarkView? { textFields[.number] == nil ? nil : brandMark }

    /// The section that holds `field` (tests).
    func sectionView(containing field: PayriffCardField) -> CardFormSectionView? {
        sectionViews.first { $0.section.fields.contains(field) }
    }

    /// The section of the field being edited, or `nil`; ``PayriffPaymentView`` keeps it above the
    /// keyboard.
    var focusedSectionView: CardFormSectionView? {
        guard let field = textFields.first(where: { $0.value.isFirstResponder })?.key else { return nil }
        return sectionView(containing: field)
    }
}

// MARK: - UITextFieldDelegate

extension PayriffCardForm: UITextFieldDelegate {
    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let textField = textField as? CardTextField, !isProcessing else { return false }
        let field = textField.field
        if field == .holder {
            // The system keyboard edits the name (marked text, autocorrection off) and `textDidChange`
            // upper-cases it; the length cap counts the upper-cased name.
            let current = (textField.text ?? "") as NSString
            guard range.location + range.length <= current.length else { return false }
            let proposed = current.replacingCharacters(in: range, with: string)
            return CardFormatting.formatHolder(proposed).utf16.count <= CardValidation.maxHolderLength
        }
        // Keep the model in sync with what the field shows before applying the edit.
        if (textField.text ?? "") != model.text(field) { _ = model.setText(field, textField.text ?? "") }
        guard let edit = model.edit(field, range: range, replacement: string) else { return false }
        textField.text = edit.text
        if let position = textField.position(from: textField.beginningOfDocument, offset: edit.caret) {
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }
        render(field)
        emitChange(field)
        if edit.advance, autoAdvance, let next = model.nextField(after: field) {
            textFields[next]?.becomeFirstResponder()
        }
        return false
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

#endif
