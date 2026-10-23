import Foundation
import Testing
@testable import Payriff

/// Device integrity tests that touch process-wide state (`Payriff.services`, `PayriffLogger`); they
/// run in the serialized "Global state" suite.
extension GlobalStateTests {
    /// The device integrity entries (`Device integrity: …`) among `recorder`'s. Other suites run at
    /// the same time and log too; only these lines count in the policy tests.
    private static func deviceIntegrityEntries(_ recorder: LogRecorder) -> [PayriffLogEntry] {
        recorder.all.filter { $0.message.hasPrefix("Device integrity:") }
    }

    @Test("The policy: DEVICE_COMPROMISED by default; with allowCompromisedDevices in a debug build only a warning that names the signals")
    func deviceIntegrityPolicy() {
        let recorder = LogRecorder()
        recorder.install()
        defer { PayriffLogger.onLog = nil }
        PayriffLogger.isEnabled = true
        defer { PayriffLogger.isEnabled = false }
        func policyEntries() -> [PayriffLogEntry] { Self.deviceIntegrityEntries(recorder) }

        for isDebugBuild in [true, false] {
            #expect(DeviceIntegrityPolicy.decide([], allowCompromisedDevices: false, isDebugBuild: isDebugBuild) == nil)
            #expect(DeviceIntegrityPolicy.decide([], allowCompromisedDevices: true, isDebugBuild: isDebugBuild) == nil)
        }
        #expect(policyEntries().isEmpty, "a clean device logs nothing")

        for isDebugBuild in [true, false] {
            recorder.clear()
            let error = DeviceIntegrityPolicy.decide([.jailbreakFiles, .frida], allowCompromisedDevices: false, isDebugBuild: isDebugBuild)
            #expect(error == PayriffError.deviceCompromised)
            #expect(error?.code == .deviceCompromised)
            #expect(error?.message == "Card payments are not available on this device.")
            #expect(error?.isRetryable == false)
            #expect(error?.isFatal == false, "the order can still be paid on another device")
            #expect(policyEntries().map(\.level) == [.warning])
            #expect(policyEntries().first?.message == "Device integrity: card payments are refused on this device. Signals: jailbreak files, Frida.")
            #expect(DeviceIntegrityPolicy.decide([.checkFailed], allowCompromisedDevices: false, isDebugBuild: isDebugBuild) == PayriffError.deviceCompromised)
        }

        recorder.clear()
        #expect(DeviceIntegrityPolicy.decide([.debugger, .fridaServer], allowCompromisedDevices: true, isDebugBuild: true) == nil)
        #expect(policyEntries().map(\.level) == [.warning])
        #expect(policyEntries().first?.message == "Device integrity: allowCompromisedDevices is on, so the card payment continues on a compromised device. Signals: debugger, frida-server.")
    }

    @Test("Outside debug builds allowCompromisedDevices is ignored: the device is refused as without it, and a warning says so")
    func optOutIgnoredOutsideDebugBuilds() {
        let recorder = LogRecorder()
        recorder.install()
        defer { PayriffLogger.onLog = nil }
        PayriffLogger.isEnabled = true
        defer { PayriffLogger.isEnabled = false }

        let error = DeviceIntegrityPolicy.decide([.debugger, .fridaServer], allowCompromisedDevices: true, isDebugBuild: false)
        #expect(error == PayriffError.deviceCompromised)
        #expect(error?.message == "Card payments are not available on this device.")
        let entries = Self.deviceIntegrityEntries(recorder)
        #expect(entries.map(\.level) == [.warning])
        #expect(entries.first?.message == "Device integrity: allowCompromisedDevices is ignored outside debug builds; card payments are refused on this device. Signals: debugger, frida-server.")
        #expect(DeviceIntegrityPolicy.decide([.checkFailed], allowCompromisedDevices: true, isDebugBuild: false) == PayriffError.deviceCompromised, "fails closed")
    }

    @Test("The three payment checkpoints take the build from Payriff.services.isDebugBuild")
    func checkpointsFollowTheBuild() {
        Payriff.reset()
        defer { Payriff.reset() }
        Payriff.services.deviceSignals = { [.sandboxWrite] }
        Payriff.services.isDebugBuild = true
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: true) == nil)
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: false) == PayriffError.deviceCompromised)
        Payriff.services.isDebugBuild = false
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: true) == PayriffError.deviceCompromised, "ignored in a release build")
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: false) == PayriffError.deviceCompromised)
        Payriff.services.deviceSignals = { [] }
        #expect(Payriff.deviceIntegrityError(allowCompromisedDevices: true) == nil, "a clean device pays in every build")
        // The live value is the DEBUG condition, which the SDK and its tests are built with alike.
        Payriff.reset()
        #if DEBUG
        #expect(Payriff.services.isDebugBuild)
        #else
        #expect(!Payriff.services.isDebugBuild)
        #endif
    }

    @Test("configure warns once when allowCompromisedDevices is on outside a debug build")
    func configureWarnsAboutAnIgnoredOptOut() {
        Payriff.reset()
        let recorder = LogRecorder()
        recorder.install()
        defer {
            PayriffLogger.onLog = nil
            Payriff.reset()
        }
        let warning = "Device integrity: allowCompromisedDevices is ignored outside debug builds, so card payments are refused on a compromised device."
        #expect(DeviceIntegrityPolicy.ignoredOptOutWarning == warning)
        for (isDebugBuild, allows, warns) in [(false, true, true), (true, true, false), (false, false, false), (true, false, false)] {
            recorder.clear()
            Payriff.services.isDebugBuild = isDebugBuild
            Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox, enableLogging: true, allowCompromisedDevices: allows))
            let entries = recorder.all.filter { $0.message == warning }
            #expect(entries.map(\.level) == (warns ? [.warning] : []), "debug build: \(isDebugBuild), allowCompromisedDevices: \(allows)")
        }
    }

    @Test("isDeviceCompromised follows the checks, not allowCompromisedDevices; retrieveOrder is never blocked")
    func isDeviceCompromised() async throws {
        Payriff.reset()
        defer { Payriff.reset() }
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"o1","status":"CREATED","paymentMethods":["CARD"]}}"#)
        Payriff.services.transport = transport
        Payriff.services.deviceSignals = { [.hookingLibrary] }
        Payriff.services.isDebugBuild = true
        #expect(Payriff.isDeviceCompromised)
        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox, allowCompromisedDevices: true))
        #expect(Payriff.isDeviceCompromised, "the setting does not change the answer")
        Payriff.services.isDebugBuild = false
        #expect(Payriff.isDeviceCompromised, "nor does the build")
        Payriff.services.isDebugBuild = true
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
