import Darwin
import Foundation
import MachO
import os

/// A sign that the device is jailbroken, or that a hooking tool or a debugger is attached
/// (CONTRACT §16.16). The raw value names it in the warning log; it never carries file contents.
enum DeviceIntegritySignal: String, Sendable, CaseIterable {
    /// A jailbreak app, tool or file exists, such as `/Applications/Cydia.app` or `/var/jb`.
    case jailbreakFiles = "jailbreak files"
    /// The app could write outside its sandbox.
    case sandboxWrite = "sandbox write"
    /// A hooking library is loaded into the app, such as MobileSubstrate, libhooker or ElleKit.
    case hookingLibrary = "hooking library"
    /// Frida is loaded into the app (`FridaGadget`, `frida-agent`).
    case frida = "Frida"
    /// `DYLD_INSERT_LIBRARIES` is set in an App Store or TestFlight build.
    case insertedLibraries = "DYLD_INSERT_LIBRARIES"
    /// A frida-server accepts connections on 127.0.0.1:27042.
    case fridaServer = "frida-server"
    /// A debugger traces the app in an App Store or TestFlight build.
    case debugger = "debugger"
    /// A check could not complete, so the device counts as compromised.
    case checkFailed = "check failed"
}

/// What the device integrity checks read (CONTRACT §16.16). Injected into ``DeviceIntegrity`` so
/// that its decisions are unit-tested; ``SystemDeviceProbes`` reads the device.
protocol DeviceIntegrityProbes: Sendable {
    /// Whether the app runs on the simulator or on a Mac (Mac Catalyst, an iPhone or iPad app on a
    /// Mac), whose file system is the Mac's. Nothing is checked there.
    var isSimulatorOrMac: Bool { get }
    /// Whether the app bundle has an `embedded.mobileprovision`: development, ad hoc and
    /// enterprise builds do; App Store and TestFlight builds do not.
    var hasEmbeddedProvisioningProfile: Bool { get }
    /// Whether a file or directory exists at `path`.
    func fileExists(atPath path: String) -> Bool
    /// Creates a file at `path` and removes it again at once; whether that worked.
    func canCreateFile(atPath path: String) -> Bool
    /// The paths of the images loaded into the app: its executable and its libraries.
    func loadedImagePaths() -> [String]
    /// The value of an environment variable.
    func environmentValue(_ name: String) -> String?
    /// Whether something accepts a TCP connection on 127.0.0.1:`port` within `timeout`. Throws
    /// when the probe cannot run.
    func acceptsLoopbackConnection(port: UInt16, timeout: TimeInterval) throws -> Bool
    /// Whether a debugger traces the app (`P_TRACED`). Throws when the process information
    /// cannot be read.
    func isTraced() throws -> Bool
}

/// The device integrity checks (CONTRACT §16.16): jailbreak files, a write outside the sandbox,
/// hooking libraries, Frida, `DYLD_INSERT_LIBRARIES` and a debugger. Any signal is enough.
///
/// - The jailbreak file and sandbox checks run once and are cached for the process: a device does
///   not become jailbroken while the app runs. The hooking, Frida and debugger checks run at every
///   call, because such a tool can attach at any time.
/// - `DYLD_INSERT_LIBRARIES` and a debugger count only in App Store and TestFlight builds (no
///   `embedded.mobileprovision`): Xcode sets the variable and attaches its debugger when it runs a
///   development build.
/// - Nothing is checked on the simulator or on a Mac, whose file system is the Mac's.
/// - A check that cannot complete counts as the signal ``DeviceIntegritySignal/checkFailed``, so
///   breaking the check does not skip it.
///
/// The checks are local and can be bypassed by a determined attacker; they stop the common tools.
final class DeviceIntegrity: Sendable {
    /// The checks of this process, on the device.
    static let shared = DeviceIntegrity(probes: SystemDeviceProbes())

