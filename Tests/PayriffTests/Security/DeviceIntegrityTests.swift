import Darwin
import Foundation
import os
import Testing
@testable import Payriff

/// ``DeviceIntegrityProbes`` with set answers; it counts what it was asked.
final class FakeDeviceProbes: DeviceIntegrityProbes {
    struct Answers: Sendable {
        var isSimulatorOrMac = false
        var hasEmbeddedProvisioningProfile = false
        var existingFiles: Set<String> = []
        var canCreateFile = false
        var loadedImages = FakeDeviceProbes.cleanImages
        var environment: [String: String] = [:]
        var fridaServer: Bool? = false
        var traced: Bool? = false
    }

    struct Calls: Sendable {
        var fileExists: [String] = []
        var createFile: [String] = []
        var loadedImages = 0
        var environment: [String] = []
        var loopback: [UInt16] = []
        var loopbackTimeouts: [TimeInterval] = []
        var traced = 0
    }

    /// The images of an ordinary app.
    static let cleanImages = [
        "/private/var/containers/Bundle/Application/0F1E/Shop.app/Shop",
        "/usr/lib/libSystem.B.dylib",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/UIKit.framework/UIKit",
        "/private/var/containers/Bundle/Application/0F1E/Shop.app/Frameworks/Payriff.framework/Payriff",
    ]

    private let state: OSAllocatedUnfairLock<(answers: Answers, calls: Calls)>

    init(_ answers: Answers = Answers()) {
        state = OSAllocatedUnfairLock(initialState: (answers, Calls()))
    }

    var answers: Answers {
        get { state.withLock { $0.answers } }
        set { state.withLock { $0.answers = newValue } }
    }

    var calls: Calls { state.withLock { $0.calls } }

    var isSimulatorOrMac: Bool { answers.isSimulatorOrMac }
    var hasEmbeddedProvisioningProfile: Bool { answers.hasEmbeddedProvisioningProfile }

    func fileExists(atPath path: String) -> Bool {
        state.withLock { state in
            state.calls.fileExists.append(path)
            return state.answers.existingFiles.contains(path)
        }
    }

    func canCreateFile(atPath path: String) -> Bool {
        state.withLock { state in
            state.calls.createFile.append(path)
            return state.answers.canCreateFile
        }
    }

    func loadedImagePaths() -> [String] {
        state.withLock { state in
            state.calls.loadedImages += 1
            return state.answers.loadedImages
        }
    }

    func environmentValue(_ name: String) -> String? {
        state.withLock { state in
            state.calls.environment.append(name)
            return state.answers.environment[name]
        }
    }

    func acceptsLoopbackConnection(port: UInt16, timeout: TimeInterval) throws -> Bool {
        let answer: Bool? = state.withLock { state in
            state.calls.loopback.append(port)
            state.calls.loopbackTimeouts.append(timeout)
            return state.answers.fridaServer
        }
        guard let answer else { throw DeviceProbeError.unavailable }
        return answer
    }

    func isTraced() throws -> Bool {
        let answer: Bool? = state.withLock { state in
            state.calls.traced += 1
            return state.answers.traced
        }
        guard let answer else { throw DeviceProbeError.unavailable }
        return answer
    }
}

/// Device integrity (CONTRACT §16.16): the iOS signals and the rules that decide them, with fake
/// probes; then the probes that read this Mac.
@Suite("Device integrity")
struct DeviceIntegrityTests {
    typealias Answers = FakeDeviceProbes.Answers

    private static func signals(_ answers: Answers) -> [DeviceIntegritySignal] {
        DeviceIntegrity(probes: FakeDeviceProbes(answers)).signals()
    }

    @Test("A clean device, App Store build: no signal")
    func clean() {
        let probes = FakeDeviceProbes()
        #expect(DeviceIntegrity(probes: probes).signals().isEmpty)
        // Every check ran.
        #expect(probes.calls.fileExists == DeviceIntegrity.jailbreakPaths)
        #expect(probes.calls.createFile == ["/private/payriff-jb-check"])
        #expect(probes.calls.loadedImages == 1)
        #expect(probes.calls.environment == ["DYLD_INSERT_LIBRARIES"])
        #expect(probes.calls.loopback == [27042] && probes.calls.loopbackTimeouts == [0.1])
        #expect(probes.calls.traced == 1)
    }

