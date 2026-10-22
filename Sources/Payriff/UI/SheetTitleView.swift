#if canImport(UIKit) && canImport(WebKit)
import UIKit

/// The sheet's title, "Payment" in the payment language. Nothing else: no address, padlock or
/// host, so the sheet reads as part of the app rather than a website (CONTRACT §9.1).
@MainActor
final class SheetTitleView: UIView {
    private let titleLabel = UILabel()

    /// - Parameter title: The localized title.
    init(title: String) {
        super.init(frame: .zero)

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Navigation bar titles stay readable without pushing the bar buttons away.
        maximumContentSizeCategory = .accessibilityMedium
        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The displayed title.
    var title: String? { titleLabel.text }
}
#endif
