import Foundation
import Testing
@testable import Payriff

/// Card-flow tests that touch process-wide state (`Payriff.configure`, `PayriffLogger`); they run
/// in the serialized "Global state" suite.
extension GlobalStateTests {
    static let publishableKey = "pr_pk_live_GLOBALTEST123"
    static let clientSecret = "pr_cs_GLOBALSECRET456"

    @Test("retrieveOrder: configure, a pr_pk_live_ key, a pr_cs_ secret and an order id, else no request")
    func retrieveOrderValidation() async throws {
        Payriff.reset()
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"o1","status":"CREATED","paymentMethods":["CARD"]}}"#)
        Payriff.services.transport = transport
        func code(orderId: String = "o1", clientSecret: String = GlobalStateTests.clientSecret) async -> PayriffError.Code? {
            do {
                _ = try await Payriff.retrieveOrder(orderId: orderId, clientSecret: clientSecret)
                return nil
            } catch {
                #expect(!error.message.contains(Self.publishableKey) && !error.message.contains(Self.clientSecret))
                return error.code
            }
        }
        #expect(await code() == .notConfigured)
        Payriff.configure(PayriffConfig(environment: .sandbox))
        #expect(await code() == .invalidConfig, "no publishable key")
        let secretShaped = "0123456789ABCDEF0123456789ABCDEF"
        Payriff.configure(PayriffConfig(publishableKey: secretShaped, environment: .sandbox))
        #expect(await code() == .invalidConfig, "a secret key is never a publishable key")
        Payriff.configure(PayriffConfig(publishableKey: "  \(Self.publishableKey)  ", environment: .sandbox))
        #expect(await code(clientSecret: "cs_abc") == .invalidOrder)
        #expect(await code(clientSecret: "pr_cs_a\nb") == .invalidOrder)
        #expect(await code(orderId: "   ") == .invalidOrder)
        #expect(transport.requests.isEmpty)
        #expect(await code(clientSecret: "  \(Self.clientSecret) ") == nil)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Public-Key") == Self.publishableKey)
        #expect(request.value(forHTTPHeaderField: "X-Client-Secret") == Self.clientSecret)
    }

    @Test("The card flow uses the environment's host, the app's bundle id and only the publishable key and client secret")
    func retrieveOrderHostsAndHeaders() async throws {
        Payriff.reset()
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"o1","amount":"10.50","currency":"AZN","merchantName":"Shop","status":"PENDING","language":"ru","paymentMethods":["CARD"]}}"#)
        Payriff.services.transport = transport
        Payriff.services.clientAppId = { "com.payriff.example.ios" }
        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox))
        let order = try await Payriff.retrieveOrder(orderId: "o 1", clientSecret: Self.clientSecret)
        #expect(order == PayriffClientOrder(
            orderId: "o1",
            amount: Decimal(string: "10.50", locale: Locale(identifier: "en_US_POSIX")),
            currency: "AZN",
            merchantName: "Shop",
            status: .pending,
            rawStatus: "PENDING",
            language: .ru,
            paymentMethods: ["CARD"]
        ))
        #expect(order.isPayableByCard)
        let sandbox = try #require(transport.requests.last)
        #expect(sandbox.url?.absoluteString == "https://sb-api.payriff.com/api/v3/client/orders/o%201")
        #expect(sandbox.value(forHTTPHeaderField: "X-Client-App-Id") == "com.payriff.example.ios")
        #expect(sandbox.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(Set((sandbox.allHTTPHeaderFields ?? [:]).keys) == ["Accept", "X-Client-App-Id", "X-Client-Secret", "X-Public-Key"])
        #expect(PayriffEnvironment.sandbox.apiBaseURL == URL(string: "https://sb-api.payriff.com"))
        #expect(PayriffEnvironment.production.apiBaseURL == URL(string: "https://api.payriff.com"))

        Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .production))
        Payriff.services.clientAppId = { nil }
        _ = try await Payriff.retrieveOrder(orderId: "o1", clientSecret: Self.clientSecret)
        let production = try #require(transport.requests.last)
        #expect(production.url?.absoluteString == "https://api.payriff.com/api/v3/client/orders/o1")
        #expect(production.value(forHTTPHeaderField: "X-Client-App-Id") == nil)

        // Client API errors surface with isFatal.
        Payriff.services.transport = FakeTransport(status: 404, body: #"{"code":"01000","message":"Order not found"}"#)
        do {
            _ = try await Payriff.retrieveOrder(orderId: "o1", clientSecret: Self.clientSecret)
            Issue.record("expected SESSION_EXPIRED")
        } catch {
            #expect(error.code == .sessionExpired)
            #expect(error.isFatal)
        }
    }

    @Test("PayriffConfig shows the publishable key only as its prefix and length")
    func publishableKeyDescription() {
        let config = PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox, language: .az)
        var dumped = ""
        dump(config, to: &dumped)
        for text in [config.description, config.debugDescription, String(reflecting: config), dumped] {
            #expect(!text.contains("GLOBALTEST123"))
        }
        #expect(config.description == "PayriffConfig(publishableKey: pr_pk_live_***(\(Self.publishableKey.count)), environment: sandbox, language: AZ, enableLogging: false, allowCompromisedDevices: false)")
        #expect(Mirror(reflecting: config).children.map(\.label) == ["publishableKey", "environment", "language", "enableLogging", "allowCompromisedDevices"])
        #expect(PayriffConfig(publishableKey: "abc").description.contains("publishableKey: ***(3)"))
        #expect(PayriffConfig().description == "PayriffConfig(publishableKey: nil, environment: production, language: nil, enableLogging: false, allowCompromisedDevices: false)")
        #expect(PayriffConfig(allowCompromisedDevices: true).description.hasSuffix("allowCompromisedDevices: true)"))
        #expect(!PayriffConfig().allowCompromisedDevices, "card payments are refused on a compromised device by default")
    }

    @Test(
        "Card-flow logs never contain card data, the client secret, the publishable key, ciphertext, x-secret-key, creq or threeDSMethodData",
        arguments: [false, true]
    )
    func cardLogsAreRedacted(httpDetails: Bool) async throws {
        Payriff.reset()
        let recorder = LogRecorder()
        recorder.install()
        PayriffLogger.isEnabled = true
        defer {
            PayriffLogger.isEnabled = false
            PayriffLogger.onLog = nil
        }
        // A real encryption with the pinned key, the 3DS method, a challenge, 429 and network retries.
        let api = RoutedClientAPI([
            .order: [CardBodies.order()],
            .pay: [CardBodies.error(429, code: "01000"), .network, CardBodies.method],
            .threeDS: [CardBodies.challenge],
            .status: [CardBodies.status("APPROVED")],
        ])
        let clock = FakeClock()
        let ui = FakeCardFlowUI()
        let encryptedBox = EncryptedBox()
        let flow = CardPaymentFlow(
            orderId: "o1",
            card: CardFlowHarness.card,
            apiHost: "api.payriff.com",
            dependencies: CardPaymentFlow.Dependencies(
                client: ClientAPIClient(
                    baseURL: "https://api.payriff.com",
                    credentials: ClientCredentials(publishableKey: Self.publishableKey, clientSecret: Self.clientSecret),
                    appId: "com.payriff.example.ios",
                    transport: api.transport,
                    clock: clock,
                    // The JSON request and response entries of debug builds (CONTRACT §11).
                    logsHTTPDetails: httpDetails
                ),
                clock: clock,
                encrypt: { card in
                    let encrypted = try CardCrypto.encrypt(card)
                    encryptedBox.set(encrypted)
                    return encrypted
                },
                // Logged in plain with the details; a fixed one cannot contain the CVV by chance.
                makeIdempotencyKey: { CardFlowHarness.idempotencyKey },
                checkDevice: { nil }
            ),
            ui: ui
        )
        let box = ResultHolder()
        Task { @MainActor in box.result = await flow.run() }
        try await waitUntil(timeout: 20, "3DS sheet") { ui.isSheetPresented }
        _ = flow.decideNavigation(to: CardBodies.callback, isMainFrame: true, inPopup: false)
        _ = flow.decideNavigation(to: CardBodies.merchantReturn, isMainFrame: true, inPopup: false)
        try await waitUntil(timeout: 20, "result") { box.result != nil }
        #expect(box.result?.isSuccess == true)

        let encrypted = try #require(encryptedBox.value)
        let pay = try #require(api.requests(.pay).first)
        let secrets = [
            CardFlowHarness.card.pan, "4111 1111", CardFlowHarness.card.cvv, CardFlowHarness.card.cardHolder,
            Self.clientSecret, Self.publishableKey, encrypted.encryptedMessage, encrypted.wrappedKey,
            CardBodies.creq, CardBodies.methodData,
        ]
        #expect(pay.value(forHTTPHeaderField: "x-secret-key") == encrypted.wrappedKey)
        let entries = recorder.all
        #expect(!entries.isEmpty)
        // With the details on, the bodies of /pay, the 3DS method and the challenge were logged too.
        let details = Self.httpDetails(entries)
        #expect(details.contains { $0.message.hasPrefix("HTTP request\n") && $0.message.contains("/o1/pay") } == httpDetails)
        #expect(details.contains { $0.message.contains("threeDSMethodData") } == httpDetails)
        #expect(details.contains { $0.message.contains(#""key": "creq""#) } == httpDetails)
        for entry in entries {
            for secret in secrets {
                #expect(!entry.message.contains(secret), "log line contains a secret: \(entry.level.label)")
            }
            #expect(!entry.message.contains("x=1"), "no URL queries")
        }
        // The pinned key encrypted it: 256-byte wrap, ciphertext ‖ tag.
        #expect(Data(base64Encoded: encrypted.wrappedKey)?.count == 256)
    }
}

/// Holds a value across tasks in tests.
final class EncryptedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EncryptedCard?

    func set(_ value: EncryptedCard) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: EncryptedCard? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@MainActor
final class ResultHolder {
    var result: PayriffResult?
}
