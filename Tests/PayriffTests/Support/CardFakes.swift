import Foundation
import os
import Testing
@testable import Payriff

/// A fake Client API: scripted answers per endpoint (the last one repeats), every request recorded.
final class RoutedClientAPI: Sendable {
    enum Reply: Sendable {
        case json(Int, String)
        /// No response: a transport error (`NETWORK_ERROR`).
        case network
    }

    enum Route: String, Sendable, CaseIterable {
        case order = "GET order"
        case pay = "POST pay"
        case threeDS = "GET three-ds"
        case status = "GET status"
    }

    private let scripts: OSAllocatedUnfairLock<[Route: [Reply]]>
    let transport: FakeTransport

    init(_ scripts: [Route: [Reply]]) {
        let state = OSAllocatedUnfairLock(initialState: scripts)
        self.scripts = state
        self.transport = FakeTransport { request in
            guard let route = Self.route(of: request) else { return (500, Data("{}".utf8)) }
            let reply: Reply = state.withLock { scripts in
                guard var queue = scripts[route], !queue.isEmpty else { return .json(500, "{}") }
                let next = queue.count > 1 ? queue.removeFirst() : queue[0]
                scripts[route] = queue
                return next
            }
            switch reply {
            case .json(let status, let body): return (status, Data(body.utf8))
            case .network: throw URLError(.notConnectedToInternet)
            }
        }
    }

    static func route(of request: URLRequest) -> Route? {
        guard let path = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }) else { return nil }
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", let path) where path.hasSuffix("/pay"): return .pay
        case ("GET", let path) where path.hasSuffix("/three-ds"): return .threeDS
        case ("GET", let path) where path.hasSuffix("/status"): return .status
        case ("GET", let path) where path.hasPrefix(ClientAPIClient.ordersPath + "/"): return .order
        default: return nil
        }
    }

    var requests: [URLRequest] { transport.requests }

    func requests(_ route: Route) -> [URLRequest] {
        transport.requests.filter { Self.route(of: $0) == route }
    }

    var routes: [Route] { transport.requests.compactMap(Self.route(of:)) }
}

