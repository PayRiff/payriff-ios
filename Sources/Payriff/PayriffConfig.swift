import Foundation

/// The Payriff environment a payment runs against. Together with ``PayriffRegion`` it picks the
/// API host (``PayriffConfig/apiBaseURL``).
public enum PayriffEnvironment: String, Sendable, Hashable, Codable, CaseIterable {
    /// Live payments: API `https://api.payriff.com` in region ``PayriffRegion/az``,
    /// `https://api.gccpay.sa` in region ``PayriffRegion/sa``.
    case production
    /// Test payments: API `https://sb-api.payriff.com`, the sandbox of region ``PayriffRegion/az``
    /// (provisional, CONTRACT §16.2). Region ``PayriffRegion/sa`` has no sandbox: its sandbox
    /// payments go to production (`https://api.gccpay.sa`) and charge real cards.
    case sandbox
}

/// The Payriff region whose API the SDK calls (CONTRACT §16.2). Together with
/// ``PayriffEnvironment`` it picks the API host (``PayriffConfig/apiBaseURL``).
public enum PayriffRegion: String, Sendable, Hashable, Codable, CaseIterable {
    /// Azerbaijan, the default: API `https://api.payriff.com`, sandbox `https://sb-api.payriff.com`.
    case az
    /// Saudi Arabia (GCC Pay): API `https://api.gccpay.sa`. There is no Saudi sandbox: with
    /// ``PayriffEnvironment/sandbox`` payments go to production and charge real cards, and
    /// ``Payriff/configure(_:)`` logs a warning.
    case sa
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
    /// In region ``PayriffRegion/az`` the SDK talks to `https://api.payriff.com` in production and
    /// to `https://sb-api.payriff.com` in the sandbox (see ``apiBaseURL``).
    public var environment: PayriffEnvironment

    /// The region whose API the SDK calls. Defaults to ``PayriffRegion/az``.
    ///
    /// ``PayriffRegion/sa`` (Saudi Arabia, GCC Pay) talks to `https://api.gccpay.sa`. It has no
    /// sandbox: with ``PayriffEnvironment/sandbox`` payments go to production and charge real
    /// cards, and ``Payriff/configure(_:)`` logs a warning.
    public var region: PayriffRegion

    /// The default language of the card form and the 3-D Secure sheet. `nil` uses the device
    /// language. ``PayriffCardForm/language`` takes precedence.
    public var language: PayriffLanguage?

    /// Enables SDK logging (see ``PayriffLogger``). Defaults to `false`.
    public var enableLogging: Bool

    /// Lets card payments run on a compromised device in debug builds, for development on
    /// jailbroken test devices (CONTRACT §16.16). Defaults to `false`.
    ///
    /// By default the SDK refuses card payments on a jailbroken device and when a hooking tool such
    /// as Frida or, in an App Store or TestFlight build, a debugger is found: they fail with
    /// `DEVICE_COMPROMISED`, and ``PayriffPaymentView`` says that card payments aren't available on
    /// this device. With `true` the SDK only logs a warning that names what it found.
    ///
    /// It works only in debug builds: when the SDK is compiled with the `DEBUG` condition, which
    /// follows your app's build configuration with Swift Package Manager and CocoaPods. In any
    /// other build, such as a Release build for the App Store or TestFlight, the SDK ignores it and
    /// logs a warning, and a compromised device is refused as with `false`, so leaving it on can
    /// never reach your customers.
    public var allowCompromisedDevices: Bool

    /// The API base URL the SDK calls for ``region`` and ``environment`` (CONTRACT §16.2):
    ///
    /// | Region | Environment | API base URL |
    /// |---|---|---|
    /// | `az` | production | `https://api.payriff.com` |
    /// | `az` | sandbox | `https://sb-api.payriff.com` (provisional) |
    /// | `sa` | production | `https://api.gccpay.sa` |
    /// | `sa` | sandbox | `https://api.gccpay.sa`: no Saudi sandbox, payments go to production |
    public var apiBaseURL: URL {
        URL(string: ClientAPIHost.baseURL(region: region, environment: environment))!
    }

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - publishableKey: The publishable key (`pr_pk_live_…`).
    ///   - environment: The environment. Defaults to production.
    ///   - region: The region. Defaults to ``PayriffRegion/az``.
    ///   - language: The default language, or `nil` for the device language.
    ///   - enableLogging: Whether the SDK emits log entries.
    ///   - allowCompromisedDevices: Whether card payments run on a jailbroken or hooked device;
    ///     ignored outside debug builds. Defaults to `false`.
    public init(
        publishableKey: String? = nil,
        environment: PayriffEnvironment = .production,
        region: PayriffRegion = .az,
        language: PayriffLanguage? = nil,
        enableLogging: Bool = false,
        allowCompromisedDevices: Bool = false
    ) {
        self.publishableKey = publishableKey
        self.environment = environment
        self.region = region
        self.language = language
        self.enableLogging = enableLogging
        self.allowCompromisedDevices = allowCompromisedDevices
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
            RedactedField("region", region, text: region.rawValue),
            RedactedField("language", optional: language?.rawValue),
            RedactedField("enableLogging", enableLogging),
            RedactedField("allowCompromisedDevices", allowCompromisedDevices),
        ]
    }
}
