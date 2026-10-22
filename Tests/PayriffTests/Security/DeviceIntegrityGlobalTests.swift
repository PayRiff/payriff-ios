import Foundation
import Testing
@testable import Payriff

/// Device integrity tests that touch process-wide state (`Payriff.services`, `PayriffLogger`); they
/// run in the serialized "Global state" suite.
extension GlobalStateTests {
    @Test("The policy: DEVICE_COMPROMISED by default; with allowCompromisedDevices only a warning that names the signals")
    func deviceIntegrityPolicy() {
        let recorder = LogRecorder()
        recorder.install()
        defer { PayriffLogger.onLog = nil }
        PayriffLogger.isEnabled = true
        defer { PayriffLogger.isEnabled = false }
        // Other suites run at the same time and log too; only this policy's lines count here.
        func policyEntries() -> [PayriffLogEntry] {
            recorder.all.filter { $0.message.hasPrefix("Device integrity:") }
        }

        #expect(DeviceIntegrityPolicy.decide([], allowCompromisedDevices: false) == nil)
        #expect(policyEntries().isEmpty, "a clean device logs nothing")

        let error = DeviceIntegrityPolicy.decide([.jailbreakFiles, .frida], allowCompromisedDevices: false)
        #expect(error == PayriffError.deviceCompromised)
        #expect(error?.code == .deviceCompromised)
        #expect(error?.message == "Card payments are not available on this device.")
        #expect(error?.isRetryable == false)
        #expect(error?.isFatal == false, "the order can still be paid on another device")
        #expect(policyEntries().map(\.level) == [.warning])
        #expect(policyEntries().first?.message == "Device integrity: card payments are refused on this device. Signals: jailbreak files, Frida.")
        #expect(DeviceIntegrityPolicy.decide([.checkFailed], allowCompromisedDevices: false) == PayriffError.deviceCompromised)

        recorder.clear()
        #expect(DeviceIntegrityPolicy.decide([.debugger, .fridaServer], allowCompromisedDevices: true) == nil)
        #expect(policyEntries().map(\.level) == [.warning])
        #expect(policyEntries().first?.message == "Device integrity: allowCompromisedDevices is on, so the card payment continues on a compromised device. Signals: debugger, frida-server.")
    }

    @Test("isDeviceCompromised follows the checks, not allowCompromisedDevices; retrieveOrder is never blocked")
    func isDeviceCompromised() async throws {
        Payriff.reset()
        defer { Payriff.reset() }
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"o1","status":"CREATED","paymentMethods":["CARD"]}}"#)
        Payriff.services.transport = transport
        Payriff.services.deviceSignals = { [.hookingLibrary] }
        #expect(Payriff.isDeviceCompromised)
        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox, allowCompromisedDevices: true))
        #expect(Payriff.isDeviceCompromised, "the setting does not change the answer")
        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox))
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: false) == PayriffError.deviceCompromised)
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: true) == nil)

        // Reading the order sends nothing card-related, so it is never blocked.
        let order = try await Payriff.retrieveOrder(orderId: "o1", clientSecret: Self.clientSecret)
        #expect(order.isPayableByCard)
        #expect(transport.requests.count == 1)

        Payriff.services.deviceSignals = { [] }
        #expect(!Payriff.isDeviceCompromised)
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: false) == nil)
        // The live checks find nothing on a Mac.
        Payriff.reset()
        #expect(!Payriff.isDeviceCompromised)
    }
}
