import Foundation

/// The parts of a URL the 3-D Secure navigation rules compare: lower-cased scheme and host, the
/// effective port and the percent-encoded path.
struct ParsedURL: Equatable, Sendable {
    let scheme: String
    let host: String?
    let port: Int?
    let path: String

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            return nil
        }
        self.scheme = scheme
        self.host = components.host.map { $0.lowercased() }
        self.port = components.port
        self.path = components.percentEncodedPath
    }

    var isHTTP: Bool { scheme == "http" || scheme == "https" }

    /// The explicit port, or 80/443 for http/https.
    var effectivePort: Int? {
        if let port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

extension URL {
    /// Whether the URL is absolute, uses `https` and has a host.
    var isAbsoluteHTTPS: Bool {
        guard let parsed = ParsedURL(self) else { return false }
        return parsed.scheme == "https" && !(parsed.host ?? "").isEmpty
    }
}
