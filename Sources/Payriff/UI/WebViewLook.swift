#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// Makes the 3-D Secure pages feel like part of the app (CONTRACT §7.7, §9.1): no zoom, no
/// rubber-band overscroll, no scroll indicators, no link previews and no back/forward swipe.
/// No script is injected; everything is set on the web view and its scroll view.
@MainActor
enum WebViewLook {
    static func apply(to webView: WKWebView) {
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        let scrollView = webView.scrollView
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = false
        lockZoom(webView)
    }

    /// Pins the zoom range to the page's current fit scale, which stops pinch zoom and the zoom
    /// WebKit applies when a small text field gets focus, without changing how the page fits.
    /// WebKit resets the range from each page's viewport, so this runs again whenever a page
    /// commits or finishes loading.
    static func lockZoom(_ webView: WKWebView) {
        let scrollView = webView.scrollView
        scrollView.pinchGestureRecognizer?.isEnabled = false
        let scale = scrollView.zoomScale
        scrollView.minimumZoomScale = scale
        scrollView.maximumZoomScale = scale
    }
}

/// Liquid Glass (iOS 26+) for the sheet's controls. The sheet itself stays opaque, like the
/// system's large sheets: the close button is glass automatically, and the buttons of the error
/// screen use the glass button styles. Earlier systems keep the classic styles.
@MainActor
enum Glass {
    /// A glass button on iOS 26+: prominent (tinted) for the primary action.
    static func buttonConfiguration(prominent: Bool) -> UIButton.Configuration {
        if #available(iOS 26.0, *) {
            return prominent ? .prominentGlass() : .glass()
        }
        return prominent ? .filled() : .gray()
    }
}
#endif
