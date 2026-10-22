import Foundation

/// The view layer of a card payment's 3-D Secure step: the 3DS sheet and the hidden 3DS-method
/// web views. The UIKit presenter in the app, a fake in tests.
@MainActor
protocol CardFlowUI: AnyObject {
    /// Presents the 3DS sheet driven by `flow`. Returns `false` when nothing can present it.
    func presentThreeDSSheet(for flow: any SheetFlowHandling) -> Bool
    /// Loads `request` (a GET, or a form POST) in the sheet's web view.
    func loadThreeDS(_ request: URLRequest)
    /// Shows the web content again (after the page-load error).
    func showThreeDSContent()
    /// Shows the sheet's "Checking payment…" overlay; closing is disabled while it shows.
    func showThreeDSVerifying()
    /// Shows `page_load_error` with "Try again" and "Close".
    func showThreeDSPageLoadError()
    /// Stops loading in the sheet.
    func stopThreeDSLoading()
    /// Asks the customer to confirm closing; calls `decision` exactly once.
    func confirmThreeDSClose(_ decision: @escaping @MainActor (Bool) -> Void)
    /// Dismisses the sheet and calls `completion` exactly once afterwards.
    func dismissThreeDS(_ completion: @escaping @MainActor () -> Void)
    /// Hands `url` to the operating system (a bank app).
    func openExternally(_ url: URL)
    /// Loads each request in its own hidden web view (the 3DS method, CONTRACT §16.7).
    func startMethodFrames(_ requests: [URLRequest], apiHost: String)
    /// Destroys the hidden web views.
    func stopMethodFrames()
}

/// The card payment after the form was validated (CONTRACT §16.7 steps 2–5), independent of
/// UIKit: load the order, check the device (CONTRACT §16.16), encrypt and `POST /pay`, run
/// `nextAction` (3-D Secure in the sheet or in hidden web views), then resolve the status.
/// ``run()`` returns exactly one result.
///
/// While the 3DS sheet is up, the flow is the sheet's ``SheetFlowHandling`` and decides its
/// navigations with ``ThreeDSNavigator`` (CONTRACT §16.8).
@MainActor
final class CardPaymentFlow: SheetFlowHandling {
    struct Dependencies: Sendable {
        var client: ClientAPIClient
        var clock: any PaymentClock
        /// Encrypts the card; fresh key material on every call.
        var encrypt: @Sendable (CardDetails) throws -> EncryptedCard
        /// A new idempotency key per pay attempt.
        var makeIdempotencyKey: @Sendable () -> String
        /// The device integrity check right before the card is encrypted (CONTRACT §16.16): an
        /// error ends the payment with it. It has no default, so no flow runs without it.
        var checkDevice: @MainActor @Sendable () -> PayriffError?

        init(
            client: ClientAPIClient,
            clock: any PaymentClock,
            encrypt: @escaping @Sendable (CardDetails) throws -> EncryptedCard = { try CardCrypto.encrypt($0) },
            makeIdempotencyKey: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
            checkDevice: @escaping @MainActor @Sendable () -> PayriffError?
        ) {
            self.client = client
            self.clock = clock
            self.encrypt = encrypt
            self.makeIdempotencyKey = makeIdempotencyKey
            self.checkDevice = checkDevice
        }
    }

    /// `/three-ds` polling: every 1 s, at most 30 requests in one flow.
    static let threeDSPollInterval: TimeInterval = 1
    static let threeDSPollLimit = 30
    /// `/status` polling: every 2.5 s from the terminal signal, for at most 120 s.
    static let statusPollInterval: TimeInterval = 2.5
    static let statusPollTimeout: TimeInterval = 120

    private enum SheetOutcome {
        /// The first main-frame navigation after the gateway callback.
        case navigationFinished
        /// Status polling found a final status while the sheet was up.
        case finalStatus(StatusSnapshot)
        /// The customer (or the app) closed the sheet; the single check gave this result.
        case closed(PayriffResult)
        /// The sheet could not be presented.
        case presentationFailed
    }

    private enum SheetState {
        case none
        /// The sheet is up and its navigations decide the outcome.
        case active
        /// The single status check of a close runs.
        case closing
        /// The outcome is known; the sheet is being dismissed.
        case ending
    }

    private enum StatusPollOutcome: Sendable {
        case final(StatusSnapshot)
        case timedOut
        case failed(PayriffError)
    }

    let orderId: String
    /// The lower-cased API host, which identifies gateway callbacks.
    let apiHost: String

