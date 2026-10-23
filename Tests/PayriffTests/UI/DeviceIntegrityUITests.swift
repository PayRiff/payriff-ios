#if canImport(UIKit) && canImport(WebKit)
import Foundation
import Testing
import UIKit
@testable import Payriff

extension GlobalStateTests {
    /// Device integrity (CONTRACT §16.16) where a payment starts: `confirmCardPayment` and the
    /// payment view. Nested here because they configure the SDK and replace the device checks.
    @MainActor
    @Suite("Device integrity in confirmCardPayment and the payment view")
    struct DeviceIntegrityEntry {
        static let orderBody = #"{"code":"00000","payload":{"orderId":"o1","amount":1.02,"currency":"AZN","status":"CREATED","paymentMethods":["CARD"]}}"#

        /// `isDebugBuild` stands for the `DEBUG` condition of the SDK, the only build in which
        /// `allowCompromisedDevices` counts.
        private func configure(signals: [DeviceIntegritySignal], allowCompromisedDevices: Bool = false, isDebugBuild: Bool = true) -> FakeTransport {
            Payriff.reset()
            let transport = FakeTransport(status: 200, body: Self.orderBody)
            Payriff.services.transport = transport
            Payriff.services.deviceSignals = { signals }
            Payriff.services.isDebugBuild = isDebugBuild
            Payriff.configure(PayriffConfig(
                publishableKey: GlobalStateTests.publishableKey,
                environment: .sandbox,
                enableLogging: true,
                allowCompromisedDevices: allowCompromisedDevices
            ))
            return transport
        }

        @Test("confirmCardPayment refuses a compromised device first: DEVICE_COMPROMISED, nothing sent, the form untouched")
        func confirmRefused() async throws {
            let transport = configure(signals: [.frida])
            defer { Payriff.reset() }
            // An empty form would fail validation; the device is checked before it.
            let form = PayriffCardForm(showsHolder: false, language: .en)
            let result = await Payriff.confirmCardPayment(form, orderId: "o1", clientSecret: GlobalStateTests.clientSecret)
            #expect(result == .failed(.deviceCompromised))
            #expect(transport.requests.isEmpty)
            #expect(!Payriff.isPaymentInProgress)
            #expect(!form.isProcessing)
            #expect(form.textField(for: .number)?.isEnabled == true)
        }

        @Test("With allowCompromisedDevices in a debug build the payment goes on after a warning that names the signals")
        func confirmAllowed() async throws {
            let recorder = LogRecorder()
            recorder.install()
            let transport = configure(signals: [.debugger, .insertedLibraries], allowCompromisedDevices: true)
            defer {
                PayriffLogger.onLog = nil
                Payriff.reset()
            }
            let form = PayriffCardForm(showsHolder: false, language: .en)
            let result = await Payriff.confirmCardPayment(form, orderId: "o1", clientSecret: GlobalStateTests.clientSecret)
            #expect(result.error?.code == .validationFailed, "the empty form is checked next")
            #expect(transport.requests.isEmpty)
            #expect(recorder.all.contains { $0.level == .warning && $0.message.hasSuffix("Signals: debugger, DYLD_INSERT_LIBRARIES.") })
        }

        @Test("Outside debug builds confirmCardPayment ignores allowCompromisedDevices: DEVICE_COMPROMISED, nothing sent, a warning says so")
        func confirmOptOutIgnored() async throws {
            let recorder = LogRecorder()
            recorder.install()
            let transport = configure(signals: [.frida], allowCompromisedDevices: true, isDebugBuild: false)
            defer {
                PayriffLogger.onLog = nil
                Payriff.reset()
            }
            let form = PayriffCardForm(showsHolder: false, language: .en)
            let result = await Payriff.confirmCardPayment(form, orderId: "o1", clientSecret: GlobalStateTests.clientSecret)
            #expect(result == .failed(.deviceCompromised))
            #expect(transport.requests.isEmpty)
            #expect(!Payriff.isPaymentInProgress)
            #expect(recorder.contains(DeviceIntegrityPolicy.ignoredOptOutWarning), "configure says so")
            #expect(recorder.all.contains { $0.level == .warning && $0.message == "Device integrity: allowCompromisedDevices is ignored outside debug builds; card payments are refused on this device. Signals: Frida." })
        }

        @Test("The payment view on a compromised device: view.deviceNotSupported, Pay disabled, no order read, DEVICE_COMPROMISED reported once")
        func paymentViewRefused() async throws {
            let transport = configure(signals: [.jailbreakFiles])
            defer { Payriff.reset() }
            var results: [PayriffResult] = []
            let view = PayriffPaymentView(orderId: "o1", clientSecret: GlobalStateTests.clientSecret, language: .en) { results.append($0) }
            view.appear()
            #expect(results == [.failed(.deviceCompromised)])
            #expect(view.errorLabel.text == "Card payments aren't available on this device for security reasons")
            #expect(!view.errorLabel.isHidden)
            #expect(!view.payButton.isEnabled)
            #expect(view.payButton.title == "Pay")
            // Appearing again keeps the refusal and does not report it again.
            view.appear()
            view.language = .az
            #expect(view.errorLabel.text == "Təhlükəsizlik səbəbilə bu cihazda kartla ödəniş mümkün deyil")
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(results.count == 1)
            #expect(transport.requests.isEmpty, "the order is not read")

            // Pay does nothing.
            view.pay()
            #expect(!Payriff.isPaymentInProgress)
            #expect(results.count == 1)
        }

        @Test("The payment view with allowCompromisedDevices in a debug build reads the order as usual")
        func paymentViewAllowed() async throws {
            let transport = configure(signals: [.sandboxWrite], allowCompromisedDevices: true)
            defer { Payriff.reset() }
            var results: [PayriffResult] = []
            let view = PayriffPaymentView(orderId: "o1", clientSecret: GlobalStateTests.clientSecret, language: .en) { results.append($0) }
            view.appear()
            try await waitUntil(timeout: 10, "the order") { view.payButton.title == "Pay 1.02 AZN" }
            #expect(transport.requests.count == 1)
            #expect(results.isEmpty)
            #expect(view.errorLabel.isHidden)
        }

        @Test("Outside debug builds the payment view ignores allowCompromisedDevices: refused as without it")
        func paymentViewOptOutIgnored() async throws {
            let transport = configure(signals: [.sandboxWrite], allowCompromisedDevices: true, isDebugBuild: false)
            defer { Payriff.reset() }
            var results: [PayriffResult] = []
            let view = PayriffPaymentView(orderId: "o1", clientSecret: GlobalStateTests.clientSecret, language: .en) { results.append($0) }
            view.appear()
            #expect(results == [.failed(.deviceCompromised)])
            #expect(view.errorLabel.text == "Card payments aren't available on this device for security reasons")
            #expect(!view.payButton.isEnabled)
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(transport.requests.isEmpty, "the order is not read")
        }

        @Test("A clean device reads the order when the view appears")
        func paymentViewClean() async throws {
            let transport = configure(signals: [])
            defer { Payriff.reset() }
            let view = PayriffPaymentView(orderId: "o1", clientSecret: GlobalStateTests.clientSecret, language: .en)
            view.appear()
            try await waitUntil(timeout: 10, "the order") { view.payButton.title == "Pay 1.02 AZN" }
            #expect(transport.requests.count == 1)
            #expect(view.errorLabel.isHidden)
        }
    }
}
#endif
