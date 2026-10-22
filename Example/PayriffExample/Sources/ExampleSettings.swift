import Foundation
import Payriff

/// The example app's settings, read from Info.plist. Debug builds fill them from the git-ignored
/// `Example/Config/Secrets.xcconfig`. There is no secret key: orders come from your server.
struct ExampleSettings: Equatable {
    var environment: PayriffEnvironment
    /// The publishable key (`pr_pk_live_…`).
    var publishableKey: String

    /// The values baked into the app from the xcconfig files.
    static func fromInfoPlist(_ bundle: Bundle = .main) -> ExampleSettings {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ExampleSettings(
            environment: PayriffEnvironment(rawValue: value("PayriffEnvironment").lowercased()) ?? .sandbox,
            publishableKey: value("PayriffPublishableKey")
        )
    }

    var hasPublishableKey: Bool { !publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The SDK configuration for these settings, in the device language. The example always logs:
    /// Debug builds write the SDK log to `Documents/payriff-sdk.log`.
    var config: PayriffConfig {
        PayriffConfig(
            publishableKey: hasPublishableKey ? publishableKey : nil,
            environment: environment,
            enableLogging: true
        )
    }
}
