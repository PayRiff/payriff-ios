import Foundation

/// The Payriff environment a payment runs against.
public enum PayriffEnvironment: String, Sendable, Hashable, Codable, CaseIterable {
    /// Live payments: API `https://api.payriff.com`.
    case production
    /// Test payments: API `https://sb-api.payriff.com` (provisional, CONTRACT §16.2).
    case sandbox

    /// The API base URL the SDK calls in this environment (CONTRACT §16.2).
    public var apiBaseURL: URL {
        URL(string: ClientAPIHost.baseURL(for: self))!
    }
}

/// SDK-wide configuration, passed to ``Payriff/configure(_:)``.
///
/// Calling `configure` again replaces the configuration for later calls only; a payment that is
/// already running keeps the configuration it started with. The card form's appearance is set on
/// the form itself (``PayriffCardForm/style``).
///
/// The textual representations (`description`, `debugDescription` and the mirror used by
/// `dump`) show the publishable key only as its `pr_pk_live_` prefix and length.
public struct PayriffConfig: Sendable {
    /// The publishable key (`pr_pk_live_…`) of your Payriff application (CONTRACT §16.2).
    ///
    /// ``Payriff/confirmCardPayment(_:orderId:clientSecret:from:)`` and
    /// ``Payriff/retrieveOrder(orderId:clientSecret:)`` call Payriff's Client API with this key and
    /// the order's `clientSecret`. The key is trimmed; a missing key, or one that does not start
    /// with `pr_pk_live_` (a secret key is always refused), makes those calls fail with
    /// `INVALID_CONFIG`. The merchant secret key never belongs in the app: your server creates
    /// orders with it.
    public var publishableKey: String?

    /// The environment to use. Defaults to ``PayriffEnvironment/production``.
    ///
    /// The SDK talks to `https://api.payriff.com` in production and to
    /// `https://sb-api.payriff.com` in the sandbox.
    public var environment: PayriffEnvironment

    /// The default language of the card form and the 3-D Secure sheet. `nil` uses the device
    /// language. ``PayriffCardForm/language`` takes precedence.
    public var language: PayriffLanguage?

    /// Enables SDK logging (see ``PayriffLogger``). Defaults to `false`.
    public var enableLogging: Bool

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - publishableKey: The publishable key (`pr_pk_live_…`).
    ///   - environment: The environment. Defaults to production.
    ///   - language: The default language, or `nil` for the device language.
    ///   - enableLogging: Whether the SDK emits log entries.
    public init(
        publishableKey: String? = nil,
        environment: PayriffEnvironment = .production,
        language: PayriffLanguage? = nil,
        enableLogging: Bool = false
    ) {
        self.publishableKey = publishableKey
        self.environment = environment
        self.language = language
        self.enableLogging = enableLogging
    }
}

extension PayriffConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A description with the publishable key shown only as its prefix and length.
    public var description: String {
        "PayriffConfig(" + redactedFields.map { "\($0.label): \($0.text)" }.joined(separator: ", ") + ")"
    }

    /// The same redacted text as ``description``.
    public var debugDescription: String { description }

    /// A mirror with the same redacted values, so `dump(config)` never shows the publishable key.
    public var customMirror: Mirror {
        Mirror(self, children: redactedFields.map { (label: Optional($0.label), value: $0.value) }, displayStyle: .struct)
    }

    /// One property in its redacted form: `text` for the description, `value` for the mirror.
    private struct RedactedField {
        let label: String
        let text: String
        let value: Any

        init(_ label: String, _ value: some Any, text: String? = nil) {
            self.label = label
            self.value = value
            self.text = text ?? "\(value)"
        }

        init(_ label: String, optional: String?) {
            self.label = label
            self.value = optional as Any
            self.text = optional ?? "nil"
        }
    }

    private var redactedFields: [RedactedField] {
        [
            RedactedField("publishableKey", optional: ResponseParser.nonBlank(publishableKey).map { key in
                key.hasPrefix(ClientCredentials.publishableKeyPrefix)
                    ? "\(ClientCredentials.publishableKeyPrefix)***(\(key.count))"
                    : "***(\(key.count))"
            }),
            RedactedField("environment", environment, text: environment.rawValue),
            RedactedField("language", optional: language?.rawValue),
            RedactedField("enableLogging", enableLogging),
        ]
    }
}