    /// The card until it is encrypted; dropped right after the encryption attempt, so the flow
    /// does not keep the plaintext through 3-D Secure and status polling (CONTRACT §16.5).
    private var card: CardDetails?
    private let dependencies: Dependencies
    private let ui: any CardFlowUI

    private var navigator: ThreeDSNavigator
    private var sheetState = SheetState.none
    private var sheetContinuation: CheckedContinuation<SheetOutcome, Never>?
    private var isSheetPresented = false
    private var isConfirmingClose = false
    private var isShowingPageLoadError = false
    private var initialSheetRequest: URLRequest?
    private var hasCommittedPage = false
    private var lastCommittedURL: URL?
    private var failedURL: URL?
    private var areMethodFramesRunning = false
    private var statusPoll: Task<StatusPollOutcome, Never>?
    /// Identifies the current status poll, so an older one never clears a newer one.
    private var statusPollGeneration = 0
    /// The last status `/status` returned.
    private(set) var lastStatus: StatusSnapshot?
    /// How many `/three-ds` requests were sent.
    private(set) var threeDSPolls = 0

    init(orderId: String, card: CardDetails, apiHost: String, dependencies: Dependencies, ui: any CardFlowUI) {
        self.orderId = orderId
        self.card = card
        self.apiHost = apiHost.lowercased()
        self.dependencies = dependencies
        self.ui = ui
        self.navigator = ThreeDSNavigator(apiHost: apiHost)
    }

    /// Runs the payment to its result.
    func run() async -> PayriffResult {
        let result = await confirm()
        // Also when the flow ended before encrypting (order not payable, network error).
        card = nil
        stopMethodFramesIfNeeded()
        statusPoll?.cancel()
        statusPoll = nil
        await dismissSheetIfNeeded()
        sheetState = .none
        Log.info("Card payment finished: \(result.type)\(result.payment.map { " order=\($0.orderId) status=\($0.status.rawValue)" } ?? "")\(result.error.map { " error=\($0.code.rawValue)" } ?? "")")
        return result
    }

    private var client: ClientAPIClient { dependencies.client }

    /// Whether the flow still holds the plaintext card (tests).
    var holdsCardDetails: Bool { card != nil }

    private func confirm() async -> PayriffResult {
        Log.info("Card payment for order \(orderId): loading the order.")
        // Step 2: the order must be payable by card.
        switch await client.order(orderId) {
        case .failure(let error):
            return .failed(error)
        case .success(let order) where !order.isPayableByCard:
            let status = order.rawStatus ?? order.status.rawValue
            let methods = order.paymentMethods.isEmpty ? "none" : order.paymentMethods.joined(separator: ", ")
            return .failed(PayriffError(
                code: .orderNotPayable,
                message: "The order cannot be paid by card (status \(status), payment methods \(methods))."
            ))
        case .success:
            break
        }

        // A hooking tool can attach after the payment started: the device is checked again right
        // before the card is encrypted (CONTRACT §16.16).
        if let refusal = dependencies.checkDevice() {
            card = nil
            return .failed(refusal)
        }

        // Step 3: encrypt with fresh key material and POST /pay. Only the ciphertext is kept.
        let encryption: Result<EncryptedCard, any Error>
        if let card {
            encryption = Result { try dependencies.encrypt(card) }
        } else {
            encryption = .failure(CardCryptoError.encryptionFailed)
        }
        card = nil
        let encrypted: EncryptedCard
        switch encryption {
        case .success(let value):
            encrypted = value
        case .failure:
            Log.error("The card could not be encrypted.")
            return .failed(PayriffError(code: .unknown, message: "The card could not be encrypted on this device."))
        }
        let action: CardNextAction
        switch await client.pay(orderId, card: encrypted, idempotencyKey: dependencies.makeIdempotencyKey()) {
        case .failure(let error):
            return .failed(error)
        case .success(let next):
            action = next
        }
        Log.info("POST /pay -> \(action)")
        // Step 4.
        return await runNextAction(action)
    }

    // MARK: - nextAction (CONTRACT §16.7 step 4)

