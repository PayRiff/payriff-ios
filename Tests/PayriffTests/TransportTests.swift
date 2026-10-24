import Foundation
import os
import Testing
@testable import Payriff

/// A `URLProtocol` that answers from a handler, so the real `URLSession` path can be tested
/// without the network.
final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let handlers = OSAllocatedUnfairLock(initialState: [String: Handler]())

    /// Registers a handler for requests whose URL host is `host`.
    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// The body of a request created by URLSession, which moves `httpBody` into a stream.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A `URLProtocol` that raises a server-trust challenge before it answers, like the TLS handshake
/// of a real connection: the request reaches the "server" only when the challenge is accepted.
/// The challenge has no certificate, so a pinned host's challenge must be refused. Requests go to
/// `*.payriff.test` hosts, which do not exist; the challenge names the host they stand for.
final class ChallengingURLProtocol: URLProtocol {
    /// Passes URLSession's answer to the challenge back to the protocol.
    private final class Sender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
        let owner: ChallengingURLProtocol

        init(_ owner: ChallengingURLProtocol) {
            self.owner = owner
        }

        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { owner.serve() }
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { owner.serve() }
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) { owner.serve() }
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { owner.serve() }
        func cancel(_ challenge: URLAuthenticationChallenge) { owner.refuse() }
    }

    /// The host each test host stands for in the challenge.
    static let challengeHosts = ["pinned.payriff.test": "api.payriff.com", "sandbox.payriff.test": "sb-api.payriff.com", "bank.payriff.test": "acs.bank.example"]

    private static let log = OSAllocatedUnfairLock(initialState: (started: [String](), served: [String]()))

    /// The hosts whose requests started (a TLS handshake each).
    static func started(_ host: String) -> Int { log.withLock { $0.started.filter { $0 == host }.count } }
    /// The hosts whose requests reached the server.
    static func served(_ host: String) -> Int { log.withLock { $0.served.filter { $0 == host }.count } }

    override class func canInit(with request: URLRequest) -> Bool {
        challengeHosts[request.url?.host ?? ""] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.log.withLock { $0.started.append(host) }
        let space = URLProtectionSpace(
            host: Self.challengeHosts[host] ?? host,
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: Sender(self))
        client?.urlProtocol(self, didReceive: challenge)
    }

    override func stopLoading() {}

    /// The handshake passed: the request reaches the server, which answers.
    fileprivate func serve() {
        let host = request.url?.host ?? ""
        Self.log.withLock { $0.served.append(host) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":"00000","payload":{"orderId":"o1","status":"PENDING"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The handshake was cancelled: the connection ends before the request is sent.
    fileprivate func refuse() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
}

@Suite("URLSession transport")
struct TransportTests {
    private func transport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    private func client(_ host: String, transport: URLSessionTransport) -> ClientAPIClient {
        ClientAPIClient(
            baseURL: "https://\(host)",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_WIRE", clientSecret: "pr_cs_WIRE"),
            appId: "com.payriff.example.ios",
            transport: transport,
            clock: FakeClock()
        )
    }

    @Test("Requests go out with the Client API headers and the exact body")
    func wireFormat() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [URLRequest]())
        let bodies = OSAllocatedUnfairLock(initialState: [Data]())
        MockURLProtocol.register(host: "wire.payriff.test") { request in
            seen.withLock { $0.append(request) }
            bodies.withLock { $0.append(MockURLProtocol.body(of: request)) }
            return (200, Data(#"{"code":"00000","payload":{"orderId":"o1","nextAction":"CHECK_STATUS"}}"#.utf8))
        }
        let card = EncryptedCard(encryptedMessage: "RU5D+/w=", wrappedKey: "S0VZ")
        let next = try await client("wire.payriff.test", transport: transport()).pay("o1", card: card, idempotencyKey: "k-1").get()
        #expect(next == .checkStatus)
        let request = try #require(seen.withLock { $0.first })
        #expect(request.url?.absoluteString == "https://wire.payriff.test/api/v3/client/orders/o1/pay")
        #expect(request.value(forHTTPHeaderField: "X-Public-Key") == "pr_pk_live_WIRE")
        #expect(request.value(forHTTPHeaderField: "X-Client-Secret") == "pr_cs_WIRE")
        #expect(request.value(forHTTPHeaderField: "x-secret-key") == "S0VZ")
        #expect(request.value(forHTTPHeaderField: "X-Idempotency-Key") == "k-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(decoding: try #require(bodies.withLock { $0.first }), as: UTF8.self)
        #expect(body == #"{"method":"CARD","encryptedMessage":"RU5D+/w="}"#)
    }

    @Test("Transport failures become NETWORK_ERROR")
    func networkFailure() async throws {
        MockURLProtocol.register(host: "offline.payriff.test") { _ in throw URLError(.notConnectedToInternet) }
        let error = try #require(await client("offline.payriff.test", transport: transport()).status("o1").failureValue)
        #expect(error.code == .networkError)
        #expect(error.isRetryable)
        #expect(error.httpStatus == nil)
        #expect((error.cause as? URLError)?.code == .notConnectedToInternet)
    }

    @Test("A body larger than 1 MB is never buffered whole: a failed response (audit IOS-10)")
    func oversizedBody() async throws {
        let limit = URLSessionTransport.maximumBodySize
        let envelope = #"{"code":"00000","payload":{"orderId":"fits","status":"PENDING"}}"#
        MockURLProtocol.register(host: "huge.payriff.test") { request in
            guard request.url?.path.contains("/fits/") == true else {
                return (200, Data(repeating: UInt8(ascii: " "), count: limit + 1))
            }
            // Exactly the limit: a real envelope padded with white space.
            return (200, Data((envelope + String(repeating: " ", count: limit - envelope.utf8.count)).utf8))
        }
        let api = client("huge.payriff.test", transport: transport())
        let error = try #require(await api.status("big").failureValue)
        #expect(error.code == .paymentFailed)
        #expect(error.httpStatus == 200)
        // A body of exactly the limit is read and parsed.
        let fits = try await api.status("fits").get()
        #expect(fits.status == .pending)
    }

    @Test("The shared session is ephemeral and caches nothing")
    func sharedSession() {
        let configuration = URLSessionTransport.shared.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.timeoutIntervalForRequest == 30)
        // A task without a delegate of its own is pinned too, and never follows a redirect.
        let delegate = URLSessionTransport.shared.session.delegate as? TransportTaskDelegate
        #expect(delegate != nil && delegate?.followsRedirects == false)
    }

    // MARK: Certificate pinning (CONTRACT §16.15)

    private func challengingClient(_ host: String) -> ClientAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChallengingURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))
        return client(host, transport: transport)
    }

    @Test("A pinned host whose certificate fails: NETWORK_ERROR, not retryable, the contract's message, nothing sent, /pay not retried")
    func pinningRefusal() async throws {
        let card = EncryptedCard(encryptedMessage: "Q0lQSEVSVEVYVA==", wrappedKey: "V1JBUFBFRC1LRVk=")
        for host in ["pinned.payriff.test", "sandbox.payriff.test"] {
            let api = challengingClient(host)
            let pay = try #require(await api.pay("o1", card: card, idempotencyKey: "k-1").failureValue)
            #expect(pay.code == .networkError, "\(host)")
            #expect(!pay.isRetryable)
            #expect(!pay.isFatal)
            #expect(pay.message == "Payriff's server certificate could not be verified.")
            #expect(pay.cause is CertificatePinningError)
            #expect(ChallengingURLProtocol.started(host) == 1, "\(host): one handshake, no retry")
            let status = try #require(await api.status("o1").failureValue)
            #expect(status.message == CertificatePinning.failureMessage)
            #expect(ChallengingURLProtocol.served(host) == 0, "\(host): nothing reached the server")
        }
    }

    @Test("Other hosts are not pinned: their challenges are left to URLSession and the request is sent")
    func otherHostsNotPinned() async throws {
        let status = try await challengingClient("bank.payriff.test").status("o1").get()
        #expect(status.status == .pending)
        #expect(ChallengingURLProtocol.served("bank.payriff.test") >= 1)
    }

    @Test("A test transport replaces the pinned one whole")
    func testTransportUnaffected() async throws {
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"o1","status":"PENDING"}}"#)
        let api = ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_WIRE", clientSecret: "pr_cs_WIRE"),
            appId: nil,
            transport: transport,
            clock: FakeClock()
        )
        #expect(try await api.status("o1").get().status == .pending)
        #expect(transport.requests.count == 1)
    }

    @Test("A refused certificate on /pay from any transport is not retried")
    func pinningRefusalNotRetried() async throws {
        let transport = FakeTransport { _ in throw CertificatePinningError() }
        let api = ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_WIRE", clientSecret: "pr_cs_WIRE"),
            appId: nil,
            transport: transport,
            clock: FakeClock()
        )
        let card = EncryptedCard(encryptedMessage: "Q0lQSEVSVEVYVA==", wrappedKey: "V1JBUFBFRC1LRVk=")
        let error = try #require(await api.pay("o1", card: card, idempotencyKey: "k-1").failureValue)
        #expect(error.code == .networkError && !error.isRetryable)
        #expect(transport.requests.count == 1)
    }
}

