import Foundation
import os

/// The severity of a log entry.
public enum PayriffLogLevel: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Detailed diagnostics, such as navigation decisions.
    case debug
    /// Normal milestones, such as a payment starting or finishing.
    case info
    /// Something unexpected that the SDK handled.
    case warning
    /// A failure.
    case error

    /// The upper-case label used in formatted lines (`DEBUG`, `INFO`, `WARNING`, `ERROR`).
    public var label: String { rawValue.uppercased() }

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    /// Orders levels from ``debug`` to ``error``.
    public static func < (lhs: PayriffLogLevel, rhs: PayriffLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One SDK log entry. Entries never contain keys, the client secret, the value of any secret
/// header, card data, or the user info, query or fragment of a URL; they show a URL's path only
/// for Payriff's API hosts, and of other schemes only `<scheme>:…`.
public struct PayriffLogEntry: Sendable, Hashable {
    /// The severity.
    public let level: PayriffLogLevel
    /// The message, without the `[Payriff] [LEVEL]` prefix.
    public let message: String
    /// When the entry was created.
    public let timestamp: Date

    /// Creates an entry.
    public init(level: PayriffLogLevel, message: String, timestamp: Date = Date()) {
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }

    /// The entry formatted as `[Payriff] [LEVEL] message`, the same line the SDK writes to the
    /// console. The example app's log console renders this.
    public var formatted: String {
        "[Payriff] [\(level.label)] \(message)"
    }
}

/// Receives the SDK's log output.
///
/// Logging is off by default; turn it on with ``PayriffConfig/enableLogging``. Entries are
/// written to the unified logging system (subsystem `com.payriff.sdk`; the text is private
/// there in release builds) and passed to ``onLog``.
///
/// Entries never contain secrets or card data, but they do contain order ids, statuses, amounts
/// and the paths of Payriff's API URLs. Keep them in your own diagnostics; do not forward them
/// to third-party analytics.
///
/// URLs never show their user info, query or fragment. Only Payriff's API hosts
/// (`api.payriff.com`, `sb-api.payriff.com`) show the path, with every segment of 16 or more
/// characters shortened to its first and last 4 (`/api/v3/client/orders/7c9e…0ae7/pay`); any
/// other host, such as a bank's 3-D Secure page, shows as `https://host[:port]` only, and other
/// schemes only as `<scheme>:…`.
///
/// In debug builds, `debug` entries also show every API request and response as pretty-printed
/// JSON (`HTTP request` / `HTTP response`: method, URL, headers and body), with secrets redacted
/// (`***(<length>)`) and URLs redacted as above. Release builds never log them.
///
/// ```swift
/// PayriffLogger.onLog = { entry in
///     Task { @MainActor in console.append(entry.formatted) }
/// }
/// ```
public enum PayriffLogger {
    private struct State: Sendable {
        var isEnabled = false
        var handler: (@Sendable (PayriffLogEntry) -> Void)?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let osLogger = Logger(subsystem: "com.payriff.sdk", category: "Payriff")

    /// Called for every log entry while logging is enabled.
    ///
    /// The handler may be called on any thread; hop to the main actor before touching UI.
    public static var onLog: (@Sendable (PayriffLogEntry) -> Void)? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    /// Whether logging is enabled. Set from ``PayriffConfig/enableLogging`` by ``Payriff/configure(_:)``.
    static var isEnabled: Bool {
        get { state.withLock { $0.isEnabled } }
        set { state.withLock { $0.isEnabled = newValue } }
    }

    /// Emits an entry when logging is enabled, or unconditionally when `force` is `true`.
    ///
    /// Lines contain order ids, statuses, amounts and the paths of Payriff's API URLs. In the
    /// unified log they are public only in debug builds; release builds mark them private, so
    /// Console and sysdiagnose archives show `<private>` (``onLog`` still receives the full text).
    static func log(_ level: PayriffLogLevel, _ message: @autoclosure () -> String, force: Bool = false) {
        let (enabled, handler) = state.withLock { ($0.isEnabled, $0.handler) }
        guard enabled || force else { return }
        let entry = PayriffLogEntry(level: level, message: message())
        let line = entry.formatted
        #if DEBUG
        switch level {
        case .debug: osLogger.debug("\(line, privacy: .public)")
        case .info: osLogger.info("\(line, privacy: .public)")
        case .warning: osLogger.warning("\(line, privacy: .public)")
        case .error: osLogger.error("\(line, privacy: .public)")
        }
        #else
        switch level {
        case .debug: osLogger.debug("\(line, privacy: .private)")
        case .info: osLogger.info("\(line, privacy: .private)")
        case .warning: osLogger.warning("\(line, privacy: .private)")
        case .error: osLogger.error("\(line, privacy: .private)")
        }
        #endif
        handler?(entry)
    }
}

/// Internal logging shortcuts and redaction helpers.
enum Log {
    static func debug(_ message: @autoclosure () -> String) { PayriffLogger.log(.debug, message()) }
    static func info(_ message: @autoclosure () -> String) { PayriffLogger.log(.info, message()) }
    static func warning(_ message: @autoclosure () -> String) { PayriffLogger.log(.warning, message()) }
    static func error(_ message: @autoclosure () -> String) { PayriffLogger.log(.error, message()) }

    /// The hosts whose URL paths may be logged: Payriff's API hosts, `api.payriff.com` and
    /// `sb-api.payriff.com` (CONTRACT §11, the host table of §16.2), lower-cased.
    static let apiHosts: Set<String> = Set(PayriffEnvironment.allCases.map(ClientAPIHost.host(for:)))

    /// A path segment of this many characters or more is logged as its first and last
    /// ``shortenedSegmentEnds`` characters.
    static let longPathSegment = 16
    static let shortenedSegmentEnds = 4

    /// `url` as it may appear in logs, redacted by the `String` variant below; `nil` as `nil`.
    static func redactedURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        return redactedURL(url.absoluteString)
    }

    /// `url` as it may appear in logs (CONTRACT §11). This is the SDK's one URL redaction: the
    /// general log, the HTTP details (``HTTPLog``) and the URLs inside logged bodies all use it.
    ///
    /// - An http(s) URL never shows its user info (`user:password@`), query or fragment.
    /// - Only on Payriff's API hosts (``apiHosts``) is the path shown, and a path segment of 16 or
    ///   more characters only as its first and last 4 characters:
    ///   `https://api.payriff.com/api/v3/client/orders/7c9e…0ae7/pay`.
    /// - Any other host, such as a bank's 3-D Secure page, shows as `scheme://host[:port]` only.
    /// - Any other scheme shows only as `<scheme>:…`, so a `tel:` number, a `mailto:` address or
    ///   `data:` and `javascript:` content never reaches the logs.
    ///
    /// The scheme and the host are lower-cased. An http(s) URL without `//` and a host shows as
    /// `<scheme>:…`, a reference without a scheme as `…`, and an empty string stays empty.
    static func redactedURL(_ url: String) -> String {
        let scalars = url.unicodeScalars
        guard !scalars.isEmpty else { return "" }
        guard let colon = scalars.firstIndex(of: ":"), isScheme(scalars[..<colon]) else { return "…" }
        let scheme = String(scalars[..<colon]).lowercased()
        guard scheme == "http" || scheme == "https" else { return scheme + ":…" }
        // The query and the fragment never show.
        let end = scalars[colon...].firstIndex { $0 == "?" || $0 == "#" } ?? scalars.endIndex
        let rest = scalars[scalars.index(after: colon)..<end]
        guard rest.starts(with: "//".unicodeScalars) else { return scheme + ":…" }
        // The authority runs up to the path. WebKit reads `\` as `/` in http(s) URLs, so a
        // backslash ends it too.
        let authorityStart = rest.index(rest.startIndex, offsetBy: 2)
        let pathStart = rest[authorityStart...].firstIndex { $0 == "/" || $0 == "\\" } ?? rest.endIndex
        var authority = rest[authorityStart..<pathStart]
        // The user info runs up to the authority's last `@`.
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        let (host, port) = hostAndPort(authority)
        let origin = scheme + "://" + host + (port.map { ":" + $0 } ?? "")
        guard apiHosts.contains(host) else { return origin }
        return origin + shortenedPath(rest[pathStart...])
    }

    /// The lower-cased host of an authority without user info, and its port when that is all
    /// digits.
    private static func hostAndPort(_ authority: Substring.UnicodeScalarView) -> (host: String, port: String?) {
        // An IPv6 literal, `[…]`, has colons of its own.
        let hostEnd: Substring.UnicodeScalarView.Index
        if authority.first == "[", let bracket = authority.firstIndex(of: "]") {
            hostEnd = authority.index(after: bracket)
        } else {
            hostEnd = authority.firstIndex(of: ":") ?? authority.endIndex
        }
        let host = String(authority[..<hostEnd]).lowercased()
        guard hostEnd < authority.endIndex, authority[hostEnd] == ":" else { return (host, nil) }
        let port = authority[authority.index(after: hostEnd)...]
        guard !port.isEmpty, port.allSatisfy({ ("0"..."9").contains($0) }) else { return (host, nil) }
        return (host, String(port))
    }

    /// `path` with every segment of ``longPathSegment`` or more characters shortened to its first
    /// and last ``shortenedSegmentEnds`` characters, joined by `…`.
    private static func shortenedPath(_ path: Substring.UnicodeScalarView) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            guard segment.count >= longPathSegment else { return String(segment) }
            return String(segment.prefix(shortenedSegmentEnds)) + "…" + String(segment.suffix(shortenedSegmentEnds))
        }.joined(separator: "/")
    }

    /// An RFC 3986 scheme: a letter, then letters, digits, `+`, `-` and `.`.
    private static func isScheme(_ scalars: Substring.UnicodeScalarView) -> Bool {
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }
        guard let first = scalars.first, isLetter(first) else { return false }
        return scalars.dropFirst().allSatisfy {
            isLetter($0) || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == "."
        }
    }
}