    private func runNextAction(_ first: CardNextAction) async -> PayriffResult {
        var action = first
        while true {
            switch action {
            case .challenge(let url, let form):
                return await runSheet(Self.formPost(url, fields: form.map { ($0.key, $0.value) }))
            case .redirect(let url):
                return await runSheet(URLRequest(url: url))
            case .checkStatus:
                return await pollToResult()
            case .invalid:
                return await singleCheck(otherwise: PayriffError(
                    code: .unexpectedResponse,
                    message: "Payriff returned a next step the SDK cannot run safely."
                ))
            case .method(let methodURL, let methodData, let serverURL):
                startMethodFrames(methodURL: methodURL, methodData: methodData, serverURL: serverURL)
            case .wait:
                break
            }
            // The /three-ds loop, shared by every wait and method step of this flow.
            switch await pollThreeDS() {
            case .next(let next):
                if case .method = next {
                    action = next
                    continue
                }
                stopMethodFramesIfNeeded()
                action = next
            case .exhausted:
                stopMethodFramesIfNeeded()
                Log.info("No 3-D Secure step after \(threeDSPolls) /three-ds requests; checking the status.")
                return await pollToResult()
            case .failed(let error):
                stopMethodFramesIfNeeded()
                return await singleCheck(otherwise: error)
            }
        }
    }

    private enum ThreeDSPollResult {
        case next(CardNextAction)
        case exhausted
        case failed(PayriffError)
    }

    /// Polls `/three-ds` every second until it returns a step to run. `wait`, a `method` with
    /// nothing to post and `NETWORK_ERROR` continue; the loop is limited to
    /// ``threeDSPollLimit`` requests per flow.
    private func pollThreeDS() async -> ThreeDSPollResult {
        while threeDSPolls < Self.threeDSPollLimit {
            do {
                try await dependencies.clock.sleep(for: Self.threeDSPollInterval)
            } catch {
                return .exhausted
            }
            threeDSPolls += 1
            switch await client.threeDS(orderId) {
            case .failure(let error) where error.code == .networkError:
                continue
            case .failure(let error):
                return .failed(error)
            case .success(let next):
                if next == .wait || next.isEmptyMethod { continue }
                Log.info("GET /three-ds -> \(next)")
                return .next(next)
            }
        }
        return .exhausted
    }

    private func startMethodFrames(methodURL: URL?, methodData: String?, serverURL: URL?) {
        var requests: [URLRequest] = []
        if let methodURL {
            requests.append(Self.formPost(methodURL, fields: [("threeDSMethodData", methodData ?? "")]))
        }
        if let serverURL {
            requests.append(Self.formPost(serverURL, fields: []))
        }
        guard !requests.isEmpty else { return }
        stopMethodFramesIfNeeded()
        Log.info("Running the 3DS method in \(requests.count) hidden web view(s).")
        areMethodFramesRunning = true
        ui.startMethodFrames(requests, apiHost: apiHost)
    }

    private func stopMethodFramesIfNeeded() {
        guard areMethodFramesRunning else { return }
        areMethodFramesRunning = false
        ui.stopMethodFrames()
    }

    // MARK: - Status (CONTRACT §16.7 step 5)

    /// Starts status polling unless it already runs.
    @discardableResult
    private func startStatusPollIfNeeded() -> Task<StatusPollOutcome, Never> {
        if let statusPoll { return statusPoll }
        Log.info("Polling the order status every \(Self.statusPollInterval) s.")
        statusPollGeneration += 1
        let generation = statusPollGeneration
        let task = Task { @MainActor [weak self] () -> StatusPollOutcome in
            guard let self else { return .timedOut }
            let outcome = await self.pollStatus()
            // A poll that ended without a final status lets a later terminal signal start a new one.
            if case .final = outcome {} else if self.statusPollGeneration == generation {
                self.statusPoll = nil
            }
            return outcome
        }
        statusPoll = task
        return task
    }

    private func pollStatus() async -> StatusPollOutcome {
        let clock = dependencies.clock
        let start = clock.now
        while !Task.isCancelled {
            switch await client.status(orderId) {
            case .success(let snapshot):
                lastStatus = snapshot
                Log.info("Order status: \(snapshot.status.rawValue) (raw \(snapshot.rawStatus ?? "nil"))")
                if snapshot.status.isFinal {
                    statusPollFoundFinal(snapshot)
                    return .final(snapshot)
                }
            case .failure(let error) where error.code == .networkError:
                break
            case .failure(let error):
                return .failed(error)
            }
            if clock.now - start + Self.statusPollInterval > Self.statusPollTimeout { return .timedOut }
            do {
                try await clock.sleep(for: Self.statusPollInterval)
            } catch {
                return .timedOut
            }
        }
        return .timedOut
    }

    /// A final status ends the 3DS sheet even when no navigation follows the callback.
    private func statusPollFoundFinal(_ snapshot: StatusSnapshot) {
        guard sheetState == .active else { return }
        Log.info("A final status arrived while the 3-D Secure sheet is open; closing it.")
        sheetState = .ending
        resolveSheet(.finalStatus(snapshot))
    }