/// Guards from CONTRACT §7.7, §9.1a, §16.3 and revision 5: no script injection, no user-agent
/// change, no default website data store, no `Bearer`, no order creation and no secret key.
@Suite("Source guards")
struct SourceGuardTests {
    static let sourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Payriff")

    @Test("Shipped sources never inject JavaScript or change the user agent")
    func noInjection() throws {
        let forbidden = [
            "WKUserScript", "evaluateJavaScript", "callAsyncJavaScript", "addScriptMessageHandler",
            "WKScriptMessageHandler", "customUserAgent", "applicationNameForUserAgent",
            "limitsNavigationsToAppBoundDomains", "Bearer ", "UIApplication.shared.windows", "UIApplication.shared.keyWindow",
        ]
        let files = try FileManager.default.subpathsOfDirectory(atPath: Self.sourcesDirectory.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 10)
        for file in files {
            let text = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent(file), encoding: .utf8)
            for symbol in forbidden {
                #expect(!text.contains(symbol), "\(file) contains \(symbol)")
            }
        }
    }

    @Test("Shipped sources never use the app's default website data store (CONTRACT §9.1a)")
    func noDefaultWebsiteDataStore() throws {
        // Split so that this list does not match itself in a search of the repository.
        let forbidden = ["WKWebsiteDataStore" + ".default", "websiteDataStore = " + ".default", "WKWebsiteDataStore(" + "forIdentifier"]
        let files = try FileManager.default.subpathsOfDirectory(atPath: Self.sourcesDirectory.path)
            .filter { $0.hasSuffix(".swift") }
        var configurationFiles: [String] = []
        for file in files {
            let text = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent(file), encoding: .utf8)
            for symbol in forbidden {
                #expect(!text.contains(symbol), "\(file) contains \(symbol)")
            }
            if text.contains("WKWebViewConfiguration()") { configurationFiles.append(file) }
        }
        // Every web view configuration comes from PaymentSheet.makeConfiguration(websiteDataStore:),
        // which sets the payment's store.
        #expect(configurationFiles == ["UI/PaymentSheet.swift"])
    }

    @Test("The SDK and the example app never create orders or hold a secret key (CONTRACT revision 5)")
    func cardOnly() throws {
        // Split so that this list does not match itself in a search of the repository.
        let forbidden = [
            "create" + "Order", "get" + "Order(", "pay" + "Session", "secret" + "Key", "SECRET" + "_KEY",
            "/api/v3/" + "orders", "callback" + "URL", "callback" + "Url", "status" + "Resolver",
        ]
        let root = Self.sourcesDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let example = root.appendingPathComponent("Example")
        var files = try FileManager.default.subpathsOfDirectory(atPath: Self.sourcesDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { Self.sourcesDirectory.appendingPathComponent($0) }
        let exampleSources = example.appendingPathComponent("PayriffExample/Sources")
        files += try FileManager.default.contentsOfDirectory(atPath: exampleSources.path)
            .filter { $0.hasSuffix(".swift") || $0.hasSuffix(".plist") }
            .map { exampleSources.appendingPathComponent($0) }
        // Only the committed configuration files; the git-ignored Secrets.xcconfig is never read.
        files += ["Example.xcconfig", "Example.Debug.xcconfig", "Secrets.example.xcconfig"]
            .map { example.appendingPathComponent("Config/\($0)") }
        #expect(files.count > 30)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for symbol in forbidden {
                #expect(!text.contains(symbol), "\(file.lastPathComponent) contains \(symbol)")
            }
        }
    }

    @Test("Payriff.version, the podspec and the CHANGELOG agree (CONTRACT §14)")
    @MainActor
    func versionsAgree() throws {
        let root = Self.sourcesDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let podspec = try String(contentsOf: root.appendingPathComponent("Payriff.podspec"), encoding: .utf8)
        #expect(podspec.contains("s.version           = '\(Payriff.version)'"))
        #expect(podspec.contains("s.ios.deployment_target = '16.0'"))
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let lines = changelog.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.first?.hasPrefix("## [\(Payriff.version)] - ") == true, "the newest CHANGELOG entry is this version")
    }

    @Test("The privacy manifest ships with the package")
    func privacyManifest() throws {
        let url = Self.sourcesDirectory.appendingPathComponent("Resources/PrivacyInfo.xcprivacy")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        #expect(plist?["NSPrivacyTracking"] as? Bool == false)
        #expect((plist?["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        let types = (plist?["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
        #expect(Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == [
            "NSPrivacyCollectedDataTypePaymentInfo", "NSPrivacyCollectedDataTypePurchaseHistory",
        ])
        for type in types {
            #expect(type["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(type["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }
}
