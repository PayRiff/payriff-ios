import Foundation

/// The entry point of the Payriff SDK.
///
/// Your server creates the order with its secret key and gives the app the order's `orderId`
/// and `clientSecret`. The app shows ``PayriffCardForm`` and pays the order with the publishable
/// key:
///
/// ```swift
/// Payriff.configure(PayriffConfig(publishableKey: "pr_pk_live_…", environment: .production))
///
/// let result = await Payriff.confirmCardPayment(form, orderId: orderId, clientSecret: clientSecret)
/// ```
///
/// All members run on the main actor.
@MainActor
public enum Payriff {
    /// The SDK version.
    public static let version = "1.0.0"

    /// The configuration set by ``configure(_:)``.
    static private(set) var configuration: PayriffConfig?

    /// Replaceable services; tests swap the transport, the clock and the device checks.
    static var services = Services.live

    /// Services the SDK depends on.
    struct Services: Sendable {
        /// The Client API transport. The live one pins Payriff's certificates (CONTRACT §16.15);
        /// a test transport replaces it whole.
        var transport: any PayriffHTTPTransport
        var clock: any PaymentClock
        var deviceLanguage: @Sendable () -> PayriffLanguage
        /// The app identity sent as `X-Client-App-Id` (CONTRACT §16.2): the bundle id, or `nil`
        /// to omit the header.
        var clientAppId: @Sendable () -> String?
        /// Whether this is a debug build: the `DEBUG` compilation condition of this module, which
        /// follows the app's build configuration for Swift Package Manager and CocoaPods. Release
        /// builds never log request and response details (§11, ``HTTPLog``); tests switch this to
        /// exercise both.
        var isDebugBuild: Bool
        /// The device integrity signals that match now (CONTRACT §16.16, ``DeviceIntegrity``).
        var deviceSignals: @Sendable () -> [DeviceIntegritySignal]

        static let live = Services(
            transport: URLSessionTransport.shared,
            clock: SystemPaymentClock(),
            deviceLanguage: { PayriffLanguage.device },
            clientAppId: { ClientAppID.current },
            isDebugBuild: compiledForDebug,
            deviceSignals: { DeviceIntegrity.shared.signals() }
        )

        private static var compiledForDebug: Bool {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }

    /// Configures the SDK. Call it once at app launch; calling it again replaces the
    /// configuration for later calls only.
    ///
    /// `configure` never throws. The publishable key is trimmed. A missing key, or one that does
    /// not start with `pr_pk_live_` (a secret key is always refused), is logged as a warning
    /// (`Invalid configuration: …`), and every later call fails with `INVALID_CONFIG`:
    /// ``confirmCardPayment(_:orderId:clientSecret:from:)`` returns ``PayriffResult/failed(_:)``
    /// and ``retrieveOrder(orderId:clientSecret:)`` throws.
    ///
    /// - Parameter config: The configuration.
    public static func configure(_ config: PayriffConfig) {
        configuration = config
        PayriffLogger.isEnabled = config.enableLogging
        Log.info("Configured Payriff \(version): environment=\(config.environment.rawValue) publishableKey=\(ResponseParser.nonBlank(config.publishableKey) == nil ? "none" : "set") language=\(config.language?.rawValue ?? "device")")
        if case .failure(let problem) = ClientCredentials.publishableKey(config.publishableKey) {
            Log.warning("Invalid configuration: \(problem.message)")
        }
    }

    /// The configuration set by ``configure(_:)``, or `NOT_CONFIGURED` when `configure` was
    /// never called.
    static func currentConfiguration() -> Result<PayriffConfig, PayriffError> {
        guard let configuration else { return .failure(.notConfigured()) }
        return .success(configuration)
    }

    /// Resets the SDK state. Used by tests.
    static func reset() {
        configuration = nil
        activeCardFlow = nil
        services = .live
        PayriffLogger.isEnabled = false
    }
}
