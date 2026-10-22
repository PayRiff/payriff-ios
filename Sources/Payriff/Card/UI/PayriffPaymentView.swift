#if canImport(UIKit) && canImport(WebKit)
import UIKit

/// Payriff's ready-made card payment screen (CONTRACT §16.14), like the card part of Payriff's
/// hosted payment page (pay.payriff.com). In SwiftUI use ``PayriffPaymentScreen``.
///
/// It shows ``PayriffCardForm``, a Pay button with the order's amount ("Pay 1.02 AZN"), the
/// Mastercard and Visa badges, "Proceed securely by PCI DSS" and "Powered by Payriff", on the
/// page's background. When it appears it reads the order with
/// ``Payriff/retrieveOrder(orderId:clientSecret:)``. Pay runs
/// ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)`` and passes the result to
/// ``onResult``.
///
/// The Pay button is disabled while the order loads, when the order cannot be paid by card or did
/// not load (an error line under the button says why), while the form is incomplete and while
/// paying; a spinner replaces its title meanwhile. A fatal error, such as an expired client
/// secret, also goes to ``onResult``, once.
///
/// Give it the whole screen: it adds the safe area to its padding, scrolls when the keyboard is up
/// and keeps the footer at the bottom when there is room. Call ``Payriff/configure(_:)`` first.
///
/// ```swift
/// let paymentView = PayriffPaymentView(orderId: orderId, clientSecret: clientSecret) { [weak self] result in
///     self?.show(result)   // fulfil the order on your server
/// }
/// paymentView.frame = view.bounds
/// paymentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
/// view.addSubview(paymentView)
/// ```
///
/// ``PayriffPaymentViewStyle`` changes the colours and sizes and hides the badges, the secure line,
/// the footer or the form's labels. ``PayriffCardForm`` and
/// ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)`` remain available to build your own
/// screen.
@available(iOSApplicationExtension, unavailable)
@MainActor
public final class PayriffPaymentView: UIView {
    /// The id of the order this view pays, from your server.
    public private(set) var orderId: String
    private var clientSecret: String

    /// The language of the view and its form. `nil` uses ``PayriffConfig/language``, then the
    /// device language.
    public var language: PayriffLanguage? {
        didSet {
            guard language != oldValue else { return }
            form.language = language
            applyTexts()
        }
    }

    /// The look of the view and of its form. A new style applies at once and keeps what the
    /// customer typed.
    public var style: PayriffPaymentViewStyle {
        didSet {
            guard style != oldValue else { return }
            applyStyle()
        }
    }

    /// Called on the main actor with the result of each payment attempt, and once with a fatal
    /// error that ends the order (``PayriffError/isFatal``), for example an expired client secret.
    /// The result drives your UI only: fulfil the order after your server confirms it.
    public var onResult: (@MainActor (PayriffResult) -> Void)?

    /// The view controller that presents the 3-D Secure sheet. `nil`, the default, uses the
    /// top-most view controller of the view's window.
    public weak var presenter: UIViewController?

    // MARK: - Parts (internal for tests)

    let form: PayriffCardForm
    let payButton = PaymentViewPayButton()
    /// Why the order cannot be paid, under the Pay button; hidden while there is no reason.
    let errorLabel = UILabel()
    /// The Mastercard and Visa badges, centred.
    let badgesView = UIView()
    let badgesRow = UIStackView()
    /// The lock and "Proceed securely by PCI DSS", centred.
    let secureView = UIView()
    let lockView = PaymentViewLockView()
    let secureLabel = UILabel()
    /// "Powered by" with the Payriff logo in place of the word "Payriff".
    let poweredByLabel = UILabel()
    let scrollView = UIScrollView()
    private let contentView = UIView()
    private let contentStack = UIStackView()

    /// The order, the form and the payment, and the rules for what the view shows.
    private(set) var state: PaymentViewState

