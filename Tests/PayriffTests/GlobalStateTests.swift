import Foundation
import Testing
@testable import Payriff

/// Tests that touch process-wide state (`Payriff.configure`, `PayriffLogger`) run one at a time.
@MainActor
@Suite("Global state", .serialized)
struct GlobalStateTests {
    init() {
        Payriff.reset()
        PayriffLogger.onLog = nil
    }

    // MARK: Configuration (CONTRACT §3.0, §16.2)

    @Test("Every call before configure fails with NOT_CONFIGURED; configure itself never throws")
    func everyCallNeedsConfigure() async {
        Payriff.reset()
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"o1","status":"CREATED","paymentMethods":["CARD"]}}"#)
        Payriff.services.transport = transport
        do {
            _ = try await Payriff.retrieveOrder(orderId: "o1", clientSecret: Self.clientSecret)
            Issue.record("expected NOT_CONFIGURED")
        } catch {
            #expect(error.code == .notConfigured)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("configure logs a missing or invalid publishable key as a warning; every call then fails with INVALID_CONFIG")
    func invalidPublishableKey() async {
        let recorder = LogRecorder()
        recorder.install()
        defer { PayriffLogger.onLog = nil }
        let transport = FakeTransport(status: 200, body: "{}")
        Payriff.services.transport = transport
        let warning = "Invalid configuration: publishableKey must be a Payriff publishable key (pr_pk_live_…)."
        for key in [nil, "  ", "0123456789ABCDEF0123456789ABCDEF", "pk_live_abc", "pr_pk_live_"] as [String?] {
            recorder.clear()
            Payriff.configure(PayriffConfig(publishableKey: key, environment: .sandbox, enableLogging: true))
            #expect(recorder.all.contains { $0.level == .warning && $0.message.hasPrefix(warning) }, "\(String(describing: key))")
            do {
                _ = try await Payriff.retrieveOrder(orderId: "o1", clientSecret: Self.clientSecret)
                Issue.record("expected INVALID_CONFIG for \(String(describing: key))")
            } catch {
                #expect(error.code == .invalidConfig)
            }
        }
        recorder.clear()
        Payriff.configure(PayriffConfig(publishableKey: " \(Self.publishableKey) ", environment: .sandbox, enableLogging: true))
        #expect(!recorder.all.contains { $0.level == .warning })
        #expect(transport.requests.isEmpty, "nothing is sent with an invalid configuration")
    }

    // MARK: Logging (CONTRACT §11)

    @Test("Logging is off by default and on with enableLogging")
    func loggingToggle() {
        let recorder = LogRecorder()
        recorder.install()
        Payriff.configure(PayriffConfig(environment: .sandbox))
        Log.info("hidden-entry")
        #expect(!recorder.contains("hidden-entry"))
        Payriff.configure(PayriffConfig(environment: .sandbox, enableLogging: true))
        Log.warning("visible-entry")
        let entry = recorder.all.first { $0.message == "visible-entry" }
        #expect(entry?.level == .warning)
        #expect(entry?.formatted == "[Payriff] [WARNING] visible-entry")
        PayriffLogger.onLog = nil
    }

    @Test("configure logs whether a publishable key is set, never the key; URLs lose their query and credentials")
    func redaction() {
        let recorder = LogRecorder()
        recorder.install()
        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox, language: .ru, enableLogging: true))
        #expect(recorder.contains("Configured Payriff \(Payriff.version): environment=sandbox publishableKey=set language=RU"))
        #expect(!recorder.all.contains { $0.message.contains(Self.publishableKey) })
        Payriff.configure(PayriffConfig(enableLogging: true))
        #expect(recorder.contains("environment=production publishableKey=none language=device"))
        #expect(Log.redactedURL(URL(string: "https://user:pass@acs.bank.example/challenge?id=1#x")) == "https://acs.bank.example/challenge")
        PayriffLogger.onLog = nil
    }
}
