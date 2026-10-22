import Foundation

/// The answer to a navigation reported by the web layer.
enum NavigationResponse: Equatable, Sendable {
    case allow
    case cancel
}

/// What the 3-D Secure sheet reports to the flow it shows and asks it to decide (CONTRACT §9.1,
/// §16.8).
///
/// ``CardPaymentFlow`` drives the sheet; it is UI-free, and the UIKit sheet only forwards events.
@MainActor
protocol SheetFlowHandling: AnyObject {
    /// Whether the flow behind the sheet has ended; a close button then just dismisses.
    var isFinished: Bool { get }
    /// Decides a navigation of the web view. `inPopup` is `true` for a navigation that would
    /// open a new window (`window.open`, `target=_blank`); the sheet never opens one.
    func decideNavigation(to url: URL?, isMainFrame: Bool, inPopup: Bool) -> NavigationResponse
    /// The page asked for a new window. The sheet never opens one; the flow may hand a bank-app
    /// URL to the operating system.
    func windowRequested(to url: URL?)
    /// The web view committed a main-frame navigation.
    func pageDidCommit(_ url: URL?)
    /// The web view finished loading a main-frame page.
    func pageDidFinish(_ url: URL?)
    /// The web view failed to load a main-frame page.
    func pageDidFail(_ error: any Error, failingURL: URL?)
    /// The web view's content process terminated.
    func webContentProcessDidTerminate()
    /// "Try again" on the page-load error screen.
    func retry()
    /// The close button, a swipe-down attempt, or the Close button of the error screen.
    func requestClose()
    /// The host app dismissed the sheet itself (or its scene went away).
    func sheetWasDismissedExternally()
}
