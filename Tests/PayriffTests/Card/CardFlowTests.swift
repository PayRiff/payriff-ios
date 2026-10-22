import Foundation
import Testing
@testable import Payriff

/// The card payment flow (CONTRACT §16.7, §16.8) with a fake Client API, a fake clock and a fake 3DS UI.
@MainActor
@Suite("Card payment flow")
struct CardFlowTests {
    typealias Bodies = CardBodies

    private static func paid(_ status: PayriffPaymentStatus = .approved) -> PayriffPayment {
        PayriffPayment(
            orderId: "o1",
            status: status,
            rawStatus: status.rawValue,
            amount: Decimal(string: "10.5", locale: Locale(identifier: "en_US_POSIX")),
            currency: "AZN"
        )
    }

    // MARK: Order, encryption and /pay

    @Test("Frictionless: GET order, POST /pay, CHECK_STATUS, then /status every 2.5 s until final")
    func frictionless() async throws {
        let harness = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.checkStatus],
            .status: [Bodies.status("PENDING"), Bodies.status("PENDING"), Bodies.status("APPROVED")],
        ])
        let result = try await harness.run()
        #expect(result == .success(Self.paid()))
        #expect(harness.api.routes == [.order, .pay, .status, .status, .status])
        #expect(harness.clock.sleeps == [2.5, 2.5])
        #expect(harness.ui.events.isEmpty, "no 3DS UI: \(harness.ui.events)")
        let pay = try #require(harness.api.requests(.pay).first)
        #expect(String(decoding: try #require(pay.httpBody), as: UTF8.self) == #"{"method":"CARD","encryptedMessage":"RU5DUllQVEVELU1FU1NBR0U="}"#)
        #expect(pay.value(forHTTPHeaderField: "x-secret-key") == CardFlowHarness.encrypted.wrappedKey)
        #expect(pay.value(forHTTPHeaderField: "X-Idempotency-Key") == CardFlowHarness.idempotencyKey)
        #expect(pay.value(forHTTPHeaderField: "Content-Type") == "application/json")
        for request in harness.api.requests {
            #expect(request.value(forHTTPHeaderField: "X-Public-Key") == "pr_pk_live_TEST")
            #expect(request.value(forHTTPHeaderField: "X-Client-Secret") == "pr_cs_TEST")
            #expect(request.value(forHTTPHeaderField: "X-Client-App-Id") == "com.payriff.example.ios")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        }
    }

    @Test("An order that is not CREATED/PENDING or has no CARD is ORDER_NOT_PAYABLE; nothing is paid")
    func orderNotPayable() async throws {
        for order in [Bodies.order(status: "APPROVED"), Bodies.order(methods: ["GOOGLE_PAY"])] {
            let harness = CardFlowHarness([.order: [order]])
            let result = try await harness.run()
            #expect(result.error?.code == .orderNotPayable)
            #expect(result.error?.isFatal == false)
            #expect(harness.api.routes == [.order])
        }
        let pending = CardFlowHarness([.order: [Bodies.order(status: "PENDING")], .pay: [Bodies.checkStatus], .status: [Bodies.status("DECLINED")]])
        #expect(try await pending.run() == .declined(Self.paid(.declined)))
    }

    @Test("Order and /pay errors map like the web SDK and end the flow")
    func payErrors() async throws {
        let cases: [(RoutedClientAPI.Route, RoutedClientAPI.Reply, PayriffError.Code, Bool)] = [
            (.order, Bodies.error(404, code: "01000", message: "Order not found"), .sessionExpired, true),
            (.order, Bodies.error(401, code: "14010", message: "App is not allowed for this public key"), .unauthorized, true),
            (.pay, Bodies.error(400, code: "15400", message: "encryptedMessage is required for CARD"), .invalidRequest, false),
            (.pay, Bodies.error(400, code: "01000", message: "Order is not payable"), .orderNotPayable, false),
            (.pay, Bodies.error(200, code: "16001", message: "Card declined by issuer"), .paymentFailed, false),
        ]
        for (route, reply, code, fatal) in cases {
            var scripts: [RoutedClientAPI.Route: [RoutedClientAPI.Reply]] = [.order: [Bodies.order()], .pay: [Bodies.checkStatus]]
            scripts[route] = [reply]
            let harness = CardFlowHarness(scripts)
            let error = try #require(try await harness.run().error)
            #expect(error.code == code)
            #expect(error.isFatal == fatal)
            #expect(!harness.api.routes.contains(.status), "\(code): no status polling after a refused /pay")
            if code == .paymentFailed {
                #expect(error.message == "Card declined by issuer")
                #expect(error.isRetryable)
            }
        }
    }

    @Test("/pay 429 is retried after 1 s and 2 s with the identical bytes and idempotency key")
    func payRateLimited() async throws {
        let harness = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.error(429, code: "01000"), .json(429, ""), Bodies.checkStatus],
            .status: [Bodies.status("APPROVED")],
        ])
        #expect(try await harness.run() == .success(Self.paid()))
        let pays = harness.api.requests(.pay)
        #expect(pays.count == 3)
        #expect(Set(pays.map(\.httpBody)).count == 1)
        #expect(Set(pays.map { $0.value(forHTTPHeaderField: "X-Idempotency-Key") }) == [CardFlowHarness.idempotencyKey])
        #expect(Set(pays.map { $0.value(forHTTPHeaderField: "x-secret-key") }).count == 1)
        #expect(harness.clock.sleeps == [1, 2])
    }

    @Test("A network error on /pay is retried once after 1 s with the same bytes; a second one fails")
    func payNetworkRetry() async throws {
        let retried = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [.network, Bodies.checkStatus],
            .status: [Bodies.status("APPROVED")],
        ])
        #expect(try await retried.run() == .success(Self.paid()))
        let pays = retried.api.requests(.pay)
        #expect(pays.count == 2)
        #expect(pays[0] == pays[1], "identical request: URL, headers (idempotency key) and body")
        #expect(retried.clock.sleeps.first == 1)

        let failing = CardFlowHarness([.order: [Bodies.order()], .pay: [.network]])
        let error = try #require(try await failing.run().error)
        #expect(error.code == .networkError)
        #expect(!error.isFatal)
        #expect(failing.api.requests(.pay).count == 2)

        // GET requests are not retried on network errors.
        let order = CardFlowHarness([.order: [.network]])
        #expect(try await order.run().error?.code == .networkError)
        #expect(order.api.requests(.order).count == 1)
    }

    @Test("Encryption failure is UNKNOWN and sends nothing")
    func encryptionFailure() async throws {
        let api = RoutedClientAPI([.order: [Bodies.order()]])
        let ui = FakeCardFlowUI()
        let client = ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_TEST", clientSecret: "pr_cs_TEST"),
            appId: nil,
            transport: api.transport,
            clock: FakeClock()
        )
        let flow = CardPaymentFlow(
            orderId: "o1",
            card: CardFlowHarness.card,
            apiHost: "api.payriff.com",
            dependencies: CardPaymentFlow.Dependencies(client: client, clock: FakeClock(), encrypt: { _ in throw CardCryptoError.randomUnavailable }),
            ui: ui
        )
        let result = await flow.run()
        #expect(result.error?.code == .unknown)
        #expect(api.routes == [.order])
    }

    // MARK: Status polling (CONTRACT §16.7 step 5)

    @Test("Status polling: every 2.5 s for 120 s, then pending(notFinal) with the last status")
    func statusTimeout() async throws {
        let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.checkStatus], .status: [Bodies.status("PENDING")]])
        let result = try await harness.run()
        #expect(result == .pending(Self.paid(.pending), reason: .notFinal))
        #expect(harness.api.requests(.status).count == 49)
        #expect(harness.clock.sleeps == Array(repeating: 2.5, count: 48))
        #expect(harness.clock.now == 120)
    }

    @Test("Status polling continues on NETWORK_ERROR and stops on other errors with pending(verificationFailed)")
    func statusErrors() async throws {
        let network = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.checkStatus],
            .status: [.network, Bodies.status("PENDING"), .network, Bodies.status("CANCELED")],
        ])
        let cancelled = try await network.run()
        #expect(cancelled == .cancelled(PayriffPayment(orderId: "o1", status: .canceled, rawStatus: "CANCELED", amount: Decimal(string: "10.5", locale: Locale(identifier: "en_US_POSIX")), currency: "AZN"), reason: .canceled))
        #expect(network.api.requests(.status).count == 4)

        let expired = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.checkStatus],
            .status: [Bodies.status("PENDING"), Bodies.error(404, code: "01000")],
        ])
        #expect(try await expired.run() == .pending(Self.paid(.pending), reason: .verificationFailed))

        let refunded = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.checkStatus], .status: [Bodies.status("REFUNDED")]])
        #expect(try await refunded.run() == .pending(Self.paid(.refunded), reason: .unexpectedStatus))
    }

    @Test("An unknown or unsafe nextAction: one status check; final maps, otherwise UNEXPECTED_RESPONSE")
    func invalidNextAction() async throws {
        let notFinal = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.invalid], .status: [Bodies.status("PENDING")]])
        let error = try #require(try await notFinal.run().error)
        #expect(error.code == .unexpectedResponse)
        #expect(notFinal.api.requests(.status).count == 1)

        let final = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.invalid], .status: [Bodies.status("APPROVED")]])
        #expect(try await final.run() == .success(Self.paid()))

        // An http accessUrl is invalid: never loaded.
        let unsafe = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.envelope(#"{"nextAction":"THREE_DS","accessUrl":"http://acs.bank.example/c","clientRequest":[{"key":"creq","value":"a"}]}"#)],
            .status: [Bodies.status("PENDING")],
        ])
        #expect(try await unsafe.run().error?.code == .unexpectedResponse)
        #expect(unsafe.ui.events.isEmpty)
    }

    // MARK: 3DS challenge in the sheet (CONTRACT §16.8)

    @Test("Challenge: a native form POST in the sheet; the callback loads, parallel polling closes the sheet on a final status")
    func challengeParallelPolling() async throws {
        let harness = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.challenge],
            .status: [Bodies.status("PENDING"), Bodies.status("APPROVED")],
        ])
        harness.start()
        try await harness.waitForSheet()
        let request = try #require(harness.ui.loadedRequests.first)
        #expect(request.url == Bodies.acsURL)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == "creq=\(Bodies.creq)&threeDSSessionData=")
        #expect(harness.ui.sheetFlow === harness.flow)

        let flow = harness.flow
        #expect(flow.decideNavigation(to: Bodies.acsURL, isMainFrame: true, inPopup: false) == .allow)
        #expect(flow.decideNavigation(to: URL(string: "https://acs.bank.example/frame")!, isMainFrame: false, inPopup: false) == .allow)
        #expect(harness.api.requests(.status).isEmpty, "no polling before the callback")
        #expect(flow.decideNavigation(to: Bodies.callback, isMainFrame: true, inPopup: false) == .allow, "the callback is never cancelled")
        flow.pageDidCommit(Bodies.callback)
        flow.pageDidFinish(Bodies.callback)
        let result = try await harness.finish()
        #expect(result == .success(Self.paid()))
        #expect(harness.ui.count(.dismiss) == 1)
        #expect(harness.api.requests(.status).count == 2)
        #expect(flow.isFinished)
        #expect(flow.decideNavigation(to: Bodies.merchantReturn, isMainFrame: true, inPopup: false) == .cancel)
    }

    @Test("Challenge: the first main-frame navigation after the callback is cancelled, the sheet closes, then polling")
    func challengeFinishesOnNavigation() async throws {
        let harness = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.challenge],
            .status: [Bodies.status("DECLINED")],
        ])
        harness.start()
        try await harness.waitForSheet()
        let flow = harness.flow
        #expect(flow.decideNavigation(to: Bodies.callback, isMainFrame: true, inPopup: false) == .allow)
        #expect(flow.decideNavigation(to: URL(string: "about:blank")!, isMainFrame: true, inPopup: false) == .allow)
        #expect(flow.decideNavigation(to: Bodies.merchantReturn, isMainFrame: true, inPopup: false) == .cancel)
        let result = try await harness.finish()
        #expect(result == .declined(Self.paid(.declined)))
        let loaded = try #require(harness.ui.loadedRequests.first)
        #expect(harness.ui.events == [.present, .load(loaded), .dismiss])
        #expect(harness.api.requests(.status).count == 1)
    }

    @Test("Close: confirmation, the verifying overlay, one status check; non-final is pending(notFinal), never cancelled")
    func closePath() async throws {
        let cases: [([RoutedClientAPI.Reply], PayriffResult)] = [
            ([Bodies.status("CREATED")], .pending(Self.paid(.created), reason: .notFinal)),
            ([Bodies.status("PENDING")], .pending(Self.paid(.pending), reason: .notFinal)),
            ([Bodies.status("DECLINED")], .declined(Self.paid(.declined))),
            ([.network], .pending(PayriffPayment(orderId: "o1", status: .unknown), reason: .notFinal)),
        ]
        for (status, expected) in cases {
            let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.challenge], .status: status])
            harness.start()
            try await harness.waitForSheet()
            harness.flow.requestClose()
            let result = try await harness.finish()
            #expect(result == expected)
            #expect(Array(harness.ui.events.suffix(4)) == [.confirmClose, .stopLoading, .verifying, .dismiss])
            #expect(harness.api.requests(.status).count == 1)
        }
    }

    @Test("Close declined: the sheet stays and the flow continues")
    func closeDeclined() async throws {
        let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.challenge], .status: [Bodies.status("APPROVED")]])
        harness.ui.confirmAnswer = false
        harness.start()
        try await harness.waitForSheet()
        harness.flow.requestClose()
        #expect(harness.api.requests(.status).isEmpty)
        #expect(!harness.flow.isFinished)
        _ = harness.flow.decideNavigation(to: Bodies.callback, isMainFrame: true, inPopup: false)
        _ = harness.flow.decideNavigation(to: Bodies.merchantReturn, isMainFrame: true, inPopup: false)
        #expect(try await harness.finish() == .success(Self.paid()))
    }

    @Test("The app dismissing the sheet: one status check without UI")
    func externalDismissal() async throws {
        let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.challenge], .status: [Bodies.status("PENDING")]])
        harness.start()
        try await harness.waitForSheet()
        harness.flow.sheetWasDismissedExternally()
        #expect(try await harness.finish() == .pending(Self.paid(.pending), reason: .notFinal))
        #expect(!harness.ui.events.contains(.dismiss))
        #expect(!harness.ui.events.contains(.confirmClose))
    }

    @Test("REDIRECT opens the URL (GET) in the sheet")
    func redirect() async throws {
        let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.redirect], .status: [Bodies.status("APPROVED")]])
        harness.start()
        try await harness.waitForSheet()
        let request = try #require(harness.ui.loadedRequests.first)
        #expect(request.url == Bodies.redirectURL)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        _ = harness.flow.decideNavigation(to: Bodies.callback, isMainFrame: true, inPopup: false)
        harness.flow.pageDidFinish(Bodies.callback)
        #expect(try await harness.finish() == .success(Self.paid()))
    }

    @Test("When the sheet cannot be presented: one status check, pending(notFinal) unless final")
    func presentationFailure() async throws {
        let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.challenge], .status: [Bodies.status("PENDING")]])
        harness.ui.presentSucceeds = false
        #expect(try await harness.run() == .pending(Self.paid(.pending), reason: .notFinal))
        #expect(harness.ui.events.isEmpty)
    }

    @Test("In the sheet: bank apps go to iOS, non-https pages are blocked, popups never open")
    func sheetNavigationRules() async throws {
        let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.challenge], .status: [Bodies.status("PENDING")]])
        harness.start()
        try await harness.waitForSheet()
        let flow = harness.flow
        let bankApp = URL(string: "birbank://confirm?id=1")!
        #expect(flow.decideNavigation(to: bankApp, isMainFrame: true, inPopup: false) == .cancel)
        #expect(harness.ui.events.contains(.openExternally(bankApp)))
        #expect(flow.decideNavigation(to: URL(string: "http://acs.bank.example/x")!, isMainFrame: true, inPopup: false) == .cancel)
        #expect(flow.decideNavigation(to: URL(string: "javascript:alert(1)")!, isMainFrame: true, inPopup: false) == .cancel)
        #expect(flow.decideNavigation(to: Bodies.acsURL, isMainFrame: true, inPopup: true) == .cancel)
        flow.windowRequested(to: URL(string: "https://acs.bank.example/terms")!)
        #expect(!harness.ui.events.contains(.openExternally(URL(string: "https://acs.bank.example/terms")!)), "https stays out of the OS")
        let popupApp = URL(string: "bankapp://open")!
        flow.windowRequested(to: popupApp)
        #expect(harness.ui.events.contains(.openExternally(popupApp)))
        harness.flow.sheetWasDismissedExternally()
        _ = try await harness.finish()
    }

    @Test("A page-load error shows page_load_error; Try again reloads (the original POST before any page committed)")
    func pageLoadErrorAndRetry() async throws {
        let harness = CardFlowHarness([.order: [Bodies.order()], .pay: [Bodies.challenge], .status: [Bodies.status("APPROVED")]])
        harness.start()
        try await harness.waitForSheet()
        let flow = harness.flow
        let original = try #require(harness.ui.loadedRequests.first)
        // Cancellations by the SDK and scheme hand-offs are not errors.
        flow.pageDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), failingURL: Bodies.acsURL)
        flow.pageDidFail(NSError(domain: "WebKitErrorDomain", code: 102), failingURL: Bodies.acsURL)
        flow.pageDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL), failingURL: URL(string: "bank://x"))
        #expect(!harness.ui.events.contains(.pageLoadError))
        flow.pageDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), failingURL: Bodies.acsURL)
        #expect(harness.ui.events.last == .pageLoadError)
        flow.retry()
        #expect(Array(harness.ui.events.suffix(2)) == [.content, .load(original)])
        // After a page committed, Try again reloads the failed page.
        flow.pageDidCommit(Bodies.acsURL)
        let next = URL(string: "https://acs.bank.example/step2")!
        flow.pageDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), failingURL: next)
        flow.retry()
        #expect(harness.ui.loadedRequests.last?.url == next)
        flow.webContentProcessDidTerminate()
        #expect(harness.ui.events.last == .pageLoadError)
        flow.retry()
        _ = flow.decideNavigation(to: Bodies.callback, isMainFrame: true, inPopup: false)
        _ = flow.decideNavigation(to: Bodies.merchantReturn, isMainFrame: true, inPopup: false)
        #expect(try await harness.finish() == .success(Self.paid()))
    }

    // MARK: 3DS method and the /three-ds loop

    @Test("3DS method: two hidden POSTs, then /three-ds every 1 s; wait, empty method and network errors continue")
    func methodThenChallenge() async throws {
        let harness = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.method],
            .threeDS: [Bodies.wait, Bodies.emptyThreeDS, .network, Bodies.challenge],
            .status: [Bodies.status("APPROVED")],
        ])
        harness.start()
        try await harness.waitForSheet()
        guard case .startMethod(let frames)? = harness.ui.events.first else {
            Issue.record("expected the hidden method web views first: \(harness.ui.events)")
            return
        }
        #expect(frames.count == 2)
        #expect(frames[0].url == Bodies.methodURL)
        #expect(frames[0].httpMethod == "POST")
        #expect(String(decoding: try #require(frames[0].httpBody), as: UTF8.self) == "threeDSMethodData=\(Bodies.methodData)")
        #expect(frames[1].url == Bodies.methodServerURL)
        #expect(frames[1].httpMethod == "POST")
        #expect(frames[1].httpBody?.isEmpty == true)
        #expect(harness.ui.events[1] == .stopMethod, "the hidden web views are destroyed when polling ends")
        #expect(harness.ui.events[2] == .present)
        #expect(harness.api.requests(.threeDS).count == 4)
        #expect(harness.flow.threeDSPolls == 4)
        #expect(harness.clock.sleeps == [1, 1, 1, 1])
        _ = harness.flow.decideNavigation(to: Bodies.callback, isMainFrame: true, inPopup: false)
        _ = harness.flow.decideNavigation(to: Bodies.merchantReturn, isMainFrame: true, inPopup: false)
        #expect(try await harness.finish() == .success(Self.paid()))
    }

    @Test("WAIT polls /three-ds at most 30 times in total, then status polling")
    func threeDSLoopLimit() async throws {
        let harness = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.wait],
            .threeDS: [Bodies.wait],
            .status: [Bodies.status("APPROVED")],
        ])
        #expect(try await harness.run() == .success(Self.paid()))
        #expect(harness.api.requests(.threeDS).count == 30)
        #expect(harness.ui.events.isEmpty)

        // A method step inside the loop restarts the hidden web views but shares the same budget.
        let method = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.method],
            .threeDS: [Bodies.wait, Bodies.method, Bodies.wait],
            .status: [Bodies.status("APPROVED")],
        ])
        #expect(try await method.run() == .success(Self.paid()))
        #expect(method.api.requests(.threeDS).count == 30)
        #expect(method.ui.events.filter { if case .startMethod = $0 { return true } else { return false } }.count == 2)
        #expect(method.ui.events.last == .stopMethod)
    }

    @Test("A /three-ds error other than NETWORK_ERROR: one status check, else the error")
    func threeDSError() async throws {
        let harness = CardFlowHarness([
            .order: [Bodies.order()],
            .pay: [Bodies.wait],
            .threeDS: [Bodies.error(404, code: "01000", message: "Order not found")],
            .status: [Bodies.status("PENDING")],
        ])
        let error = try #require(try await harness.run().error)
        #expect(error.code == .sessionExpired)
        #expect(error.isFatal)
        #expect(harness.api.requests(.status).count == 1)
    }

    @Test("Form encoding: unreserved characters kept, space as +, everything else percent-encoded")
    func formEncoding() {
        #expect(CardPaymentFlow.formEncoded([("creq", "ab+/= c"), ("k*-._", "ə")]) == "creq=ab%2B%2F%3D+c&k*-._=%C9%99")
        #expect(CardPaymentFlow.formEncoded([]) == "")
    }
}