    @Test("Each jailbreak file on its own is the signal 'jailbreak files'", arguments: DeviceIntegrity.jailbreakPaths)
    func jailbreakFile(_ path: String) {
        var answers = Answers()
        answers.existingFiles = [path]
        #expect(Self.signals(answers) == [.jailbreakFiles])
    }

    @Test("The list of jailbreak files is the contract's")
    func jailbreakFileList() {
        #expect(DeviceIntegrity.jailbreakPaths == [
            "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app", "/Applications/Filza.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/sbin/sshd", "/usr/bin/sshd", "/usr/libexec/sftp-server",
            "/etc/apt", "/private/var/lib/apt/", "/private/var/lib/cydia", "/private/var/stash", "/var/jb", "/private/preboot/jb",
            "/usr/lib/TweakInject", "/usr/lib/libhooker.dylib", "/usr/lib/libsubstitute.dylib", "/.bootstrapped",
            "/.installed_unc0ver", "/bin/bash",
        ])
        #expect(DeviceIntegrity.sandboxProbePath == "/private/payriff-jb-check")
    }

    @Test("A write outside the sandbox on its own is the signal 'sandbox write'")
    func sandboxWrite() {
        var answers = Answers()
        answers.canCreateFile = true
        #expect(Self.signals(answers) == [.sandboxWrite])
    }

    @Test(
        "A loaded image whose path contains a hooking library's name is a signal, matched as written",
        arguments: [
            ("/Library/MobileSubstrate/MobileSubstrate.dylib", DeviceIntegritySignal.hookingLibrary),
            ("/usr/lib/substrate/SubstrateLoader.dylib", .hookingLibrary),
            ("/usr/lib/TweakInject.dylib", .hookingLibrary),
            ("/usr/lib/libhooker.dylib", .hookingLibrary),
            ("/usr/lib/libsubstitute.dylib", .hookingLibrary),
            ("/var/jb/usr/lib/libellekit.dylib", .hookingLibrary),
            ("/var/jb/basebin/systemhook.dylib", .hookingLibrary),
            ("/Library/MobileSubstrate/DynamicLibraries/SSLKillSwitch2.dylib", .hookingLibrary),
            ("/usr/lib/cynject.dylib", .hookingLibrary),
            ("/usr/lib/libcycript.dylib", .hookingLibrary),
            ("/private/var/containers/Bundle/Application/0F1E/Shop.app/Frameworks/FridaGadget.dylib", .frida),
            ("/usr/lib/frida/frida-agent.dylib", .frida),
        ]
    )
    func hookingLibrary(path: String, signal: DeviceIntegritySignal) {
        var answers = Answers()
        answers.loadedImages = FakeDeviceProbes.cleanImages + [path]
        #expect(Self.signals(answers) == [signal])
    }

    @Test("Library names count only as written: an app called Frida or Substitute is not a hooking tool")
    func libraryNamesAsWritten() {
        #expect(DeviceIntegrity.hookingLibraryNames + DeviceIntegrity.fridaLibraryNames == [
            "MobileSubstrate", "SubstrateLoader", "TweakInject", "libhooker", "substitute", "ellekit", "systemhook",
            "SSLKillSwitch", "cynject", "libcycript", "FridaGadget", "frida",
        ])
        var answers = Answers()
        answers.loadedImages = FakeDeviceProbes.cleanImages + [
            "/private/var/containers/Bundle/Application/0F1E/Frida.app/Frida",
            "/private/var/containers/Bundle/Application/0F1E/Frida.app/Frameworks/Substitute.framework/Substitute",
        ]
        #expect(Self.signals(answers).isEmpty)
    }

    @Test("A frida-server on 127.0.0.1:27042 on its own is the signal 'frida-server'")
    func fridaServer() {
        var answers = Answers()
        answers.fridaServer = true
        #expect(Self.signals(answers) == [.fridaServer])
        answers.hasEmbeddedProvisioningProfile = true
        #expect(Self.signals(answers) == [.fridaServer], "in every build")
    }

    @Test("A debugger and DYLD_INSERT_LIBRARIES count only in App Store and TestFlight builds (no embedded.mobileprovision)")
    func storeBuildRules() {
        var store = Answers()
        store.traced = true
        #expect(Self.signals(store) == [.debugger])
        store.traced = false
        store.environment = ["DYLD_INSERT_LIBRARIES": "/usr/lib/libMainThreadChecker.dylib"]
        #expect(Self.signals(store) == [.insertedLibraries])
        store.environment = ["DYLD_INSERT_LIBRARIES": ""]
        #expect(Self.signals(store).isEmpty, "an empty value inserts nothing")

        // Xcode runs development builds with its debugger and its diagnostics libraries.
        var development = Answers()
        development.hasEmbeddedProvisioningProfile = true
        development.traced = true
        development.environment = ["DYLD_INSERT_LIBRARIES": "/usr/lib/libMainThreadChecker.dylib"]
        let probes = FakeDeviceProbes(development)
        #expect(DeviceIntegrity(probes: probes).signals().isEmpty)
        #expect(probes.calls.traced == 0, "the debugger is not even checked")
        #expect(probes.calls.environment.isEmpty)
    }

    @Test("A check that cannot complete counts as 'check failed' (fail closed)")
    func checkFailed() {
        var answers = Answers()
        answers.fridaServer = nil
        #expect(Self.signals(answers) == [.checkFailed])
        answers.fridaServer = false
        answers.traced = nil
        #expect(Self.signals(answers) == [.checkFailed])
        answers.fridaServer = nil
        #expect(Self.signals(answers) == [.checkFailed], "named once")
        // The debugger check does not run in a development build, so it cannot fail there.
        answers.fridaServer = false
        answers.hasEmbeddedProvisioningProfile = true
        #expect(Self.signals(answers).isEmpty)
    }

    @Test("Every signal at once: each named once, files first")
    func everySignal() {
        var answers = Answers()
        answers.existingFiles = Set(DeviceIntegrity.jailbreakPaths)
        answers.canCreateFile = true
        answers.loadedImages += ["/usr/lib/libhooker.dylib", "/usr/lib/TweakInject.dylib", "/x/FridaGadget.dylib", "/usr/lib/frida/frida-agent.dylib"]
        answers.environment = ["DYLD_INSERT_LIBRARIES": "/x/inject.dylib"]
        answers.fridaServer = true
        answers.traced = true
        #expect(Self.signals(answers) == [.jailbreakFiles, .sandboxWrite, .hookingLibrary, .frida, .insertedLibraries, .fridaServer, .debugger])
    }

    @Test("Nothing is checked on the simulator or on a Mac, whose file system is the Mac's")
    func simulatorAndMac() {
        var answers = Answers()
        answers.isSimulatorOrMac = true
        answers.existingFiles = Set(DeviceIntegrity.jailbreakPaths)
        answers.canCreateFile = true
        answers.loadedImages += ["/usr/lib/frida/frida-agent.dylib"]
        answers.environment = ["DYLD_INSERT_LIBRARIES": "/x/inject.dylib"]
        answers.fridaServer = true
        answers.traced = true
        let probes = FakeDeviceProbes(answers)
        #expect(DeviceIntegrity(probes: probes).signals().isEmpty)
        let calls = probes.calls
        #expect(calls.fileExists.isEmpty && calls.createFile.isEmpty && calls.loadedImages == 0 && calls.loopback.isEmpty && calls.traced == 0)
    }

    @Test("The file checks run once per process; the hooking, Frida and debugger checks run fresh every time")
    func caching() {
        let probes = FakeDeviceProbes()
        let integrity = DeviceIntegrity(probes: probes)
        #expect(integrity.signals().isEmpty)
        // A tool attaches after the first check; a jailbreak file that appears now is not looked for again.
        var answers = probes.answers
        answers.existingFiles = ["/var/jb"]
        answers.canCreateFile = true
        answers.loadedImages += ["/usr/lib/frida/frida-agent.dylib"]
        answers.fridaServer = true
        answers.traced = true
        probes.answers = answers
        #expect(integrity.signals() == [.frida, .fridaServer, .debugger])
        #expect(integrity.signals() == [.frida, .fridaServer, .debugger])
        let calls = probes.calls
        #expect(calls.fileExists.count == DeviceIntegrity.jailbreakPaths.count, "the files were looked for once")
        #expect(calls.createFile.count == 1)
        #expect(calls.loadedImages == 3 && calls.loopback.count == 3 && calls.traced == 3)

        // A jailbroken device stays so for the process, also when the tool detaches.
        var jailbroken = Answers()
        jailbroken.existingFiles = ["/Applications/Sileo.app"]
        jailbroken.fridaServer = true
        let flagged = FakeDeviceProbes(jailbroken)
        let cached = DeviceIntegrity(probes: flagged)
        #expect(cached.signals() == [.jailbreakFiles, .fridaServer])
        var clean = flagged.answers
        clean.existingFiles = []
        clean.fridaServer = false
        flagged.answers = clean
        #expect(cached.signals() == [.jailbreakFiles])
    }

    @Test("The signals' names in the log")
    func signalNames() {
        #expect(DeviceIntegritySignal.allCases.map(\.rawValue) == [
            "jailbreak files", "sandbox write", "hooking library", "Frida", "DYLD_INSERT_LIBRARIES", "frida-server", "debugger", "check failed",
        ])
    }

    // MARK: The probes of this Mac

    @Test("On a Mac nothing is checked, so the shared checks find nothing here")
    func sharedChecksOnAMac() {
        #expect(SystemDeviceProbes().isSimulatorOrMac)
        #expect(DeviceIntegrity.shared.signals().isEmpty)
    }

    @Test("The file probe creates and removes the file, or reports that it cannot")
    func fileProbe() throws {
        let probes = SystemDeviceProbes()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("payriff-probe-\(UUID().uuidString)").path
        #expect(!probes.fileExists(atPath: path))
        #expect(probes.canCreateFile(atPath: path))
        #expect(!probes.fileExists(atPath: path), "removed again at once")
        #expect(!probes.canCreateFile(atPath: "/payriff-probe-\(UUID().uuidString)/x"), "no such directory")
        #expect(probes.fileExists(atPath: FileManager.default.temporaryDirectory.path))
        #expect(!probes.loadedImagePaths().isEmpty)
        #expect(probes.loadedImagePaths().contains { $0.contains("libSystem") })
        #expect(probes.environmentValue("PAYRIFF_UNSET_\(UUID().uuidString.prefix(8))") == nil)
        #expect(throws: Never.self) { _ = try probes.isTraced() }
    }

    /// A TCP listener on 127.0.0.1 at a free port, or `nil` where the test may not listen.
    private static func listen() -> (descriptor: Int32, port: UInt16)? {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, length) == 0 && Darwin.listen(descriptor, 4) == 0 && getsockname(descriptor, address, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            return nil
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    @Test("The frida-server probe connects to 127.0.0.1 only, finds a listener, and runs off the main thread when called on it")
    func loopbackProbe() async throws {
        let probes = SystemDeviceProbes()
        let (descriptor, port) = try #require(Self.listen(), "a loopback listener")
        #expect(try probes.acceptsLoopbackConnection(port: port, timeout: 0.1))
        let onMain = try await MainActor.run { try probes.acceptsLoopbackConnection(port: port, timeout: 0.1) }
        #expect(onMain, "called on the main thread")
        close(descriptor)
        let start = Date()
        #expect(try !probes.acceptsLoopbackConnection(port: port, timeout: 0.1), "nothing listens any more")
        #expect(try await MainActor.run { try probes.acceptsLoopbackConnection(port: port, timeout: 0.1) } == false)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
