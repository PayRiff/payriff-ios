#if canImport(UIKit) && canImport(WebKit)
import UIKit

/// An opaque full-sheet overlay with vertically centered, scrollable content.
@MainActor
class OverlayView: UIView {
    let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        let fillHeight = content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        fillHeight.priority = .defaultLow
        let preferredWidth = stack.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            fillHeight,
            content.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor, constant: 48),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: frame.widthAnchor, constant: -48),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            preferredWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The element VoiceOver should move to when the overlay appears.
    var primaryAccessibilityElement: Any? { stack.arrangedSubviews.first { !$0.isHidden && $0.isAccessibilityElement } }

    static func label(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }

    static func icon(_ systemName: String, color: UIColor) -> UIImageView {
        let configuration = UIImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        let view = UIImageView(image: UIImage(systemName: systemName, withConfiguration: configuration))
        view.tintColor = color
        view.contentMode = .center
        view.adjustsImageSizeForAccessibilityContentSizeCategory = true
        view.isAccessibilityElement = false
        return view
    }

    static func button(_ title: String, prominent: Bool, action: @escaping @MainActor () -> Void) -> UIButton {
        var configuration = Glass.buttonConfiguration(prominent: prominent)
        configuration.title = title
        configuration.buttonSize = .large
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = title
        return button
    }
}

/// "Checking payment…" with a spinner.
@MainActor
final class ProgressOverlayView: OverlayView {
    let message: String

    init(message: String) {
        self.message = message
        super.init()
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        spinner.isAccessibilityElement = false
        let label = Self.label(message, style: .body, color: .secondaryLabel)
        label.accessibilityTraits = .updatesFrequently
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)
        stack.spacing = 16
    }
}

/// The page-load error screen with "Try again" and "Close" (CONTRACT §16.8).
@MainActor
final class ErrorOverlayView: OverlayView {
    /// The SF Symbol of the error icon.
    static let symbol = "exclamationmark.triangle.fill"

    init(
        message: String,
        strings: PayriffStrings,
        onRetry: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        super.init()
        stack.addArrangedSubview(Self.icon(Self.symbol, color: .systemOrange))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[0])
        stack.addArrangedSubview(Self.label(message, style: .body))
        let retryButton = Self.button(strings[.retry], prominent: true, action: onRetry)
        stack.addArrangedSubview(retryButton)
        stack.setCustomSpacing(28, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        stack.addArrangedSubview(Self.button(strings[.close], prominent: false, action: onClose))
    }
}
#endif
