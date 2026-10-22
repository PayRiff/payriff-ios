import Foundation

/// What the SDK does after `/pay` or `/three-ds` (CONTRACT §16.7, `card_next_action.json`).
///
/// Every URL is an absolute `https` URL; anything else makes the action ``invalid``. The values
/// (`creq`, `threeDSMethodData`) go to the bank only and are never logged; the textual
/// representations never contain them.
enum CardNextAction: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    /// A 3-D Secure challenge: a form POST of `form` to `url` in the 3DS sheet.
    case challenge(url: URL, form: [FormField])
    /// The 3DS method: POST `threeDSMethodData` to `methodURL` and an empty POST to
    /// `methodServerURL` in hidden web views (each only when set), then poll `/three-ds`.
    case method(methodURL: URL?, methodData: String?, methodServerURL: URL?)
    /// Wait 1 s, then poll `/three-ds`.
    case wait
    /// Open `url` (GET) in the 3DS sheet.
    case redirect(URL)
    /// Poll `/status`.
    case checkStatus
    /// An unknown or unsafe action: one status check decides.
    case invalid

    /// One form field of a challenge POST.
    struct FormField: Sendable, Equatable {
        let key: String
        let value: String
    }

    /// No children, so `dump` never shows `creq` or `threeDSMethodData`.
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }

    /// Whether this is a `method` with nothing to post.
    var isEmptyMethod: Bool {
        if case .method(nil, _, nil) = self { return true }
        return false
    }

    /// The action type, for logs (never the URLs' queries or the form values).
    var description: String {
        switch self {
        case .challenge(let url, let form): return "challenge(\(Log.redactedURL(url)), \(form.count) field(s))"
        case .method(let methodURL, _, let serverURL):
            return "method(methodUrl: \(methodURL.map(Log.redactedURL) ?? "none"), methodUrlServer: \(serverURL.map(Log.redactedURL) ?? "none"))"
        case .wait: return "wait"
        case .redirect(let url): return "redirect(\(Log.redactedURL(url)))"
        case .checkStatus: return "checkStatus"
        case .invalid: return "invalid"
        }
    }

    /// Classifies a `/pay` or `/three-ds` payload.
    init(payload: [String: Any]) {
        switch payload["nextAction"] as? String {
        case "THREE_DS":
            let fields = Self.sanitizedClientRequest(payload["clientRequest"])
            if let accessURL = Self.nonEmptyString(payload["accessUrl"]) {
                guard let url = Self.httpsURL(accessURL) else {
                    self = .invalid
                    return
                }
                self = .challenge(url: url, form: fields.map { FormField(key: $0.key, value: $0.value ?? "") })
                return
            }
            var values: [String: String?] = [:]
            for field in fields { values[field.key] = field.value }
            let methodURLText = values["threeDSMethodUrl"].flatMap { $0 }.flatMap(Self.nonEmptyString)
            let serverURLText = values["threeDSMethodUrlServer"].flatMap { $0 }.flatMap(Self.nonEmptyString)
            let methodURL = methodURLText.flatMap(Self.httpsURL)
            let serverURL = serverURLText.flatMap(Self.httpsURL)
            if (methodURLText != nil && methodURL == nil) || (serverURLText != nil && serverURL == nil) {
                self = .invalid
                return
            }
            self = .method(methodURL: methodURL, methodData: values["threeDSMethodData"].flatMap { $0 }, methodServerURL: serverURL)
        case "WAIT":
            self = .wait
        case "REDIRECT":
            guard let text = Self.nonEmptyString(payload["redirectUrl"]), let url = Self.httpsURL(text) else {
                self = .invalid
                return
            }
            self = .redirect(url)
        case "CHECK_STATUS":
            self = .checkStatus
        default:
            self = .invalid
        }
    }

    /// Entries whose key is a string and whose value is a string or null/absent, in order.
    private static func sanitizedClientRequest(_ value: Any?) -> [(key: String, value: String?)] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            guard let entry = item as? [String: Any], let key = entry["key"] as? String else { return nil }
            switch entry["value"] {
            case nil, is NSNull: return (key, nil)
            case let text as String: return (key, text)
            default: return nil
            }
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// An absolute `https` URL with a host, else `nil`.
    private static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.isAbsoluteHTTPS else { return nil }
        return url
    }
}

/// The 3-D Secure WebView navigation rules (CONTRACT §16.8, `card_3ds_navigation.json`).
///
/// A gateway callback (`https://{apiHost}/api/v3/gateway/…/callback…`) is loaded, never cancelled,
/// because it carries the bank's answer. The first main-frame navigation after it that is neither
/// another callback nor `about:blank` ends the flow.
struct ThreeDSNavigator: Sendable {
    enum Action: String, Sendable, CaseIterable {
        /// Load it.
        case allow
        /// Payriff's bank callback: load it, never cancel it, and arm the flow.
        case allowCallback
        /// Cancel it, close the WebView and resolve the status.
        case finish
        /// Cancel it and hand the URL to the operating system.
        case external
        /// Cancel silently.
        case block
    }

    /// Schemes that are never handed to the operating system; in the main frame they are blocked.
    /// `file:` and `content:` never leave the web view (CONTRACT §16.0 item 5).
    private static let nonExternalSchemes: Set<String> = [
        "http", "https", "about", "data", "blob", "javascript", "file", "content", "ftp", "ws", "wss", "filesystem",
    ]

    /// The only schemes a subframe may load: never `file:`, cleartext `http:` or another scheme.
    private static let subframeSchemes: Set<String> = ["https", "about", "data", "blob", "javascript"]

    /// The lower-cased API host of the environment, such as `api.payriff.com`.
    let apiHost: String
    /// Whether a callback was loaded in the main frame.
    private(set) var isArmed = false

    init(apiHost: String) {
        self.apiHost = apiHost.lowercased()
    }

    /// Whether `url` is a gateway callback of this environment: `https`, the API host
    /// (case-insensitive, default port), a path under `/api/v3/gateway/` with a `callback` segment.
    func isCallback(_ url: URL?) -> Bool {
        guard let url, let parsed = ParsedURL(url), parsed.scheme == "https",
              parsed.host == apiHost, parsed.effectivePort == 443 else {
            return false
        }
        let prefix = "/api/v3/gateway/"
        guard parsed.path.hasPrefix(prefix) else { return false }
        return parsed.path.dropFirst(prefix.count).split(separator: "/").contains("callback")
    }

    /// Decides a navigation and updates the state.
    mutating func decide(_ url: URL?, isMainFrame: Bool) -> Action {
        guard let url, let parsed = ParsedURL(url) else { return .block }
        guard isMainFrame else {
            // Subframes neither arm nor end the flow and never open other apps.
            return Self.subframeSchemes.contains(parsed.scheme) ? .allow : .block
        }
        if parsed.scheme == "about", parsed.path.lowercased() == "blank" { return .allow }
        if isCallback(url) {
            isArmed = true
            return .allowCallback
        }
        if isArmed { return .finish }
        if parsed.scheme == "https" { return .allow }
        return Self.nonExternalSchemes.contains(parsed.scheme) ? .block : .external
    }
}
