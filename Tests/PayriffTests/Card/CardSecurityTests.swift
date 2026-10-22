import Foundation
import os
import Testing
@testable import Payriff

/// Regression tests from the security review of the native card flow (CONTRACT §16.2, §16.5,
/// §16.6, §16.8). Everything runs against fakes; nothing reaches the network.
@Suite("Card security")
struct CardSecurityTests {
    // MARK: Transport (CONTRACT §16.2: the Client API host comes only from the host table)

    @Test("The Client API never follows a redirect: the keys, x-secret-key and the card never leave the API host")
    func clientAPIRefusesRedirects() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))
        let client = ClientAPIClient(
            baseURL: "https://\(RedirectingURLProtocol.apiHost)",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_REDIRECTTEST", clientSecret: "pr_cs_REDIRECTTEST"),
            appId: "com.payriff.example.ios",
            transport: transport,
            clock: FakeClock()
        )
        let card = EncryptedCard(encryptedMessage: "Q0lQSEVSVEVYVA==", wrappedKey: "V1JBUFBFRC1LRVk=")

        // A 307 on /pay (URLSession would resend the body) and a 302 on every GET.
        let pay = try #require(await client.pay("o1", card: card, idempotencyKey: "k-1").failureValue)
        #expect(pay.code == .paymentFailed)
        #expect(pay.httpStatus == 307)
        let order = try #require(await client.order("o1").failureValue)
        #expect(order.httpStatus == 302)
        #expect(await client.threeDS("o1").failureValue?.httpStatus == 302)
        #expect(await client.status("o1").failureValue?.httpStatus == 302)
        #expect(RedirectingURLProtocol.requests(to: RedirectingURLProtocol.apiHost).count == 4)
        #expect(RedirectingURLProtocol.requests(to: RedirectingURLProtocol.targetHost).isEmpty, "nothing reached the redirect target")

        // Why: URLSession forwards custom headers (and a 307 body) to another host on its own.
        var probe = URLRequest(url: URL(string: "https://\(RedirectingURLProtocol.apiHost)/probe")!)
        probe.httpMethod = "POST"
        probe.setValue("pr_cs_REDIRECTTEST", forHTTPHeaderField: "X-Client-Secret")
        probe.httpBody = Data("{}".utf8)
        _ = try await transport.send(probe)
        let forwarded = try #require(RedirectingURLProtocol.requests(to: RedirectingURLProtocol.targetHost).first)
        #expect(forwarded.value(forHTTPHeaderField: "X-Client-Secret") == "pr_cs_REDIRECTTEST")
    }

    // MARK: Plaintext lifetime (CONTRACT §16.5, §16.6)

    @Test("The flow keeps the plaintext card only until it is encrypted, not through 3-D Secure")
    @MainActor
    func flowDropsPlaintextCard() async throws {
        let harness = CardFlowHarness([
            .order: [CardBodies.order()],
            .pay: [CardBodies.challenge],
            .status: [CardBodies.status("APPROVED")],
        ])
        #expect(harness.flow.holdsCardDetails)
        harness.start()
        try await harness.waitForSheet()
        #expect(!harness.flow.holdsCardDetails, "dropped once encrypted, before the 3DS sheet")
        _ = harness.flow.decideNavigation(to: CardBodies.callback, isMainFrame: true, inPopup: false)
        _ = harness.flow.decideNavigation(to: CardBodies.merchantReturn, isMainFrame: true, inPopup: false)
        #expect(try await harness.finish().isSuccess)

        // Also when the flow ends before encrypting.
        let notPayable = CardFlowHarness([.order: [CardBodies.order(status: "APPROVED")]])
        #expect(try await notPayable.run().error?.code == .orderNotPayable)
        #expect(!notPayable.flow.holdsCardDetails)
    }

    @Test("The card JSON is built in one allocation, also for the longest non-ASCII holder name")
    func cardJSONSingleAllocation() {
        let holders = [
            String(repeating: "Ə", count: 50),
            String(repeating: "Щ", count: 50),
            String(repeating: "€", count: 50),
            String(repeating: "😀", count: 25),
            String(repeating: "\"", count: 50),
            String(repeating: "\u{01}", count: 50),
            "TEST CARD",
            CardDetails.unknownHolder,
        ]
        for holder in holders {
            let card = CardDetails(pan: "4111111111111111111", cardHolder: holder, expiryYear: "2030", expiryMonth: "12", cvv: "123")
            let json = CardCrypto.cardJSON(card)
            #expect(json.count <= CardCrypto.cardJSONCapacity(card), "the buffer would grow and free an unzeroed copy")
            #expect(json.first == UInt8(ascii: "{") && json.last == UInt8(ascii: "}"))
        }
        // A fixed 160-byte buffer was too small for a Cyrillic holder name.
        let cyrillic = CardDetails(pan: "4111111111111111", cardHolder: String(repeating: "Щ", count: 50), expiryYear: "2030", expiryMonth: "12", cvv: "123")
        #expect(CardCrypto.cardJSON(cyrillic).count > 160)
    }

    // MARK: Redaction (CONTRACT §16.5)

    @Test("The form model never shows what was typed: print, debugDescription and dump")
    func formModelRedaction() {
        var model = CardFormModel(showsHolder: true, language: .en)
        _ = model.setText(.number, "5555555555554444")
        _ = model.setText(.expiry, "1230")
        _ = model.setText(.cvv, "987")
        _ = model.setText(.holder, "JANE SECRET")
        #expect(model.text(.number) == "5555 5555 5555 4444", "the values themselves are kept")
        var dumped = ""
        dump(model, to: &dumped)
        var dumpedState = ""
        dump(model.state(.cvv), to: &dumpedState)
        let texts = ["\(model)", String(reflecting: model), dumped, "\(model.state(.number))", String(reflecting: model.state(.cvv)), dumpedState]
        for text in texts {
            for secret in ["5555 5555", "5555555555554444", "4444", "987", "12 / 30", "JANE SECRET"] {
                #expect(!text.contains(secret), "\(text)")
            }
        }
    }

    // MARK: 3-D Secure navigation (CONTRACT §16.8, §16.0 item 5)

    @Test("3DS subframes load only https, about, data, blob and javascript; file: and content: never reach iOS")
    func threeDSSchemes() {
        var navigator = ThreeDSNavigator(apiHost: "api.payriff.com")
        for url in ["file:///private/var/mobile/Library/x", "http://acs.bank.example/frame", "ftp://acs.bank.example/x", "content://com.example.files/x", "filesystem:https://acs.bank.example/x", "bankapp://open"] {
            #expect(navigator.decide(URL(string: url), isMainFrame: false) == .block, "subframe \(url)")
        }
        for url in ["https://acs.bank.example/frame", "about:blank", "about:srcdoc", "data:text/html,x", "blob:https://acs.bank.example/1"] {
            #expect(navigator.decide(URL(string: url), isMainFrame: false) == .allow, "subframe \(url)")
        }
        for url in ["file:///private/var/mobile/Library/x", "content://com.example.files/x", "data:text/html,x", "javascript:alert(1)", "http://acs.bank.example/"] {
            #expect(navigator.decide(URL(string: url), isMainFrame: true) == .block, "main frame \(url)")
        }
        #expect(navigator.decide(URL(string: "birbank://confirm?id=1"), isMainFrame: true) == .external, "bank apps still open")
        #expect(!navigator.isArmed)
    }
}

/// Answers `api.redirect.payriff.test` with a redirect to `elsewhere.redirect.payriff.test`
/// (307 for POST, 302 otherwise) and records every request it sees.
final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    static let apiHost = "api.redirect.payriff.test"
    static let targetHost = "elsewhere.redirect.payriff.test"

    private static let log = OSAllocatedUnfairLock(initialState: [URLRequest]())

    static func requests(to host: String) -> [URLRequest] {
        log.withLock { $0.filter { $0.url?.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".redirect.payriff.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.log.withLock { $0.append(request) }
        if url.host == Self.apiHost {
            let target = URL(string: "https://\(Self.targetHost)/collect")!
            let status = request.httpMethod == "POST" ? 307 : 302
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // Reached only when the redirect is refused: the 3xx response is the final one.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":"00000","payload":{"nextAction":"CHECK_STATUS"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