    private var loadTask: Task<Void, Never>?
    /// Bumped for every order load, so a stale answer is dropped.
    private var loadGeneration = 0
    /// How much of the view the keyboard covers, from the bottom.
    private(set) var keyboardOverlap: CGFloat = 0
    private var keyboardObservers: [any NSObjectProtocol] = []

    private var stackTop: NSLayoutConstraint!
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    private var stackBottom: NSLayoutConstraint!
    private var footerLeading: NSLayoutConstraint!
    private var footerTrailing: NSLayoutConstraint!
    private var footerTop: NSLayoutConstraint!
    private var footerBottom: NSLayoutConstraint!
    private var minimumHeight: NSLayoutConstraint!
    private var fittingHeight: NSLayoutConstraint!

    // MARK: - Metrics (CONTRACT §16.14)

    /// Between the form and the Pay button, and above the badges.
    static let sectionSpacing: CGFloat = 24
    /// Between the Pay button and the error line.
    static let errorSpacing: CGFloat = 8
    /// Between the badges and the secure line.
    static let secureSpacing: CGFloat = 20
    /// The least space above the footer.
    static let footerSpacing: CGFloat = 24
    /// Between two badges.
    static let badgeSpacing: CGFloat = 8
    /// Between the lock and its text.
    static let lockSpacing: CGFloat = 6
    /// The size of the secure line and the footer: 12 pt regular, scaled with Dynamic Type.
    static let secondaryFontSize: CGFloat = 12

