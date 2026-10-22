import Foundation

/// The images of ``PayriffPaymentView`` (CONTRACT §16.14), from Payriff's hosted payment page:
/// PNG files in 1x, 2x and 3x (`visa.png`, `visa@2x.png`, `visa@3x.png`, …) in the SDK's resource
/// bundle. UIKit picks the file for the screen's scale. The lock of the secure line is drawn in
/// code (``PaymentViewLock``).
enum PaymentViewAsset: String, CaseIterable, Sendable {
    /// The Mastercard acceptance badge.
    case mastercard
    /// The Visa acceptance badge.
    case visa
    /// The Payriff logo of the "Powered by" footer.
    case payriffLogo = "payriff-logo"

    /// The badges of the badge row, in order: the brands the SDK accepts. No PCI logo: PCI SSC
    /// does not allow its "PCI ✓" mark (CONTRACT §16.14).
    static let badges: [PaymentViewAsset] = [.mastercard, .visa]

    /// The file name without the scale suffix and the extension.
    var name: String { rawValue }

    /// The size in points (the 1x file's size in pixels).
    var size: CGSize {
        switch self {
        case .visa: return CGSize(width: 42, height: 28)
        case .mastercard: return CGSize(width: 43, height: 28)
        case .payriffLogo: return CGSize(width: 82, height: 16)
        }
    }

    /// What VoiceOver reads for the image, or `nil` when it is decoration.
    var accessibilityLabel: String? {
        switch self {
        case .mastercard: return "Mastercard"
        case .visa: return "Visa"
        case .payriffLogo: return "Payriff"
        }
    }
}

/// The SDK's resource bundle.
///
/// Swift Package Manager builds it as `Bundle.module`. CocoaPods has no `Bundle.module`: the
/// podspec's `Payriff_PaymentView` resource bundle sits next to the SDK's code, inside the
/// framework or, for a static library, in the app's main bundle.
enum PayriffResources {
    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let code = Bundle(for: BundleToken.self)
        for candidate in [code, Bundle.main] {
            if let url = candidate.url(forResource: "Payriff_PaymentView", withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return code
        #endif
    }()

    #if !SWIFT_PACKAGE
    private final class BundleToken {}
    #endif
}

#if canImport(UIKit)
import UIKit

extension PaymentViewAsset {
    /// The image for the screen's scale, from the SDK's resource bundle; `nil` only when the
    /// bundle lacks it.
    var image: UIImage? {
        UIImage(named: name, in: PayriffResources.bundle, compatibleWith: nil)
    }
}
#endif
