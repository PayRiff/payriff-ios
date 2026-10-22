import Foundation

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

/// Refuses every HTTP redirect of the task it is attached to; the task then finishes with the
/// 3xx response itself.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusal()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Thrown by ``URLSessionTransport`` when a response body exceeds
/// ``URLSessionTransport/maximumBodySize``. The Client API maps it like any other failed
/// response (CONTRACT §16.3).
struct ResponseTooLargeError: Error, Sendable, Equatable {
    /// The HTTP status of the oversized response.
    let httpStatus: Int?
}

/// The production transport: an ephemeral `URLSession` (no cache, no cookies on disk).
struct URLSessionTransport: PayriffHTTPTransport {
    static let shared = URLSessionTransport(session: makeSession())

    /// The largest response body read into memory. Payriff's responses are a few kilobytes;
    /// anything larger is not a Payriff response and is never buffered whole.
    static let maximumBodySize = 1_048_576

    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await send(request, delegate: nil)
    }

    func sendWithoutRedirects(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await send(request, delegate: RedirectRefusal.shared)
    }

    private func send(_ request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
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
        return URLSession(configuration: configuration)
    }
}