    /// Creates the payment view for an order your server created.
    ///
    /// - Parameters:
    ///   - orderId: The order's id.
    ///   - clientSecret: The order's client secret (`pr_cs_…`).
    ///   - language: The language of the view, or `nil` for the configured or device language.
    ///   - style: The look. Defaults to the card part of Payriff's hosted payment page.
    ///   - onResult: Called with each payment's result, and once with a fatal error; see
    ///     ``onResult``.
    public init(
        orderId: String,
        clientSecret: String,
        language: PayriffLanguage? = nil,
        style: PayriffPaymentViewStyle = PayriffPaymentViewStyle(),
        onResult: (@MainActor (PayriffResult) -> Void)? = nil
    ) {
        self.orderId = orderId
        self.clientSecret = clientSecret
        self.language = language
        self.style = style
        self.onResult = onResult
        form = PayriffCardForm(showsHolder: true, language: language, style: style.formStyle)
        state = PaymentViewState(strings: CardStrings(language: language ?? .en))
        super.init(frame: .zero)
        // The Pay button shows the progress; the form is only locked.
        form.showsProcessingOverlay = false
        buildViews()
        applyStyle()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PayriffPaymentView, _: UITraitCollection) in
                view.applyTexts()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func buildViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // The view pads the safe area and the keyboard itself (updateInsets).
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        addSubview(scrollView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.isHidden = true

        badgesRow.axis = .horizontal
        badgesRow.alignment = .center
        badgesRow.spacing = Self.badgeSpacing
        badgesRow.translatesAutoresizingMaskIntoConstraints = false
        for asset in PaymentViewAsset.badges { badgesRow.addArrangedSubview(Self.imageView(asset)) }
        badgesView.addSubview(badgesRow)

        secureLabel.numberOfLines = 0
        secureLabel.textAlignment = .center
        secureLabel.adjustsFontForContentSizeCategory = true
        let secureRow = UIStackView(arrangedSubviews: [lockView, secureLabel])
        secureRow.axis = .horizontal
        secureRow.alignment = .center
        secureRow.spacing = Self.lockSpacing
        secureRow.translatesAutoresizingMaskIntoConstraints = false
        secureView.addSubview(secureRow)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for part in [form, payButton, errorLabel, badgesView, secureView] { contentStack.addArrangedSubview(part) }
        contentView.addSubview(contentStack)

        poweredByLabel.numberOfLines = 0
        poweredByLabel.textAlignment = .center
        poweredByLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(poweredByLabel)

        payButton.addAction(UIAction { [weak self] _ in self?.pay() }, for: .touchUpInside)
        form.onChange = { [weak self] _ in self?.formDidChange() }

        let frame = scrollView.frameLayoutGuide
        let content = scrollView.contentLayoutGuide
        stackTop = contentStack.topAnchor.constraint(equalTo: contentView.topAnchor)
        stackLeading = contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        stackTrailing = contentView.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor)
        stackBottom = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor)
        footerLeading = poweredByLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        footerTrailing = contentView.trailingAnchor.constraint(equalTo: poweredByLabel.trailingAnchor)
        // The footer goes to the bottom when there is room, else 24 below the content.
        footerTop = poweredByLabel.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: Self.footerSpacing)
        footerBottom = contentView.bottomAnchor.constraint(equalTo: poweredByLabel.bottomAnchor)
        // Places the footer while it is hidden; never wins over the constraints above.
        let footerPlacement = poweredByLabel.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: Self.footerSpacing)
        footerPlacement.priority = .fittingSizeLevel
        // At least as tall as what the keyboard leaves visible, and no taller than its content needs.
        minimumHeight = contentView.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor)
        fittingHeight = contentView.heightAnchor.constraint(equalTo: frame.heightAnchor)
        fittingHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.topAnchor.constraint(equalTo: content.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: frame.widthAnchor),
            minimumHeight,
            fittingHeight,
            stackTop,
            stackLeading,
            stackTrailing,
            stackBottom,
            footerLeading,
            footerTrailing,
            footerPlacement,
            badgesRow.topAnchor.constraint(equalTo: badgesView.topAnchor),
            badgesRow.bottomAnchor.constraint(equalTo: badgesView.bottomAnchor),
            badgesRow.centerXAnchor.constraint(equalTo: badgesView.centerXAnchor),
            badgesRow.leadingAnchor.constraint(greaterThanOrEqualTo: badgesView.leadingAnchor),
            secureRow.topAnchor.constraint(equalTo: secureView.topAnchor),
            secureRow.bottomAnchor.constraint(equalTo: secureView.bottomAnchor),
            secureRow.centerXAnchor.constraint(equalTo: secureView.centerXAnchor),
            secureRow.leadingAnchor.constraint(greaterThanOrEqualTo: secureView.leadingAnchor),
        ])
        for label in [errorLabel, secureLabel, poweredByLabel] {
            label.setContentHuggingPriority(.required, for: .vertical)
        }
    }

    /// An image of the view at its size in points (CONTRACT §16.14), with its VoiceOver label.
    private static func imageView(_ asset: PaymentViewAsset) -> UIImageView {
        let view = UIImageView(image: asset.image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: asset.size.width),
            view.heightAnchor.constraint(equalToConstant: asset.size.height),
        ])
        view.isAccessibilityElement = asset.accessibilityLabel != nil
        view.accessibilityLabel = asset.accessibilityLabel
        view.accessibilityTraits = .image
        return view
    }

    /// The gaps of CONTRACT §16.14 between the parts that are shown: 24 between the form and Pay,
    /// 8 to the error line, 24 to the badges, 20 from the badges to the secure line (24 without
    /// badges).
    private func updateSpacing() {
        let shown = contentStack.arrangedSubviews.filter { !$0.isHidden }
        for (part, next) in zip(shown, shown.dropFirst()) {
            let spacing: CGFloat
            if part === payButton, next === errorLabel {
                spacing = Self.errorSpacing
            } else if part === badgesView, next === secureView {
                spacing = Self.secureSpacing
            } else {
                spacing = Self.sectionSpacing
            }
            contentStack.setCustomSpacing(spacing, after: part)
        }
    }

    /// The padding of the style, plus the safe area and the part of the keyboard that covers the
    /// view: the keyboard hides the bottom safe area, so it is not added twice.
    private func updateInsets() {
        let safe = safeAreaInsets
        let padding = style.padding
        let bottom = padding.bottom + max(0, safe.bottom - keyboardOverlap)
        stackTop.constant = padding.top + safe.top
        stackLeading.constant = padding.left + safe.left
        stackTrailing.constant = padding.right + safe.right
        stackBottom.constant = bottom
        footerLeading.constant = padding.left + safe.left
        footerTrailing.constant = padding.right + safe.right
        footerBottom.constant = bottom
        minimumHeight.constant = -keyboardOverlap
        fittingHeight.constant = -keyboardOverlap
        scrollView.contentInset.bottom = keyboardOverlap
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: safe.top, left: 0, bottom: max(safe.bottom, keyboardOverlap), right: 0)
    }

    override public func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateInsets()
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // iOS 17 and later use the trait registration of init.
        if #available(iOS 17.0, *) { return }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            applyTexts()
        }
    }

    // MARK: - Style and texts

    private func applyStyle() {
        backgroundColor = style.backgroundColor
        form.style = style.formStyle
        payButton.apply(style)
        errorLabel.font = CardFormSectionView.scaledFont(style.formStyle.errorTextStyle.font, relativeTo: .footnote)
        errorLabel.textColor = style.formStyle.errorTextStyle.color ?? style.formStyle.errorColor
        secureLabel.font = Self.secondaryFont
        secureLabel.textColor = style.secondaryTextColor
        badgesView.isHidden = !style.showBadges
        secureView.isHidden = !style.showSecureNote
        poweredByLabel.isHidden = !style.showPoweredBy
        footerTop.isActive = style.showPoweredBy
        footerBottom.isActive = style.showPoweredBy
        updateSpacing()
        updateInsets()
        applyTexts()
    }

    /// 12 pt regular, scaled with Dynamic Type like captions.
    private static var secondaryFont: UIFont {
        CardFormSectionView.scaledFont(.systemFont(ofSize: secondaryFontSize), relativeTo: .caption1)
    }

    /// The texts in the effective language: the Pay title, the secure line and the footer.
    private func applyTexts() {
        state.strings = CardStrings(language: form.effectiveLanguage)
        secureLabel.text = state.strings.view(.secure)
        poweredByLabel.attributedText = poweredByText()
        poweredByLabel.accessibilityLabel = state.strings.view(.poweredBy)
        render()
    }

    /// `view.poweredBy` with the Payriff logo (82×16) where the word "Payriff" is, centred on the
    /// text: "Powered by [logo]", "[logo] tərəfindən hazırlanıb".
    func poweredByText() -> NSAttributedString {
        let font = Self.secondaryFont
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.secondaryTextColor,
            .paragraphStyle: centred,
        ]
        let strings = state.strings
        guard let parts = strings.poweredByParts, let logo = PaymentViewAsset.payriffLogo.image else {
            return NSAttributedString(string: strings.view(.poweredBy), attributes: attributes)
        }
        let size = PaymentViewAsset.payriffLogo.size
        let attachment = NSTextAttachment()
        attachment.image = logo
        attachment.bounds = CGRect(x: 0, y: ((font.capHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
        let text = NSMutableAttributedString(string: parts.before, attributes: attributes)
        let logoText = NSMutableAttributedString(attachment: attachment)
        logoText.addAttributes(attributes, range: NSRange(location: 0, length: logoText.length))
        text.append(logoText)
        text.append(NSAttributedString(string: parts.after, attributes: attributes))
        return text
    }

    // MARK: - State

    /// Shows the state: the Pay button's title, whether it is enabled or busy, and the error line.
    private func render() {
        state.isFormComplete = form.isComplete
        payButton.title = state.payTitle
        payButton.isBusy = state.isPaying || form.isProcessing
        payButton.isEnabled = state.isPayEnabled && !form.isProcessing
        let message = state.errorMessage
        guard errorLabel.text != message || errorLabel.isHidden != (message == nil) else { return }
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        updateSpacing()
        if let message, window != nil {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func formDidChange() {
        render()
        scrollToFocusedSection(animated: true)
    }

    // MARK: - Order (CONTRACT §16.14: read when the view appears)

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyboardObservers.removeAll()
        if keyboardOverlap != 0 {
            keyboardOverlap = 0
            updateInsets()
        }
        guard window != nil else { return }
        // The configured language may have changed since the view was made.
        applyTexts()
        observeKeyboard()
        loadOrderIfNeeded()
    }

    /// Reads the order unless it is loaded, loading, or failed for good (a fatal error).
    func loadOrderIfNeeded() {
        guard loadTask == nil, state.needsOrder else { return }
        loadOrder()
    }

    private func loadOrder() {
        loadGeneration += 1
        let generation = loadGeneration
        state.orderWillLoad()
        render()
        let orderId = orderId
        let clientSecret = clientSecret
        loadTask = Task { [weak self] in
            let result: Result<PayriffClientOrder, PayriffError>
            do throws(PayriffError) {
                result = .success(try await Payriff.retrieveOrder(orderId: orderId, clientSecret: clientSecret))
            } catch {
                result = .failure(error)
            }
            self?.orderDidLoad(result, generation: generation)
        }
    }

    private func orderDidLoad(_ result: Result<PayriffClientOrder, PayriffError>, generation: Int) {
        guard generation == loadGeneration else { return }
        loadTask = nil
        let fatal = state.orderDidLoad(result)
        render()
        if let fatal { onResult?(fatal) }
    }

    /// Pays another order: the view forgets the previous one and reads the new one when it is on
    /// screen. ``PayriffPaymentScreen`` calls it when its order changes.
    func setOrder(orderId: String, clientSecret: String) {
        guard orderId != self.orderId || clientSecret != self.clientSecret else { return }
        self.orderId = orderId
        self.clientSecret = clientSecret
        // A late answer for the previous order is dropped.
        loadGeneration += 1
        loadTask = nil
        state.orderDidChange()
        render()
        if window != nil { loadOrder() }
    }

    // MARK: - Pay

    /// Pay: ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)`` with the view's form.
    func pay() {
        render()
        guard state.isPayEnabled, !form.isProcessing else { return }
        state.paymentWillStart()
        render()
        // The view stays alive until the result is delivered.
        Payriff.confirmCardPayment(form, orderId: orderId, clientSecret: clientSecret, from: presenter) { result in
            self.paymentDidFinish(result)
        }
    }

    private func paymentDidFinish(_ result: PayriffResult) {
        state.paymentDidFinish(result)
        render()
        onResult?(result)
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let info = notification.userInfo
                let hides = notification.name == UIResponder.keyboardWillHideNotification
                let frame = hides ? nil : (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
                let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
                MainActor.assumeIsolated {
                    self?.keyboardWillChange(to: frame, duration: duration, curve: curve)
                }
            })
        }
    }

    /// The keyboard moves to `screenFrame` (`nil`: it hides): make room for it and keep the field
    /// being edited visible.
    func keyboardWillChange(to screenFrame: CGRect?, duration: TimeInterval = 0, curve: UInt = 7) {
        let overlap = keyboardOverlap(at: screenFrame)
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        let options = UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.updateInsets()
            self.layoutIfNeeded()
            self.scrollToFocusedSection(animated: false)
        }
    }

    /// How much of the view, from its bottom, a keyboard at `screenFrame` covers.
    private func keyboardOverlap(at screenFrame: CGRect?) -> CGFloat {
        guard let screenFrame, !screenFrame.isEmpty, let window else { return 0 }
        let frame = convert(screenFrame, from: window.screen.coordinateSpace)
        let covered = bounds.intersection(frame)
        guard !covered.isNull, !covered.isEmpty else { return 0 }
        return max(0, bounds.maxY - covered.minY)
    }

    /// Scrolls the section being edited (its box and error line) above the keyboard.
    private func scrollToFocusedSection(animated: Bool) {
        guard keyboardOverlap > 0, let section = form.focusedSectionView else { return }
        layoutIfNeeded()
        let rect = section.convert(section.bounds, to: scrollView).insetBy(dx: 0, dy: -12)
        let current = scrollView.contentOffset.y
        let visibleTop = current + safeAreaInsets.top
        let visibleBottom = current + scrollView.bounds.height - keyboardOverlap
        var offset = current
        if rect.maxY > visibleBottom { offset += rect.maxY - visibleBottom }
        if rect.minY < visibleTop + (offset - current) { offset = rect.minY - safeAreaInsets.top }
        let maximum = max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
        offset = min(max(0, offset), maximum)
        guard abs(offset - current) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: animated)
    }
}

