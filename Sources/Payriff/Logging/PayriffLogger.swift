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
/// header, URL query strings, non-http(s) URL contents or card data.
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
/// Entries never contain secrets or card data, but they do contain order ids, statuses,
/// amounts and URL paths. Keep them in your own diagnostics; do not forward them to
/// third-party analytics.
///
/// In debug builds, `debug` entries also show every API request and response as pretty-printed
/// JSON (`HTTP request` / `HTTP response`: method, URL, headers and body), with secrets redacted
/// (`***(<length>)`) and URLs without query or fragment. Release builds never log them.
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
    /// Lines contain order ids, statuses, amounts and URL paths. In the unified log they are
    /// public only in debug builds; release builds mark them private, so Console and
    /// sysdiagnose archives show `<private>` (``onLog`` still receives the full text).
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

    /// A URL as it may appear in logs (CONTRACT §11): an http(s) URL without its query string,
    /// fragment and credentials, shortened to a readable length; any other scheme only as
    /// `<scheme>:…`, so a `tel:` number, a `mailto:` address or `data:`/`javascript:` content
    /// never reaches the logs.
    static func redactedURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        if let scheme = url.scheme?.lowercased(), !scheme.isEmpty, scheme != "http", scheme != "https" {
            return "\(scheme):…"
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return "…"
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        let text = components.string ?? "…"
        let limit = 160
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
