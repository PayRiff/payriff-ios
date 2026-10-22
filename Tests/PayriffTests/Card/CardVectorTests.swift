import CryptoKit
import Foundation
import Security
import Testing
@testable import Payriff

/// Every case of `spec/vectors/card_*.json` (CONTRACT §16).
@Suite("Card vectors")
struct CardVectorTests {
    @Test("Every card vector file decodes completely")
    func everyCardFileDecodes() throws {
        let validation = try #require(CardVectors.validation)
        let counts: [(String, String, Int)] = [
            ("card_validation", "number", validation.number.count),
            ("card_validation", "detectBrand", validation.detectBrand.count),
            ("card_validation", "cvv", validation.cvv.count),
            ("card_validation", "holder", validation.holder.count),
            ("card_validation", "visibleError", validation.visibleError.count),
            ("card_validation", "luhn", validation.luhn.count),
            ("card_validation", "brands", validation.brands.count),
            ("card_format", "number", try #require(CardVectors.format).number.count),
            ("card_format", "expiry", try #require(CardVectors.format).expiry.count),
            ("card_format", "cvv", try #require(CardVectors.format).cvv.count),
            ("card_format", "holder", try #require(CardVectors.format).holder.count),
            ("card_crypto", "aesGcm", try #require(CardVectors.crypto).aesGcm.count),
            ("card_next_action", "cases", CardVectors.nextAction.count),
            ("card_3ds_navigation", "cases", CardVectors.navigation.count),
            ("card_api", "order", try #require(CardVectors.api).order.count),
            ("card_api", "errors", try #require(CardVectors.api).errors.count),
            ("card_api", "status", try #require(CardVectors.api).status.count),
            ("card_api", "requests", try #require(CardVectors.api).requests.count),
            ("card_api", "keys", try #require(CardVectors.api).keys.count),
            ("card_api", "clientSecrets", try #require(CardVectors.api).clientSecrets.count),
        ]
        for (file, key, count) in counts {
            let raw = try Vectors.rawCount(file, key: key)
            #expect(count > 0 && count == raw, "\(file).json \(key)")
        }
        let expiryRaw = try #require(try JSONSerialization.jsonObject(with: Vectors.data("card_validation")) as? [String: Any])
        #expect(((expiryRaw["expiry"] as? [String: Any])?["cases"] as? [Any])?.count == validation.expiry.cases.count)
        #expect(CardVectors.strings.keys.sorted() == ["az", "en", "ru"])
    }

    // MARK: card_validation.json

    @Test("card_validation.json brands, maxPanDigits and maxHolderLength match the SDK's rules")
    func brandRules() throws {
        let vectors = try #require(CardVectors.validation)
        #expect(vectors.maxPanDigits == CardValidation.maxPanDigits)
        #expect(vectors.maxHolderLength == CardValidation.maxHolderLength)
        #expect(vectors.brands.count == CardValidation.brands.count)
        for (vector, rule) in zip(vectors.brands, CardValidation.brands) {
            #expect(vector.brand == rule.brand.rawValue)
            #expect(vector.ranges == rule.ranges.map { [$0.0, $0.1] })
            #expect(vector.lengths == rule.lengths)
        }
    }

    @Test("card_validation.json number", arguments: CardVectors.numberCases)
    func number(_ vector: CardValidationVectors.FieldCase) {
        let result = CardValidation.validateNumber(vector.input)
        #expect(result.valid == vector.valid)
        #expect(result.empty == vector.empty)
        #expect(result.errorCode == PayriffCardFieldError(vector: vector.errorCode))
        #expect(result.brand?.rawValue == vector.brand)
        #expect(result.value == vector.value)
    }

    @Test("card_validation.json detectBrand", arguments: CardVectors.detectBrandCases)
    func detectBrand(_ vector: CardValidationVectors.DetectBrandCase) {
        #expect(CardValidation.detectBrand(vector.digits)?.rawValue == vector.brand)
        #expect(CardValidation.maxPanLength(vector.digits) == vector.maxLength)
    }

    @Test("card_validation.json expiry (now = 2026-10)", arguments: CardVectors.expiryCases)
    func expiry(_ vector: CardValidationVectors.ExpiryCase) throws {
        let now = try #require(CardVectors.validation).expiry.now
        let result = CardValidation.validateExpiry(vector.input, year: now.year, month: now.month)
        #expect(result.valid == vector.valid)
        #expect(result.empty == vector.empty)
        #expect(result.errorCode == PayriffCardFieldError(vector: vector.errorCode))
        #expect(result.value?.expiryMonth == vector.value?.expiryMonth)
        #expect(result.value?.expiryYear == vector.value?.expiryYear)
    }

    @Test("card_validation.json cvv", arguments: CardVectors.cvvCases)
    func cvv(_ vector: CardValidationVectors.FieldCase) {
        let result = CardValidation.validateCvv(vector.input)
        #expect(result.valid == vector.valid)
        #expect(result.empty == vector.empty)
        #expect(result.errorCode == PayriffCardFieldError(vector: vector.errorCode))
        #expect(result.value == vector.value)
    }

    @Test("card_validation.json holder", arguments: CardVectors.holderCases)
    func holder(_ vector: CardValidationVectors.FieldCase) {
        let result = CardValidation.validateHolder(vector.input)
        #expect(result.valid == vector.valid)
        #expect(result.empty == vector.empty)
        #expect(result.errorCode == PayriffCardFieldError(vector: vector.errorCode))
        #expect(result.value == vector.value)
    }

    @Test("card_validation.json visibleError", arguments: CardVectors.visibleErrorCases)
    func visibleError(_ vector: CardValidationVectors.VisibleErrorCase) {
        let shown = CardValidation.visibleError(
            PayriffCardFieldError(vector: vector.errorCode),
            focused: vector.focused,
            touched: vector.touched,
            submitted: vector.submitted
        )
        #expect(shown == PayriffCardFieldError(vector: vector.expected))
    }

    @Test("card_validation.json luhn", arguments: CardVectors.luhnCases)
    func luhn(_ vector: CardValidationVectors.LuhnCase) {
        #expect(CardValidation.luhn(vector.digits) == vector.valid)
    }

    // MARK: card_format.json

    @Test("card_format.json number", arguments: CardVectors.format?.number ?? [])
    func formatNumber(_ vector: CardFormatVectors.Case) {
        #expect(CardFormatting.formatNumber(vector.input) == vector.expected)
    }

    @Test("card_format.json expiry", arguments: CardVectors.format?.expiry ?? [])
    func formatExpiry(_ vector: CardFormatVectors.ExpiryCase) {
        #expect(CardFormatting.formatExpiry(vector.input, inserting: vector.inserting) == vector.expected)
    }

    @Test("card_format.json cvv", arguments: CardVectors.format?.cvv ?? [])
    func formatCvv(_ vector: CardFormatVectors.Case) {
        #expect(CardFormatting.formatCvv(vector.input) == vector.expected)
    }

    @Test("card_format.json holder: upper case with the locale-independent mapping, typed or pasted", arguments: CardVectors.format?.holder ?? [])
    func formatHolder(_ vector: CardFormatVectors.Case) {
        #expect(CardFormatting.formatHolder(vector.input) == vector.expected)
        // The form shows, validates and sends the upper-cased name, typed one character at a time…
        var typed = CardFormModel(showsHolder: true, language: .en)
        for character in vector.input {
            let length = (typed.text(.holder) as NSString).length
            let edit = typed.edit(.holder, range: NSRange(location: length, length: 0), replacement: String(character))
            #expect(edit != nil, "the edit is not refused")
        }
        #expect(typed.text(.holder) == vector.expected)
        // …or applied by the system keyboard, AutoFill or paste (the form's path for the holder).
        var pasted = CardFormModel(showsHolder: true, language: .en)
        #expect(pasted.setText(.holder, vector.input) == vector.expected)
        #expect(pasted.text(.holder) == vector.expected)
    }

    // MARK: card_strings.json

    @Test("card_strings.json: labels, placeholders, the card-information title, the payment view's texts and every error text in az/en/ru, nothing more")
    func strings() throws {
        let messages = CardVectors.strings
        #expect(messages.keys.sorted() == ["az", "en", "ru"])
        for (code, table) in messages {
            let language = try #require(PayriffLanguage(rawValue: code.uppercased()))
            let strings = CardStrings(language: language)
            for field in PayriffCardField.allCases {
                let errors = try #require(table[field.rawValue], "\(code) \(field)")
                for (error, text) in errors {
                    let fieldError = try #require(PayriffCardFieldError(rawValue: error))
                    #expect(CardStrings.messages[language]?[field]?[fieldError] == text, "\(code) \(field) \(error)")
                    #expect(strings.message(field, fieldError) == text)
                }
                #expect(CardStrings.messages[language]?[field]?.count == errors.count, "\(code) \(field): no extra texts")
                #expect(strings.placeholder(field) == table["placeholder"]?[field.rawValue], "\(code) placeholder \(field)")
                #expect(strings.label(field) == table["label"]?[field.rawValue], "\(code) label \(field)")
                // An error without its own text falls back to the field's "invalid" text.
                for error in PayriffCardFieldError.allCases where errors[error.rawValue] == nil {
                    #expect(strings.message(field, error) == errors["invalid"], "\(code) \(field) \(error) fallback")
                }
            }
            #expect(table["placeholder"]?.count == PayriffCardField.allCases.count, "\(code): no extra placeholders")
            #expect(table["label"]?.count == PayriffCardField.allCases.count, "\(code): no extra labels")
            // The title of the grouped layout's card box (CONTRACT §16.4), the only group text.
            #expect(table["group"] == ["cardInformation": strings.cardInformation], "\(code) group")
            // The payment view's Pay title, secure line and footer (CONTRACT §16.14), exactly.
            let view = Dictionary(uniqueKeysWithValues: CardStrings.ViewText.allCases.map { ($0.rawValue, strings.view($0)) })
            #expect(table["view"] == view, "\(code) view")
            #expect(CardStrings.viewTexts[language]?.count == CardStrings.ViewText.allCases.count, "\(code): every view text")
            #expect(Set(table.keys) == Set(PayriffCardField.allCases.map(\.rawValue) + ["placeholder", "label", "group", "view"]))
        }
        #expect(Set(CardStrings.messages.keys) == [.az, .en, .ru])
        #expect(Set(CardStrings.placeholders.keys) == [.az, .en, .ru])
        #expect(Set(CardStrings.labels.keys) == [.az, .en, .ru])
        #expect(Set(CardStrings.cardInformationTitles.keys) == [.az, .en, .ru])
        #expect(Set(CardStrings.viewTexts.keys) == [.az, .en, .ru])
    }

    // MARK: card_crypto.json

    private static func bytes(_ base64: String) throws -> [UInt8] {
        [UInt8](try #require(Data(base64Encoded: base64)))
    }

    static func testPrivateKey() throws -> SecKey {
        let vectors = try #require(CardVectors.crypto)
        let pkcs1 = try #require(DER.rsaPrivateKey(fromPkcs8: try bytes(vectors.testPrivateKeyPkcs8)))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error)
        error?.release()
        return try #require(key)
    }

    static func decrypt(_ wrapped: Data) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        let plain = SecKeyCreateDecryptedData(try testPrivateKey(), .rsaEncryptionOAEPSHA256, wrapped as CFData, &error)
        error?.release()
        return [UInt8](try #require(plain as Data?))
    }

    @Test("card_crypto.json aesGcm: byte-exact card JSON and AES-256-GCM output", arguments: CardVectors.aesCases)
    func aesGcm(_ vector: CardCryptoVectors.AESCase) throws {
        let vectors = try #require(CardVectors.crypto)
        let card = CardDetails(
            pan: vector.card.pan,
            cardHolder: vector.card.cardHolder,
            expiryYear: vector.card.expiryYear,
            expiryMonth: vector.card.expiryMonth,
            cvv: vector.card.cvv
        )
        let json = CardCrypto.cardJSON(card)
        #expect(json == Array(vector.cardJson.utf8))
        let sealed = try CardCrypto.sealAESGCM(json, key: try Self.bytes(vectors.aesKey), iv: try Self.bytes(vectors.iv))
        #expect(sealed.base64EncodedString() == vector.encryptedMessage)

        // The full pipeline with the vector's key material and the test key pair.
        let aesKey = try Self.bytes(vectors.aesKey)
        let iv = try Self.bytes(vectors.iv)
        let publicKey = try CardCrypto.rsaPublicKey(spki: Data(try Self.bytes(vectors.testPublicKeySpki)))
        let encrypted = try CardCrypto.encrypt(card, publicKey: publicKey) { count in count == 32 ? aesKey : iv }
        #expect(encrypted.encryptedMessage == vector.encryptedMessage)
        let unwrapped = try Self.decrypt(try #require(Data(base64Encoded: encrypted.wrappedKey)))
        #expect(unwrapped == (try Self.bytes(vectors.keyIv)))
    }

    @Test("card_crypto.json: the vector's RSA-OAEP wrap and the SDK's own wrap both decrypt to aesKey ‖ iv")
    func rsaWrap() throws {
        let vectors = try #require(CardVectors.crypto)
        let keyIv = try Self.bytes(vectors.keyIv)
        #expect(keyIv == (try Self.bytes(vectors.aesKey)) + (try Self.bytes(vectors.iv)))
        #expect(try Self.decrypt(try #require(Data(base64Encoded: vectors.rsaWrappedKeyIv))) == keyIv)

        let publicKey = try CardCrypto.rsaPublicKey(spki: Data(try Self.bytes(vectors.testPublicKeySpki)))
        let wrapped = try CardCrypto.wrapKey(keyIv, with: publicKey)
        #expect(wrapped.count == 256)
        #expect(try Self.decrypt(wrapped) == keyIv)
        // OAEP is randomized: two wraps differ but both decrypt.
        let again = try CardCrypto.wrapKey(keyIv, with: publicKey)
        #expect(again != wrapped)
        #expect(try Self.decrypt(again) == keyIv)
    }

    @Test("card_crypto.json: the pinned Payriff key equals the vector and its SHA-256 pin")
    func pinnedKey() throws {
        let vectors = try #require(CardVectors.crypto)
        #expect(CardCrypto.payriffPublicKeySpki == vectors.payriffPublicKeySpki)
        #expect(CardCrypto.payriffPublicKeySHA256 == vectors.payriffPublicKeySha256)
        let der = try #require(Data(base64Encoded: CardCrypto.payriffPublicKeySpki))
        #expect(CardCrypto.sha256Hex(der) == vectors.payriffPublicKeySha256)
        let key = try CardCrypto.pinnedPublicKey()
        #expect(SecKeyGetBlockSize(key) == 256)
        #expect(SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionOAEPSHA256))
    }

    @Test("Real encryption: fresh key material per attempt, 44-byte wrapped plaintext, no IV prefix")
    func freshKeyMaterial() throws {
        let vectors = try #require(CardVectors.crypto)
        let publicKey = try CardCrypto.rsaPublicKey(spki: Data(try Self.bytes(vectors.testPublicKeySpki)))
        let card = CardDetails(pan: "4111111111111111", cardHolder: "TEST CARD", expiryYear: "2030", expiryMonth: "12", cvv: "123")
        let first = try CardCrypto.encrypt(card, publicKey: publicKey)
        let second = try CardCrypto.encrypt(card, publicKey: publicKey)
        #expect(first.encryptedMessage != second.encryptedMessage)
        let keyIv = try Self.decrypt(try #require(Data(base64Encoded: first.wrappedKey)))
        #expect(keyIv.count == 44)
        // ciphertext ‖ tag: the JSON length plus 16 bytes, without a 12-byte IV prefix.
        let sealed = try #require(Data(base64Encoded: first.encryptedMessage))
        #expect(sealed.count == CardCrypto.cardJSON(card).count + 16)
        // Decrypting with the unwrapped key and IV gives the exact JSON back.
        let box = try AESGCMHelper.open(sealed, key: Array(keyIv.prefix(32)), iv: Array(keyIv.suffix(12)))
        #expect(box == CardCrypto.cardJSON(card))
        // Nothing sensitive in the textual representations.
        for text in ["\(card)", String(reflecting: card), "\(first)", String(reflecting: first)] {
            #expect(!text.contains("4111") && !text.contains("123") && !text.contains(first.wrappedKey))
        }
    }

    @Test("zero() overwrites the buffer; malformed keys are refused")
    func zeroingAndBadKeys() throws {
        var buffer: [UInt8] = [1, 2, 3, 4]
        CardCrypto.zero(&buffer)
        #expect(buffer == [0, 0, 0, 0])
        var empty: [UInt8] = []
        CardCrypto.zero(&empty)
        #expect(throws: CardCryptoError.invalidPublicKey) { try CardCrypto.rsaPublicKey(spki: Data([0x30, 0x03, 0x02, 0x01, 0x00])) }
        #expect(DER.rsaPublicKey(fromSpki: Array("not der".utf8)) == nil)
    }

    // MARK: card_next_action.json

    @Test("card_next_action.json", arguments: CardVectors.nextAction)
    func nextAction(_ vector: CardNextActionVector) throws {
        let payload = try #require(vector.payload.foundationObject as? [String: Any])
        let action = CardNextAction(payload: payload)
        let expected = try #require(vector.expected.objectValue)
        switch (expected["type"]?.stringValue, action) {
        case ("challenge", .challenge(let url, let form)):
            #expect(url.absoluteString == expected["url"]?.stringValue)
            var pairs: [[String]] = []
            if case .array(let list)? = expected["form"] {
                for pair in list {
                    if case .array(let items) = pair { pairs.append(items.compactMap(\.stringValue)) }
                }
            }
            #expect(form.map { [$0.key, $0.value] } == pairs)
        case ("method", .method(let methodURL, let methodData, let serverURL)):
            #expect(methodURL?.absoluteString == expected["methodUrl"]?.stringValue)
            #expect(methodData == expected["methodData"]?.stringValue)
            #expect(serverURL?.absoluteString == expected["methodUrlServer"]?.stringValue)
            #expect((expected["methodUrl"]?.isNull ?? true) == (methodURL == nil))
            #expect((expected["methodData"]?.isNull ?? true) == (methodData == nil))
        case ("wait", .wait), ("checkStatus", .checkStatus), ("invalid", .invalid):
            break
        case ("redirect", .redirect(let url)):
            #expect(url.absoluteString == expected["url"]?.stringValue)
        default:
            Issue.record("expected \(expected["type"]?.stringValue ?? "?"), got \(action)")
        }
        // The textual form never contains the bank values.
        #expect(!"\(action)".contains("abc") && !"\(action)".contains("eyJ0aHJl"))
    }

    // MARK: card_3ds_navigation.json

    @Test("card_3ds_navigation.json", arguments: CardVectors.navigation)
    func threeDSNavigation(_ vector: ThreeDSNavigationVector) throws {
        let host = try #require(URLComponents(string: vector.apiBase)?.host)
        var navigator = ThreeDSNavigator(apiHost: host)
        for (index, step) in vector.steps.enumerated() {
            let action = navigator.decide(URL(string: step.url), isMainFrame: step.isMainFrame)
            #expect(action.rawValue == step.expected, "step \(index): \(step.url)")
        }
    }

    @Test("The API host of each environment; sandbox is the one provisional constant")
    func hosts() {
        #expect(ClientAPIHost.baseURL(for: .production) == "https://api.payriff.com")
        #expect(ClientAPIHost.baseURL(for: .sandbox) == "https://sb-api.payriff.com")
        #expect(ClientAPIHost.host(for: .production) == "api.payriff.com")
        #expect(ClientAPIHost.host(for: .sandbox) == "sb-api.payriff.com")
    }

    // MARK: card_api.json

    static let appId = "com.payriff.example.ios"

    static func client(_ transport: FakeTransport, clock: FakeClock = FakeClock()) -> ClientAPIClient {
        ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_TEST", clientSecret: "pr_cs_TEST"),
            appId: appId,
            transport: transport,
            clock: clock
        )
    }

    @Test("card_api.json order", arguments: CardVectors.orderCases)
    func order(_ vector: CardAPIVectors.ResponseCase) async throws {
        let client = Self.client(FakeTransport(status: vector.httpStatus, body: vector.body))
        let expect = try #require(vector.expect.objectValue)
        let order = try await client.order("o1").get()
        #expect(expect["ok"]?.boolValue == true)
        #expect(order.orderId == expect["orderId"]?.stringValue)
        #expect(order.status.rawValue == expect["status"]?.stringValue)
        #expect(order.isPayableByCard == expect["payable"]?.boolValue)
        if let amount = expect["amount"]?.stringValue {
            #expect(order.amount == Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")))
        }
        if let currency = expect["currency"]?.stringValue { #expect(order.currency == currency) }
        if case .array(let methods)? = expect["paymentMethods"] {
            #expect(order.paymentMethods == methods.compactMap(\.stringValue))
        }
    }

    @Test("card_api.json errors: code, fatal, retries, Payriff code and message", arguments: CardVectors.errorCases)
    func errors(_ vector: CardAPIVectors.ResponseCase) async throws {
        let expect = try #require(vector.expect.objectValue)
        for call in ["GET", "POST"] {
            let transport = FakeTransport(status: vector.httpStatus, body: vector.body)
            let clock = FakeClock()
            let client = Self.client(transport, clock: clock)
            let error: PayriffError
            if call == "GET" {
                error = try #require(await client.order("o1").failureValue)
            } else {
                error = try #require(await client.pay("o1", card: EncryptedCard(encryptedMessage: "QUJD", wrappedKey: "S0VZ"), idempotencyKey: "k1").failureValue)
            }
            #expect(error.code.rawValue == expect["code"]?.stringValue, "\(call)")
            #expect(error.isFatal == expect["fatal"]?.boolValue, "\(call)")
            if let payriffCode = expect["payriffCode"] {
                #expect(error.payriffCode == payriffCode.stringValue, "\(call)")
            }
            if let message = expect["message"]?.stringValue {
                #expect(error.message == message, "\(call)")
            }
            #expect(error.isRetryable == (error.code == .paymentFailed), "\(call): only PAYMENT_FAILED lets the customer try again")
            // "retry": the SDK retries 429 three times after 1, 2 and 4 s, with the identical request.
            if expect["retry"]?.boolValue == true {
                #expect(transport.requests.count == 4, "\(call)")
                #expect(clock.sleeps == [1, 2, 4], "\(call)")
                let first = try #require(transport.requests.first)
                for request in transport.requests {
                    #expect(request.httpBody == first.httpBody)
                    #expect(request.value(forHTTPHeaderField: "X-Idempotency-Key") == first.value(forHTTPHeaderField: "X-Idempotency-Key"))
                }
            } else {
                #expect(transport.requests.count == 1, "\(call)")
                #expect(clock.sleeps.isEmpty, "\(call)")
            }
        }
    }

    @Test("card_api.json status: final set and result group", arguments: CardVectors.statusCases)
    func status(_ vector: CardAPIVectors.ResponseCase) async throws {
        let client = Self.client(FakeTransport(status: vector.httpStatus, body: vector.body))
        let expect = try #require(vector.expect.objectValue)
        let snapshot = try await client.status("o1").get()
        #expect(snapshot.rawStatus == expect["status"]?.stringValue)
        #expect(snapshot.status.isFinal == expect["final"]?.boolValue)
        let group: String?
        switch snapshot.status.outcome {
        case .success: group = "success"
        case .declined: group = "declined"
        case .cancelled: group = "cancelled"
        case .unexpectedFinal: group = "pending"
        case .nonFinal: group = nil
        }
        #expect(group == expect["result"]?.stringValue)
        if snapshot.status == .approved {
            #expect(snapshot.amount == Decimal(string: "10.5", locale: Locale(identifier: "en_US_POSIX")))
            #expect(snapshot.currency == "AZN")
        }
    }

    @Test("card_api.json requests: method, path, headers, never Origin or Authorization", arguments: CardVectors.requestCases)
    func requests(_ vector: CardAPIVectors.RequestCase) async throws {
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","message":"OK","payload":{"orderId":"o1","status":"CREATED","nextAction":"CHECK_STATUS"}}"#)
        let client = Self.client(transport)
        let card = EncryptedCard(encryptedMessage: "QUJD+/w=", wrappedKey: "S0VZ")
        switch vector.name {
        case "GET order": _ = await client.order("o1")
        case "POST pay": _ = await client.pay("o1", card: card, idempotencyKey: "0f8fad5b-d9cb-469f-a165-70867728950e")
        case "GET three-ds": _ = await client.threeDS("o1")
        case "GET status": _ = await client.status("o1")
        default: _ = await client.order(try #require(vector.orderId))
        }
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.httpMethod == vector.method)
        let url = try #require(request.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == vector.path)
        #expect(url.host == "api.payriff.com" && url.scheme == "https")
        for (name, value) in vector.headers ?? [:] {
            #expect(request.value(forHTTPHeaderField: name) == value, "\(name)")
        }
        let sent = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        for name in vector.absentHeaders ?? ["Origin", "X-Parent-Origin", "Authorization"] {
            #expect(!sent.contains(name.lowercased()), "\(name) must not be sent")
        }
        for name in vector.requiredHeaders ?? [] {
            #expect(request.value(forHTTPHeaderField: name)?.isEmpty == false, "\(name)")
        }
        if vector.body != nil {
            let body = try #require(request.httpBody)
            #expect(String(decoding: body, as: UTF8.self) == #"{"method":"CARD","encryptedMessage":"QUJD+/w="}"#)
            #expect(request.value(forHTTPHeaderField: "x-secret-key") == "S0VZ")
            #expect(request.value(forHTTPHeaderField: "X-Idempotency-Key") == "0f8fad5b-d9cb-469f-a165-70867728950e")
            #expect(request.timeoutInterval == 30)
        } else {
            #expect(request.httpBody == nil)
            #expect(request.timeoutInterval == 15)
            #expect(request.value(forHTTPHeaderField: "x-secret-key") == nil)
        }
    }

    @Test("X-Client-App-Id is omitted when the app id is unknown or not a reverse-DNS name")
    func appIdHeader() async throws {
        #expect(ClientAppID.validated("com.payriff.example.ios") == "com.payriff.example.ios")
        #expect(ClientAppID.validated("com.example.shop-1_a") == "com.example.shop-1_a")
        for invalid in [nil, "", "shop", "1com.example", "com..example", "com.example.", "com.exa mple", "com.examplé", String(repeating: "a.", count: 128) + "b"] as [String?] {
            #expect(ClientAppID.validated(invalid) == nil, "\(invalid ?? "nil")")
        }
        let transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{}}"#)
        let client = ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: "pr_pk_live_TEST", clientSecret: "pr_cs_TEST"),
            appId: nil,
            transport: transport,
            clock: FakeClock()
        )
        _ = await client.status("o1")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Client-App-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Public-Key") == "pr_pk_live_TEST")
    }

    @Test("card_api.json keys: only pr_pk_live_ publishable keys", arguments: CardVectors.keyCases)
    func keys(_ vector: CardAPIVectors.KeyCase) {
        let result = ClientCredentials.publishableKey(vector.value)
        #expect(((try? result.get()) != nil) == vector.valid)
        if case .failure(let error) = result {
            #expect(error.code == .invalidConfig)
            #expect(vector.value.isEmpty || !error.message.contains(vector.value))
        }
    }

    @Test("card_api.json clientSecrets: pr_cs_ secrets, sent trimmed and otherwise as is", arguments: CardVectors.clientSecretCases)
    func clientSecrets(_ vector: CardAPIVectors.KeyCase) async throws {
        let result = ClientCredentials.clientSecret(vector.value)
        #expect(((try? result.get()) != nil) == vector.valid)
        if case .failure(let error) = result {
            #expect(error.code == .invalidOrder)
            #expect(vector.value.isEmpty || !error.message.contains(vector.value))
        }
        if let sent = vector.sent {
            #expect(try result.get() == sent)
        }
    }

    @Test("Order ids are trimmed and encoded as one path segment; a blank id sends nothing")
    func orderPaths() async throws {
        #expect(try ClientAPIClient.path(" o1 ", suffix: "/pay").get() == "/api/v3/client/orders/o1/pay")
        #expect(try ClientAPIClient.path("../x", suffix: "").get() == "/api/v3/client/orders/%2E%2E%2Fx")
        let transport = FakeTransport(status: 200, body: "{}")
        let result = await Self.client(transport).status("  ")
        #expect(result.failureValue?.code == .invalidOrder)
        #expect(transport.requests.isEmpty)
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// Opens AES-GCM output (ciphertext ‖ tag) for tests.
enum AESGCMHelper {
    static func open(_ sealed: Data, key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: sealed.dropLast(16),
            tag: sealed.suffix(16)
        )
        return [UInt8](try AES.GCM.open(box, using: SymmetricKey(data: key)))
    }
}