/// The Pay button of ``PayriffPaymentView`` (CONTRACT §16.14): the brand colour, a white title,
/// 50% opacity while disabled, and a spinner in place of the title while a payment runs.
@MainActor
final class PaymentViewPayButton: UIControl {
    let titleLabel = UILabel()
    let spinner = UIActivityIndicatorView(style: .medium)
    private var minimumHeight: NSLayoutConstraint!

    /// The space between the title and the button's edges.
    static let titleInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

    /// The title, also the VoiceOver label.
    var title = "" {
        didSet {
            titleLabel.text = title
            accessibilityLabel = title
        }
    }

    /// Whether a payment runs: a spinner replaces the title.
    var isBusy = false {
        didSet { if isBusy != oldValue { update() } }
    }

    override var isEnabled: Bool {
        didSet { update() }
    }

    override var isHighlighted: Bool {
        didSet { update() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        layer.cornerCurve = .continuous
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        addSubview(titleLabel)
        addSubview(spinner)
        minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        // No taller than the title needs, and at least `buttonHeight`.
        let compact = heightAnchor.constraint(equalToConstant: 0)
        compact.priority = .fittingSizeLevel
        let insets = Self.titleInsets
        NSLayoutConstraint.activate([
            minimumHeight,
            compact,
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: insets.left),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: insets.top),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ style: PayriffPaymentViewStyle) {
        backgroundColor = style.buttonColor
        layer.cornerRadius = style.buttonCornerRadius
        minimumHeight.constant = style.buttonHeight
        titleLabel.font = CardFormSectionView.scaledFont(style.buttonTextStyle.font, relativeTo: .body)
        let color = style.buttonTextStyle.color ?? PayriffPaymentViewStyle.Defaults.buttonText
        titleLabel.textColor = color
        spinner.color = color
    }

    /// Whether a tap pays: enabled and not busy.
    var isActive: Bool { isEnabled && !isBusy }

    private func update() {
        alpha = isActive ? (isHighlighted ? 0.8 : 1) : 0.5
        titleLabel.isHidden = isBusy
        if isBusy {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        accessibilityTraits = isActive ? .button : [.button, .notEnabled]
    }
}

/// The lock before the secure line of ``PayriffPaymentView`` (CONTRACT §16.14), drawn in code
/// (``PaymentViewLock``): 15×15 points in `#56BE3D`. It is decoration, so VoiceOver skips it.
@MainActor
final class PaymentViewLockView: UIView {
    /// The shackle and the body, stroked.
    let outlineLayer = CAShapeLayer()
    /// The keyhole, filled.
    let keyholeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        let color = UIColor(rgb: PaymentViewLock.color).cgColor
        let square = CGRect(x: 0, y: 0, width: PaymentViewLock.side, height: PaymentViewLock.side)
        outlineLayer.frame = square
        outlineLayer.path = PaymentViewLock.outline()
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = color
        outlineLayer.lineWidth = PaymentViewLock.lineWidth()
        outlineLayer.lineCap = .round
        outlineLayer.lineJoin = .round
        keyholeLayer.frame = square
        keyholeLayer.path = PaymentViewLock.keyhole()
        keyholeLayer.fillColor = color
        layer.addSublayer(outlineLayer)
        layer.addSublayer(keyholeLayer)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PaymentViewLock.side),
            heightAnchor.constraint(equalToConstant: PaymentViewLock.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
