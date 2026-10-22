import Foundation
import os
@testable import Payriff

/// An HTTP transport answering from a closure, recording every request.
final class FakeTransport: PayriffHTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)

    private let recorded = OSAllocatedUnfairLock(initialState: [URLRequest]())
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Always answers `status` with `body`.
    convenience init(status: Int, body: String) {
        self.init { _ in (status, Data(body.utf8)) }
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        recorded.withLock { $0.append(request) }
        let (status, data) = try await handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

/// A controllable clock. In auto-advance mode every sleep moves time forward immediately;
/// in manual mode sleeps wait until ``advance(by:)`` passes their deadline.
final class FakeClock: PaymentClock {
    private struct Sleeper: Sendable {
        let id: UUID
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var now: TimeInterval = 0
        var sleeps: [TimeInterval] = []
        var sleepers: [Sleeper] = []
        var cancelled: Set<UUID> = []
    }

    let autoAdvance: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(autoAdvance: Bool = true) {
        self.autoAdvance = autoAdvance
    }

    var now: TimeInterval { state.withLock { $0.now } }
    var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }
    var pendingSleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        if autoAdvance {
            state.withLock {
                $0.sleeps.append(seconds)
                $0.now += max(0, seconds)
            }
            await Task.yield()
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool? = state.withLock { state in
                    state.sleeps.append(seconds)
                    if state.cancelled.remove(id) != nil { return false }
                    if seconds <= 0 { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: state.now + seconds, continuation: continuation))
                    return nil
                }
                switch resumeNow {
                case true?: continuation.resume()
                case false?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = state.withLock { state in
            state.now += seconds
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// Records log entries emitted while it is installed.
final class LogRecorder: Sendable {
    private let entries = OSAllocatedUnfairLock(initialState: [PayriffLogEntry]())

    var all: [PayriffLogEntry] { entries.withLock { $0 } }

    func install() {
        PayriffLogger.onLog = { [self] entry in
            entries.withLock { $0.append(entry) }
        }
    }

    func contains(_ text: String) -> Bool {
        all.contains { $0.message.contains(text) }
    }

    func clear() {
        entries.withLock { $0.removeAll() }
    }
}

/// Waits (in real time) until `condition` holds.
///
/// Only time during which this loop could run counts toward `timeout`: when the main actor is
/// blocked for a while (for example while WebKit launches its processes on a loaded machine),
/// the gap counts as at most 0.1 s, so a stall elsewhere cannot fail an unrelated test. A real
/// hang still times out after `timeout` seconds of polling.
@MainActor
func waitUntil(
    timeout: TimeInterval = 30,
    _ description: String = "condition",
    _ condition: @MainActor () -> Bool
) async throws {
    var waited: TimeInterval = 0
    var last = Date()
    while !condition() {
        let now = Date()
        waited += min(now.timeIntervalSince(last), 0.1)
        last = now
        if waited > timeout {
            throw WaitTimeout(description: description)
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}