    /// The result of status polling: a final status maps through CONTRACT §8.2, a timeout is
    /// `pending(notFinal)`, and a failure that is not a network error `pending(verificationFailed)`.
    private func pollToResult() async -> PayriffResult {
        switch await startStatusPollIfNeeded().value {
        case .final(let snapshot):
            return finalResult(snapshot)
        case .timedOut:
            return .pending(payment(lastStatus), reason: .notFinal)
        case .failed(let error):
            Log.warning("Status polling stopped: \(error.code.rawValue)")
            return .pending(payment(lastStatus), reason: .verificationFailed)
        }
    }

    /// One status check: a final status maps through CONTRACT §8.2, anything else is `failed(otherwise)`.
    private func singleCheck(otherwise error: PayriffError) async -> PayriffResult {
        if case .success(let snapshot) = await client.status(orderId) {
            lastStatus = snapshot
            if snapshot.status.isFinal { return finalResult(snapshot) }
        }
        return .failed(error)
    }

    /// The single check of a close: a final status maps, anything else is `pending(notFinal)`,
    /// because the card was already submitted (CONTRACT §16.8).
    private func closeCheckResult() async -> PayriffResult {
        switch await client.status(orderId) {
        case .success(let snapshot):
            lastStatus = snapshot
            return snapshot.status.isFinal ? finalResult(snapshot) : .pending(payment(snapshot), reason: .notFinal)
        case .failure(let error):
            Log.warning("The status check of the close failed: \(error.code.rawValue)")
            return .pending(payment(lastStatus), reason: .notFinal)
        }
    }

    private func payment(_ snapshot: StatusSnapshot?) -> PayriffPayment {
        PayriffPayment(
            orderId: orderId,
            status: snapshot?.status ?? .unknown,
            rawStatus: snapshot?.rawStatus,
            amount: snapshot?.amount,
            currency: snapshot?.currency,
            transactionId: nil,
            originalOrderId: nil
        )
    }

    /// Maps a status (CONTRACT §8.2).
    private func finalResult(_ snapshot: StatusSnapshot) -> PayriffResult {
        let payment = payment(snapshot)
        switch snapshot.status.outcome {
        case .success: return .success(payment)
        case .declined: return .declined(payment)
        case .cancelled(let reason): return .cancelled(payment, reason: reason)
        case .unexpectedFinal: return .pending(payment, reason: .unexpectedStatus)
        case .nonFinal: return .pending(payment, reason: .notFinal)
        }
    }

    // MARK: - 3DS sheet (CONTRACT §16.8)

    private func runSheet(_ request: URLRequest) async -> PayriffResult {
        navigator = ThreeDSNavigator(apiHost: apiHost)
        initialSheetRequest = request
        hasCommittedPage = false
        lastCommittedURL = nil
        failedURL = nil
        isShowingPageLoadError = false
        let outcome: SheetOutcome = await withCheckedContinuation { continuation in
            sheetContinuation = continuation
            sheetState = .active
            guard ui.presentThreeDSSheet(for: self) else {
                Log.error("The 3-D Secure sheet could not be presented; checking the status once.")
                sheetState = .none
                resolveSheet(.presentationFailed)
                return
            }
            isSheetPresented = true
            Log.info("3-D Secure sheet: \(request.httpMethod ?? "GET") \(Log.redactedURL(request.url))")
            ui.loadThreeDS(request)
        }
        switch outcome {
        case .navigationFinished:
            await dismissSheetIfNeeded()
            return await pollToResult()
        case .finalStatus(let snapshot):
            await dismissSheetIfNeeded()
            return finalResult(snapshot)
        case .closed(let result):
            return result
        case .presentationFailed:
            return await closeCheckResult()
        }
    }

    private func resolveSheet(_ outcome: SheetOutcome) {
        guard let continuation = sheetContinuation else { return }
        sheetContinuation = nil
        continuation.resume(returning: outcome)
    }

