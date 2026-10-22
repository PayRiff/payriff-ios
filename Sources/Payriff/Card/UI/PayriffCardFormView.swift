#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// SwiftUI wrapper of ``PayriffCardForm``.
///
/// Keep the form in your model (or `@State`) and pass the same instance to
/// ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)``:
///
/// ```swift
/// @State private var form = PayriffCardForm()
/// @State private var isComplete = false
///
/// var body: some View {
///     PayriffCardFormView(form) { change in isComplete = change.isComplete }
///     Button("Pay") {
///         Task { result = await Payriff.confirmCardPayment(form, orderId: id, clientSecret: secret) }
///     }
///     .disabled(!isComplete)
/// }
/// ```
///
/// Pass `style:` to change the form's look from SwiftUI state; the form keeps what the customer
/// typed when the style changes.
@MainActor
public struct PayriffCardFormView: UIViewRepresentable {
    private let form: PayriffCardForm
    private let style: PayriffCardFormStyle?
    private let onChange: (@MainActor (PayriffCardFormChange) -> Void)?

    /// Shows `form`.
    ///
    /// - Parameters:
    ///   - form: The form to show and later pass to `confirmCardPayment`.
    ///   - style: The form's look (``PayriffCardForm/style``). `nil`, the default, keeps the
    ///     style the form has.
    ///   - onChange: Replaces the form's ``PayriffCardForm/onChange`` when set.
    public init(
        _ form: PayriffCardForm,
        style: PayriffCardFormStyle? = nil,
        onChange: (@MainActor (PayriffCardFormChange) -> Void)? = nil
    ) {
        self.form = form
        self.style = style
        self.onChange = onChange
    }

    public func makeUIView(context: Context) -> PayriffCardForm {
        configure(form)
        form.setContentHuggingPriority(.required, for: .vertical)
        return form
    }

    public func updateUIView(_ uiView: PayriffCardForm, context: Context) {
        configure(uiView)
    }

    /// Gives `form` this view's style, when it has one, and its change handler. An unchanged
    /// style costs nothing: the form ignores a style equal to its own.
    func configure(_ form: PayriffCardForm) {
        if let style { form.style = style }
        if let onChange { form.onChange = onChange }
    }

    /// The form's height for the proposed width.
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: PayriffCardForm, context: Context) -> CGSize? {
        let width = proposal.width.map { $0.isFinite ? $0 : 320 } ?? 320
        let size = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: size.height)
    }
}
#endif
