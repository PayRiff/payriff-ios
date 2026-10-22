#if canImport(UIKit)
import UIKit

/// An opaque view that hides payment content while its scene is not active, so app-switcher
/// snapshots and screenshots of the inactive app show nothing a customer typed
/// (CONTRACT §16.0 item 4). It fills its superview, follows light and dark mode, and is
/// invisible to VoiceOver.
@MainActor
final class PrivacyCoverView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .systemBackground
        isOpaque = true
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Adds a cover above every other subview of `container`.
    static func cover(_ container: UIView) -> PrivacyCoverView {
        let cover = PrivacyCoverView(frame: container.bounds)
        container.addSubview(cover)
        return cover
    }
}
#endif