/// Client API bodies.
enum CardBodies {
    static func envelope(_ payload: String) -> RoutedClientAPI.Reply {
        .json(200, #"{"code":"00000","message":"OK","route":"/api/v3/client/orders","responseId":"r-1","payload":\#(payload)}"#)
    }

    static func order(status: String = "CREATED", methods: [String] = ["CARD", "GOOGLE_PAY"]) -> RoutedClientAPI.Reply {
        let list = methods.map { "\"\($0)\"" }.joined(separator: ",")
        return envelope(#"{"orderId":"o1","amount":10.5,"currency":"AZN","description":"Order #42","merchantName":"Test Merchant","status":"\#(status)","language":"AZ","paymentMethods":[\#(list)]}"#)
    }

    static func status(_ status: String) -> RoutedClientAPI.Reply {
        envelope(#"{"orderId":"o1","status":"\#(status)","amount":10.5,"currency":"AZN"}"#)
    }

    static let checkStatus = envelope(#"{"orderId":"o1","nextAction":"CHECK_STATUS"}"#)
    static let wait = envelope(#"{"orderId":"o1","nextAction":"WAIT"}"#)
    static let emptyThreeDS = envelope(#"{"orderId":"o1","nextAction":"THREE_DS","clientRequest":[]}"#)
    static let invalid = envelope(#"{"orderId":"o1","nextAction":"FOO"}"#)

    static let acsURL = URL(string: "https://acs.bank.example/challenge")!
    static let creq = "Y3JlcS1zZWNyZXQtdmFsdWU"
    static let challenge = envelope(#"{"orderId":"o1","nextAction":"THREE_DS","channel":"KAPITAL","accessUrl":"https://acs.bank.example/challenge","clientRequest":[{"key":"creq","value":"\#(creq)"},{"key":"threeDSSessionData","value":null}]}"#)

    static let methodURL = URL(string: "https://acs.bank.example/method")!
    static let methodServerURL = URL(string: "https://api.payriff.com/api/v3/gateway/atb/method")!
    static let methodData = "eyJ0aHJlZURTU2VydmVyVHJhbnNJRCI6IjEifQ"
    static let method = envelope(#"{"orderId":"o1","nextAction":"THREE_DS","channel":"ATB","clientRequest":[{"key":"threeDSMethodUrl","value":"https://acs.bank.example/method"},{"key":"threeDSMethodData","value":"\#(methodData)"},{"key":"threeDSMethodUrlServer","value":"https://api.payriff.com/api/v3/gateway/atb/method"}]}"#)

    static let redirectURL = URL(string: "https://bank.example/frictionless?x=1")!
    static let redirect = envelope(#"{"orderId":"o1","nextAction":"REDIRECT","redirectUrl":"https://bank.example/frictionless?x=1"}"#)

    static let callback = URL(string: "https://api.payriff.com/api/v3/gateway/kapital/callback/ORD-1")!
    static let merchantReturn = URL(string: "https://merchant.example/return?status=success")!

    static func error(_ status: Int, code: String, message: String = "failure") -> RoutedClientAPI.Reply {
        .json(status, #"{"code":"\#(code)","message":"\#(message)","route":"/api/v3/client/orders","responseId":"r-1"}"#)
    }
}

/// A ``CardFlowUI`` that records what the card flow asks it to do.
@MainActor
final class FakeCardFlowUI: CardFlowUI {
    enum Event: Equatable, CustomStringConvertible {
        case present
        case load(URLRequest)
        case content
        case verifying
        case pageLoadError
        case stopLoading
        case confirmClose
        case dismiss
        case openExternally(URL)
        case startMethod([URLRequest])
        case stopMethod

        var description: String {
            switch self {
            case .present: return "present"
            case .load(let request): return "load(\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "nil"))"
            case .content: return "content"
            case .verifying: return "verifying"
            case .pageLoadError: return "pageLoadError"
            case .stopLoading: return "stopLoading"
            case .confirmClose: return "confirmClose"
            case .dismiss: return "dismiss"
            case .openExternally(let url): return "openExternally(\(url.absoluteString))"
            case .startMethod(let requests): return "startMethod(\(requests.count))"
            case .stopMethod: return "stopMethod"
            }
        }
    }

    private(set) var events: [Event] = []
    var presentSucceeds = true
    /// The answer to close confirmations; `nil` keeps the dialog pending.
    var confirmAnswer: Bool? = true
    private(set) weak var sheetFlow: (any SheetFlowHandling)?

    func presentThreeDSSheet(for flow: any SheetFlowHandling) -> Bool {
        guard presentSucceeds else { return false }
        sheetFlow = flow
        events.append(.present)
        return true
    }

    func loadThreeDS(_ request: URLRequest) { events.append(.load(request)) }
    func showThreeDSContent() { events.append(.content) }
    func showThreeDSVerifying() { events.append(.verifying) }
    func showThreeDSPageLoadError() { events.append(.pageLoadError) }
    func stopThreeDSLoading() { events.append(.stopLoading) }

    func confirmThreeDSClose(_ decision: @escaping @MainActor (Bool) -> Void) {
        events.append(.confirmClose)
        if let confirmAnswer { decision(confirmAnswer) }
    }

    func dismissThreeDS(_ completion: @escaping @MainActor () -> Void) {
        events.append(.dismiss)
        completion()
    }

    func openExternally(_ url: URL) { events.append(.openExternally(url)) }
    func startMethodFrames(_ requests: [URLRequest], apiHost: String) { events.append(.startMethod(requests)) }
    func stopMethodFrames() { events.append(.stopMethod) }

    var loadedRequests: [URLRequest] {
        events.compactMap { if case .load(let request) = $0 { return request } else { return nil } }
    }

    var isSheetPresented: Bool { events.contains(.present) }

    func count(_ event: Event) -> Int { events.filter { $0 == event }.count }
}

/// A card flow under test with its fakes.
@MainActor
final class CardFlowHarness {
    nonisolated static let card = CardDetails(pan: "4111111111111111", cardHolder: "TEST CARD", expiryYear: "2030", expiryMonth: "12", cvv: "123")
    nonisolated static let encrypted = EncryptedCard(encryptedMessage: "RU5DUllQVEVELU1FU1NBR0U=", wrappedKey: "V1JBUFBFRC1LRVk=")
    nonisolated static let idempotencyKey = "0f8fad5b-d9cb-469f-a165-70867728950e"

    let api: RoutedClientAPI
    let clock: FakeClock
    let ui = FakeCardFlowUI()
    let flow: CardPaymentFlow
    private(set) var result: PayriffResult?
    /// How often the card was encrypted.
    var encryptions: Int { encryptCount.withLock { $0 } }
    private let encryptCount: OSAllocatedUnfairLock<Int>

    /// - Parameter checkDevice: The device integrity check before encryption; a clean device by default.
    init(
        _ scripts: [RoutedClientAPI.Route: [RoutedClientAPI.Reply]],
        clock: FakeClock = FakeClock(),
        checkDevice: @escaping @MainActor @Sendable () -> PayriffError? = { nil }
    ) {
        api = RoutedClientAPI(scripts)
        self.clock = clock
        let client = ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_TEST", clientSecret: "pr_cs_TEST"),
            appId: "com.payriff.example.ios",
            transport: api.transport,
            clock: clock
        )
        let encryptCount = OSAllocatedUnfairLock(initialState: 0)
        self.encryptCount = encryptCount
        flow = CardPaymentFlow(
            orderId: "o1",
            card: Self.card,
            apiHost: "api.payriff.com",
            dependencies: CardPaymentFlow.Dependencies(
                client: client,
                clock: clock,
                encrypt: { _ in
                    encryptCount.withLock { $0 += 1 }
                    return Self.encrypted
                },
                makeIdempotencyKey: { Self.idempotencyKey },
                checkDevice: checkDevice
            ),
            ui: ui
        )
    }

    func start() {
        Task { @MainActor in
            self.result = await self.flow.run()
        }
    }

    /// Runs the flow to its result.
    func run() async throws -> PayriffResult {
        start()
        return try await finish()
    }

    func finish() async throws -> PayriffResult {
        try await waitUntil(timeout: 20, "card flow result") { self.result != nil }
        return try #require(result)
    }

    func waitForSheet() async throws {
        try await waitUntil(timeout: 20, "3DS sheet") { self.ui.isSheetPresented && !self.ui.loadedRequests.isEmpty }
    }
}
