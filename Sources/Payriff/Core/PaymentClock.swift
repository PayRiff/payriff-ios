import Foundation

/// A monotonic clock that can sleep. Injected so tests can control time.
protocol PaymentClock: Sendable {
    /// Seconds since an arbitrary fixed origin. Never goes backwards.
    var now: TimeInterval { get }
    /// Suspends for `seconds`. Throws `CancellationError` when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

/// The production clock, based on `ContinuousClock`.
struct SystemPaymentClock: PaymentClock {
    private let origin = ContinuousClock.now

    var now: TimeInterval {
        let components = origin.duration(to: ContinuousClock.now).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
    }
}
