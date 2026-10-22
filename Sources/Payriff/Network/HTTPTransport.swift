import Foundation
import os

/// Sends HTTP requests. Abstracted so tests can use local fakes instead of the network.
protocol PayriffHTTPTransport: Sendable {
    /// Sends `request` and returns the body and the response, or throws a transport error.
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)

    /// Sends `request` without following HTTP redirects: a 3xx response is returned as is.
    ///
    /// The Client API uses only this (CONTRACT §16.2: the host comes only from the fixed host
    /// table). On a redirect `URLSession` forwards the custom headers (`X-Public-Key`,
    /// `X-Client-Secret`, `x-secret-key`) and, on 307/308, the encrypted card body to the new
    /// URL, whatever its host or scheme. A transport that can follow redirects must implement this.
    func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension PayriffHTTPTransport {
    /// For transports that never follow redirects (the test fakes): the same as ``send(_:)``.
    func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await send(request)
    }
}

/// The delegate of a task of ``URLSessionTransport``. Each request gets its own, so a refused
/// certificate is known for that request.
///
/// - It pins Payriff's certificates (CONTRACT §16.15, ``CertificatePinning``): a server-trust
///   challenge of a Client API host is accepted only when the platform trusts the chain for the
///   host and the chain has a pinned key. Otherwise the connection is cancelled during the TLS
///   handshake, before anything is sent.
/// - Without `followsRedirects` it refuses every HTTP redirect; the task then finishes with the
///   3xx response itself.
final class TransportTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let followsRedirects: Bool
    private let refused = OSAllocatedUnfairLock(initialState: false)

    init(followsRedirects: Bool) {
        self.followsRedirects = followsRedirects
    }

    /// Whether this delegate refused a server certificate.
    var refusedServerCertificate: Bool {
        refused.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch CertificatePinning.decide(challenge) {
        case .defaultHandling:
            completionHandler(.performDefaultHandling, nil)
        case .accept(let trust):
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .refuse(let verdict):
            refused.withLock { $0 = true }
            let host = challenge.protectionSpace.host
            Log.warning(verdict == .notPinned
                ? "The server certificate of \(host) has no pinned key (a proxy or another CA); the connection was refused before anything was sent."
                : "The server certificate of \(host) is not trusted for the host; the connection was refused before anything was sent.")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(followsRedirects ? request : nil)
    }
}

/// Thrown by ``URLSessionTransport`` when ``TransportTaskDelegate`` refused the server's
/// certificate (CONTRACT §16.15). Nothing was sent; the Client API maps it to a `NETWORK_ERROR`
/// that is not retryable.
struct CertificatePinningError: Error, Sendable, Equatable {}

/// Thrown by ``URLSessionTransport`` when a response body exceeds
/// ``URLSessionTransport/maximumBodySize``. The Client API maps it like any other failed
/// response (CONTRACT §16.3).
struct ResponseTooLargeError: Error, Sendable, Equatable {
    /// The HTTP status of the oversized response.
    let httpStatus: Int?
}

/// The production transport: an ephemeral `URLSession` (no cache, no cookies on disk) whose
/// connections to the Client API hosts are pinned (CONTRACT §16.15): every task gets a
/// ``TransportTaskDelegate``.
struct URLSessionTransport: PayriffHTTPTransport {
    static let shared = URLSessionTransport(session: makeSession())

    /// The largest response body read into memory. Payriff's responses are a few kilobytes;
    /// anything larger is not a Payriff response and is never buffered whole.
    static let maximumBodySize = 1_048_576

    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await send(request, delegate: TransportTaskDelegate(followsRedirects: true))
    }

    func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await send(request, delegate: TransportTaskDelegate(followsRedirects: false))
    }

    private func send(_ request: URLRequest, delegate: TransportTaskDelegate) async throws -> (Data, URLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            let status = (response as? HTTPURLResponse)?.statusCode
            if response.expectedContentLength > Self.maximumBodySize {
                bytes.task.cancel()
                throw ResponseTooLargeError(httpStatus: status)
            }
            var body = Data()
            for try await byte in bytes {
                guard body.count < Self.maximumBodySize else {
                    bytes.task.cancel()
                    throw ResponseTooLargeError(httpStatus: status)
                }
                body.append(byte)
            }
            return (body, response)
        } catch {
            // The refused certificate cancelled the task; URLSession reports that as `cancelled`.
            if delegate.refusedServerCertificate { throw CertificatePinningError() }
            throw error
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // The longest Client API timeout (POST /pay); each request sets its own.
        configuration.timeoutIntervalForRequest = ClientAPIClient.postTimeout
        configuration.timeoutIntervalForResource = ClientAPIClient.postTimeout
        configuration.waitsForConnectivity = false
        // Every task has a delegate of its own (send above). The session's delegate pins and
        // refuses redirects too, for a task that would have none.
        return URLSession(configuration: configuration, delegate: TransportTaskDelegate(followsRedirects: false), delegateQueue: nil)
    }
}