    private func dismissSheetIfNeeded() async {
        guard isSheetPresented else { return }
        isSheetPresented = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ui.dismissThreeDS { continuation.resume() }
        }
    }

    /// A close confirmed by the customer, or the sheet going away: one status check, then the result.
    private func closeSheetWithSingleCheck(showingUI: Bool) {
        guard sheetState == .active else { return }
        sheetState = .closing
        statusPoll?.cancel()
        statusPoll = nil
        if showingUI {
            ui.stopThreeDSLoading()
            ui.showThreeDSVerifying()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.closeCheckResult()
            self.sheetState = .ending
            await self.dismissSheetIfNeeded()
            self.resolveSheet(.closed(result))
        }
    }

    var isFinished: Bool {
        sheetState == .none || sheetState == .ending
    }

    func decideNavigation(to url: URL?, isMainFrame: Bool, inPopup: Bool) -> NavigationResponse {
        guard sheetState == .active, !inPopup else { return .cancel }
        let action = navigator.decide(url, isMainFrame: isMainFrame)
        Log.debug("3DS navigation \(isMainFrame ? "main" : "sub") \(Log.redactedURL(url)) -> \(action.rawValue)")
        switch action {
        case .allow:
            return .allow
        case .allowCallback:
            // Never cancelled: this request carries the bank's answer to Payriff.
            return .allow
        case .finish:
            Log.info("3-D Secure ended: the navigation after Payriff's callback was cancelled.")
            sheetState = .ending
            resolveSheet(.navigationFinished)
            return .cancel
        case .external:
            if let url { ui.openExternally(url) }
            return .cancel
        case .block:
            return .cancel
        }
    }

    func windowRequested(to url: URL?) {
        // The sheet never opens windows; a bank-app link in a popup still reaches iOS.
        guard sheetState == .active, let url else { return }
        var probe = navigator
        if probe.decide(url, isMainFrame: true) == .external {
            ui.openExternally(url)
        }
    }

    func pageDidCommit(_ url: URL?) {
        guard sheetState == .active else { return }
        hasCommittedPage = true
        lastCommittedURL = url
    }

    func pageDidFinish(_ url: URL?) {
        guard sheetState == .active, navigator.isCallback(url) else { return }
        // In parallel with the sheet: a final status closes it even if nothing navigates.
        startStatusPollIfNeeded()
    }

    func pageDidFail(_ error: any Error, failingURL: URL?) {
        guard sheetState == .active else { return }
        let nsError = error as NSError
        let isCancellation = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        let isTermination = nsError.domain == "WKErrorDomain" && nsError.code == 2
        guard !isCancellation, !isTermination else { return }
        if let failingURL, let parsed = ParsedURL(failingURL), !parsed.isHTTP {
            // A scheme hand-off (a bank app); the page stays.
            return
        }
        if navigator.isCallback(failingURL) { startStatusPollIfNeeded() }
        Log.warning("A 3-D Secure page failed to load (\(nsError.domain) \(nsError.code)): \(Log.redactedURL(failingURL))")
        failedURL = failingURL
        isShowingPageLoadError = true
        ui.showThreeDSPageLoadError()
    }

    func webContentProcessDidTerminate() {
        guard sheetState == .active else { return }
        Log.warning("The 3-D Secure web content process terminated.")
        isShowingPageLoadError = true
        ui.showThreeDSPageLoadError()
    }

    func retry() {
        guard sheetState == .active, isShowingPageLoadError else { return }
        isShowingPageLoadError = false
        ui.showThreeDSContent()
        if !hasCommittedPage, let initialSheetRequest {
            ui.loadThreeDS(initialSheetRequest)
        } else if let url = failedURL ?? lastCommittedURL {
            ui.loadThreeDS(URLRequest(url: url))
        } else if let initialSheetRequest {
            ui.loadThreeDS(initialSheetRequest)
        }
    }

    func requestClose() {
        guard sheetState == .active, !isConfirmingClose else { return }
        isConfirmingClose = true
        ui.confirmThreeDSClose { [weak self] confirmed in
            guard let self else { return }
            self.isConfirmingClose = false
            guard confirmed else { return }
            self.closeSheetWithSingleCheck(showingUI: true)
        }
    }

    func sheetWasDismissedExternally() {
        isSheetPresented = false
        Log.warning("The 3-D Secure sheet was dismissed by the app; checking the status once.")
        closeSheetWithSingleCheck(showingUI: false)
    }

    // MARK: - Helpers

    /// A native `application/x-www-form-urlencoded` POST; the SDK never builds HTML.
    static func formPost(_ url: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(fields).utf8)
        return request
    }

    /// The HTML form encoding: `*-._`, digits and letters as is, space as `+`, every other
    /// UTF-8 byte as `%XX`.
    static func formEncoded(_ fields: [(String, String)]) -> String {
        func encode(_ text: String) -> String {
            var output = ""
            for byte in text.utf8 {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "*"), UInt8(ascii: "-"),
                     UInt8(ascii: "."), UInt8(ascii: "_"):
                    output.unicodeScalars.append(Unicode.Scalar(byte))
                case UInt8(ascii: " "):
                    output += "+"
                default:
                    output += "%" + String(byte >> 4, radix: 16, uppercase: true) + String(byte & 0x0F, radix: 16, uppercase: true)
                }
            }
            return output
        }
        return fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }
}