    /// Files of jailbreaks, their package managers and tools (CONTRACT §16.16).
    static let jailbreakPaths = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Applications/Filza.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/usr/sbin/sshd",
        "/usr/bin/sshd",
        "/usr/libexec/sftp-server",
        "/etc/apt",
        "/private/var/lib/apt/",
        "/private/var/lib/cydia",
        "/private/var/stash",
        "/var/jb",
        "/private/preboot/jb",
        "/usr/lib/TweakInject",
        "/usr/lib/libhooker.dylib",
        "/usr/lib/libsubstitute.dylib",
        "/.bootstrapped",
        "/.installed_unc0ver",
        "/bin/bash",
    ]

    /// Written and removed at once: only a jailbreak lets an app write there.
    static let sandboxProbePath = "/private/payriff-jb-check"

    /// Parts of the path of a loaded image that mean a hooking library, matched as written
    /// (CONTRACT §16.16).
    static let hookingLibraryNames = [
        "MobileSubstrate", "SubstrateLoader", "TweakInject", "libhooker", "substitute", "ellekit",
        "systemhook", "SSLKillSwitch", "cynject", "libcycript",
    ]

    /// Parts of the path of a loaded image that mean Frida, matched as written.
    static let fridaLibraryNames = ["FridaGadget", "frida"]

    /// frida-server's default port, and how long the probe waits for it.
    static let fridaServerPort: UInt16 = 27042
    static let fridaServerTimeout: TimeInterval = 0.1

    private let probes: any DeviceIntegrityProbes
    /// The signals of the jailbreak file and sandbox checks, once they ran.
    private let fileSignals = OSAllocatedUnfairLock<[DeviceIntegritySignal]?>(initialState: nil)

    init(probes: any DeviceIntegrityProbes) {
        self.probes = probes
    }

    /// The signals that match now, in a fixed order without repeats; empty when none does. May
    /// take up to about 0.1 s while it waits for the frida-server probe.
    func signals() -> [DeviceIntegritySignal] {
        guard !probes.isSimulatorOrMac else { return [] }
        var found = fileSignals.withLock { $0 } ?? scanFiles()
        for signal in scanRuntime() where !found.contains(signal) {
            found.append(signal)
        }
        return found
    }

    /// The jailbreak file and sandbox checks; their result is kept for the process.
    private func scanFiles() -> [DeviceIntegritySignal] {
        var found: [DeviceIntegritySignal] = []
        if Self.jailbreakPaths.contains(where: { probes.fileExists(atPath: $0) }) {
            found.append(.jailbreakFiles)
        }
        if probes.canCreateFile(atPath: Self.sandboxProbePath) {
            found.append(.sandboxWrite)
        }
        let result = found
        fileSignals.withLock { $0 = result }
        return result
    }

    /// The hooking, Frida and debugger checks, fresh at every call.
    private func scanRuntime() -> [DeviceIntegritySignal] {
        var found: [DeviceIntegritySignal] = []
        func add(_ signal: DeviceIntegritySignal) {
            if !found.contains(signal) { found.append(signal) }
        }
        for path in probes.loadedImagePaths() {
            if Self.fridaLibraryNames.contains(where: { path.contains($0) }) {
                add(.frida)
            } else if Self.hookingLibraryNames.contains(where: { path.contains($0) }) {
                add(.hookingLibrary)
            }
        }
        let isStoreBuild = !probes.hasEmbeddedProvisioningProfile
        if isStoreBuild, let inserted = probes.environmentValue("DYLD_INSERT_LIBRARIES"), !inserted.isEmpty {
            add(.insertedLibraries)
        }
        do {
            if try probes.acceptsLoopbackConnection(port: Self.fridaServerPort, timeout: Self.fridaServerTimeout) {
                add(.fridaServer)
            }
        } catch {
            add(.checkFailed)
        }
        if isStoreBuild {
            do {
                if try probes.isTraced() { add(.debugger) }
            } catch {
                add(.checkFailed)
            }
        }
        return found
    }
}

/// Why a device probe could not complete.
enum DeviceProbeError: Error, Sendable {
    case unavailable
}

