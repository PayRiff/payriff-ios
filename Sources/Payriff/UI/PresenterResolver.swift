#if canImport(UIKit) && canImport(WebKit)
import UIKit

/// Hands URLs that the web view must not load (bank apps, `tel:`, `mailto:`) to the system.
@MainActor
protocol ExternalURLOpening {
    func open(_ url: URL)
}

/// Opens external URLs with `UIApplication.open` (CONTRACT §7.5). Failures are logged and ignored.
@available(iOSApplicationExtension, unavailable)
struct ApplicationURLOpener: ExternalURLOpening {
    func open(_ url: URL) {
        let description = Log.redactedURL(url)
        Log.info("Opening externally: \(description)")
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                Log.warning("No app could open \(description); the payment continues in the sheet.")
            }
        }
    }
}

/// Finds the view controller to present the payment sheet from.
@available(iOSApplicationExtension, unavailable)
@MainActor
enum PresenterResolver {
    /// The top-most view controller above `explicit`, or above the root of the key window of the
    /// foreground-active scene when `explicit` is `nil`. `nil` when nothing is on screen.
    ///
    /// With several foreground-active scenes (iPad multitasking), the scene that holds the app's
    /// key window, the one the customer is using, is preferred; `connectedScenes` is unordered.
    static func presenter(from explicit: UIViewController?) -> UIViewController? {
        if let explicit {
            guard explicit.viewIfLoaded?.window != nil else { return nil }
            return topmost(from: explicit)
        }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let scene = scenes.first { $0.windows.contains(where: \.isKeyWindow) } ?? scenes.first
        guard let scene, let window = keyWindow(in: scene) else { return nil }
        return presenter(in: window)
    }

    /// The top-most view controller of `window`.
    static func presenter(in window: UIWindow) -> UIViewController? {
        window.rootViewController.map(topmost(from:))
    }

    private static func topmost(from root: UIViewController) -> UIViewController {
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private static func keyWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.keyWindow
            ?? scene.windows.first(where: \.isKeyWindow)
            ?? scene.windows.first { !$0.isHidden && $0.windowLevel == .normal }
    }
}
#endif