/// The device side of ``DeviceIntegrityProbes``. It reads names, flags and whether files exist;
/// file contents never leave it.
struct SystemDeviceProbes: DeviceIntegrityProbes {
    var isSimulatorOrMac: Bool {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst) || os(macOS)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    var hasEmbeddedProvisioningProfile: Bool {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func canCreateFile(atPath path: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        unlink(path)
        return true
    }

    func loadedImagePaths() -> [String] {
        (0..<_dyld_image_count()).compactMap { index in
            _dyld_get_image_name(index).map { String(cString: $0) }
        }
    }

    func environmentValue(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    /// The probe itself never runs on the main thread (CONTRACT §16.16): called there, it runs on
    /// a background queue and the caller waits for it, at most about `timeout`.
    func acceptsLoopbackConnection(port: UInt16, timeout: TimeInterval) throws -> Bool {
        guard Thread.isMainThread else { return try Self.probeLoopback(port: port, timeout: timeout) }
        let outcome = OSAllocatedUnfairLock<Result<Bool, DeviceProbeError>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        // The main thread waits for it, so it runs at the main thread's priority.
        DispatchQueue.global(qos: .userInteractive).async {
            let result = Result { () throws(DeviceProbeError) -> Bool in try Self.probeLoopback(port: port, timeout: timeout) }
            outcome.withLock { $0 = result }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout + 0.5) == .success, let result = outcome.withLock({ $0 }) else {
            throw DeviceProbeError.unavailable
        }
        return try result.get()
    }

    /// A non-blocking connect to 127.0.0.1:`port`, waiting at most `timeout` for the answer.
    private static func probeLoopback(port: UInt16, timeout: TimeInterval) throws(DeviceProbeError) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw .unavailable }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw .unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected == 0 { return true }
        // Usually ECONNREFUSED at once: nothing listens.
        guard errno == EINPROGRESS else { return false }
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)
        var ready: Int32
        repeat {
            ready = poll(&request, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000))
        } while ready < 0 && errno == EINTR && deadline.timeIntervalSinceNow > 0
        guard ready >= 0 else { throw .unavailable }
        // No answer in time: nothing that behaves like frida-server listens.
        guard ready > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { throw .unavailable }
        return socketError == 0
    }

    func isTraced() throws -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { throw DeviceProbeError.unavailable }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}

/// The device integrity policy at the three points of a card payment (CONTRACT §16.16).
enum DeviceIntegrityPolicy {
    /// `DEVICE_COMPROMISED` when a signal matched and `allowCompromisedDevices` is off; `nil` when
    /// none matched, or when the app opted in, which only logs a warning that names the signals.
    static func decide(_ signals: [DeviceIntegritySignal], allowCompromisedDevices: Bool) -> PayriffError? {
        guard !signals.isEmpty else { return nil }
        let names = signals.map(\.rawValue).joined(separator: ", ")
        if allowCompromisedDevices {
            Log.warning("Device integrity: allowCompromisedDevices is on, so the card payment continues on a compromised device. Signals: \(names).")
            return nil
        }
        Log.warning("Device integrity: card payments are refused on this device. Signals: \(names).")
        return .deviceCompromised
    }
}

extension Payriff {
    /// Whether this device looks compromised (CONTRACT §16.16): it is jailbroken, or a hooking
    /// tool such as Frida or, in an App Store or TestFlight build, a debugger is attached.
    ///
    /// Card payments fail with `DEVICE_COMPROMISED` on such a device unless
    /// ``PayriffConfig/allowCompromisedDevices`` is on; this property does not depend on that
    /// setting. Use it to decide early, for example to offer another payment method. It is always
    /// `false` on the simulator and on a Mac.
    ///
    /// The checks run on the device and stop the common tools; a determined attacker can get past
    /// them. Each read runs the hooking, Frida and debugger checks again; it takes up to about
    /// 0.1 s.
    public static var isDeviceCompromised: Bool {
        !services.deviceSignals().isEmpty
    }

    /// The policy of CONTRACT §16.16 at one of the three points of a payment: when the payment
    /// view appears, when `confirmCardPayment` starts and right before the card is encrypted.
    static func deviceIntegrityError(allowCompromisedDevices: Bool) -> PayriffError? {
        DeviceIntegrityPolicy.decide(services.deviceSignals(), allowCompromisedDevices: allowCompromisedDevices)
    }
}
