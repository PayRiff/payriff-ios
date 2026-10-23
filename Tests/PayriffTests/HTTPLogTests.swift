import Foundation
import Testing
@testable import Payriff

/// CONTRACT §11: the JSON request and response log never shows a secret. Mirrors the Flutter
/// SDK's `http_log_test.dart`; body keys are sorted here (see ``HTTPLog``).
@Suite("HTTP details log")
struct HTTPLogTests {
    // MARK: Headers

    @Test("Headers: secrets show only their length, the publishable key its prefix; sorted by name")
    func headers() {
        let shown = HTTPLog.redactedHeaders([
            "Authorization": "0123456789ABCDEF0123456789ABCDEF",
            "X-Client-Secret": "pr_cs_v1_secret",
            "x-secret-key": "WRAPPED+/=",
            "X-Public-Key": "pr_pk_live_TestPublishableKey00000000000000000000",
            "X-Client-App-Id": "com.payriff.example.ios",
            "Content-Type": "application/json",
        ])
        #expect(shown == .object([
            ("Authorization", .string("***(32)")),
            ("Content-Type", .string("application/json")),
            ("X-Client-App-Id", .string("com.payriff.example.ios")),
            ("X-Client-Secret", .string("***(15)")),
            ("X-Public-Key", .string("pr_pk_live_***(49)")),
            ("x-secret-key", .string("***(10)")),
        ]))
        // Names match ignoring case; a key without the live prefix shows only its length.
        #expect(HTTPLog.redactedHeaders(["AUTHORIZATION": "k", "x-public-key": "pk_test_123", "x-client-secret": ""]) == .object([
            ("AUTHORIZATION", .string("***(1)")),
            ("x-client-secret", .string("***(0)")),
            ("x-public-key", .string("***(11)")),
        ]))
        #expect(HTTPLog.redactedHeaders([:]) == .object([]))
    }

    // MARK: Bodies

    @Test("Body: secret fields at any depth are redacted and card numbers masked")
    func secretFieldsAtAnyDepth() {
        let shown = HTTPLog.redactedBody(Data(#"{"code":"00000","payload":{"orderId":"o1","clientSecret":"pr_cs_x","items":[{"encryptedMessage":"ENC"}],"pan":"4111111111111111","maskedPan":"411111******1111","creq":"CREQ","amount":1.5}}"#.utf8))
        #expect(shown.serialized == #"{"code":"00000","payload":{"amount":1.5,"clientSecret":"***(7)","creq":"***(4)","items":[{"encryptedMessage":"***(3)"}],"maskedPan":"411111******1111","orderId":"o1","pan":"****1111"}}"#)
    }

    @Test("Body: every listed secret field, ignoring case, whatever its value", arguments: [
        ("appKey", #""0123456789ABCDEF0123456789ABCDEF""#, JSONValue.string("***(32)")),
        ("app_key", #""k""#, .string("***(1)")),
        ("CardHolder", #""ƏLİ VƏLİYEV""#, .string("***(11)")),
        ("card_holder", #""TEST CARD""#, .string("***(9)")),
        ("clientSecret", #""pr_cs_abc""#, .string("***(9)")),
        ("client_secret", #""pr_cs_abcd""#, .string("***(10)")),
        ("CREQ", #""Y3JlcQ""#, .string("***(6)")),
        ("cvc", #""456""#, .string("***(3)")),
        ("cvv", #""123""#, .string("***(3)")),
        ("encryptedMessage", #""RU5D""#, .string("***(4)")),
        ("expiryMonth", "12", .string("***(2)")),
        ("EXPIRYYEAR", #""2030""#, .string("***(4)")),
        ("password", #""hunter2""#, .string("***(7)")),
        ("SECRETKEY", #""sk""#, .string("***(2)")),
        ("secret_key", #""sk_x""#, .string("***(4)")),
        ("threeDSMethodData", #""eyJ0""#, .string("***(4)")),
        ("ThreeDSSessionData", #""c2Vz""#, .string("***(4)")),
        // Lengths count UTF-16 code units, as in the other SDKs.
        ("password", #""👍🏽""#, .string("***(4)")),
        ("cvv", "true", .string("***(4)")),
        ("cvv", "null", .null),
        // The elements of an array take the array's name.
        ("cvv", #"["123","4567"]"#, .array([.string("***(3)"), .string("***(4)")])),
    ])
    func secretField(name: String, json: String, expected: JSONValue) {
        #expect(HTTPLog.redactedBody(Data(#"{"\#(name)":\#(json)}"#.utf8)) == .object([(name, expected)]))
    }

    @Test("Body: card numbers show only their last four digits, unless already masked", arguments: [
        ("pan", #""4111111111111111""#, JSONValue.string("****1111")),
        ("cardNumber", #""4111 1111 1111 1234""#, .string("****1234")),
        ("card_number", "5555555555554444", .string("****4444")),
        ("PAN", #""411111******1111""#, .string("411111******1111")),
        ("pan", #""1234""#, .string("***(4)")),
        ("pan", "null", .null),
        ("maskedPan", #""411111******1111""#, .string("411111******1111")),
    ])
    func cardNumber(name: String, json: String, expected: JSONValue) {
        #expect(HTTPLog.redactedBody(Data(#"{"\#(name)":\#(json)}"#.utf8)) == .object([(name, expected)]))
    }

    @Test("Body: the values of the bank form fields (clientRequest) never show")
    func formFields() {
        let shown = HTTPLog.redactedBody(Data(#"{"clientRequest":[{"key":"creq","value":"CREQ-VALUE-42"},{"key":"threeDSSessionData","value":null},{"key":"other","value":"X-VALUE"},{"key":"threeDSMethodUrl","value":"https://acs.bank.example/method?id=1"}]}"#.utf8)).serialized
        #expect(!shown.contains("CREQ-VALUE-42"))
        #expect(!shown.contains("X-VALUE"))
        #expect(!shown.contains("acs.bank.example"))
        #expect(shown.contains(#"{"key":"creq","value":"***(13)"}"#))
        #expect(shown.contains(#"{"key":"threeDSSessionData","value":null}"#))
        #expect(shown.contains(#"{"key":"other","value":"***(7)"}"#))
        // Only an object with a string "key" and a "value" is a form field.
        #expect(HTTPLog.redactedBody(Data(#"{"key":1,"value":"shown"}"#.utf8)).serialized == #"{"key":1,"value":"shown"}"#)
    }

    @Test("Body: http(s) URLs lose their user info, query and fragment, and show a path only on Payriff's API hosts")
    func urlsInBodies() {
        #expect(HTTPLog.redactedBody(Data(#"{"paymentUrl":"https://pay.payriff.com/r/o1?type=direct#x"}"#.utf8)) == .object([
            ("paymentUrl", .string("https://pay.payriff.com")),
        ]))
        #expect(HTTPLog.redactedBody(Data(#"{"a":"HTTP://Bank.example/acs#frag","b":"see https://x.example/?q=1","c":["https://cb.example/r?status=ok"]}"#.utf8)) == .object([
            ("a", .string("http://bank.example")),
            ("b", .string("see https://x.example/?q=1")),
            ("c", .array([.string("https://cb.example")])),
        ]))
        // A bank's 3-D Secure page shows as its origin; Payriff's own URLs keep the path, with
        // long segments shortened.
        #expect(HTTPLog.redactedBody(Data(#"{"payload":{"accessUrl":"https://user:pass@acs.bank.example:8443/challenge/SESSION-TOKEN-0123456789?id=1","callbackUrl":"https://api.payriff.com/api/v3/gateway/kapital/callback/7c9e6679-7425-40de-944b-e07fc1f90ae7?x=1#y","redirectUrl":"https://user:pass@acs.bank.example/acs?id=1","steps":[{"methodUrl":"HTTPS://ACS.BANK.EXAMPLE/method/abc"}]}}"#.utf8)) == .object([
            ("payload", .object([
                ("accessUrl", .string("https://acs.bank.example:8443")),
                ("callbackUrl", .string("https://api.payriff.com/api/v3/gateway/kapital/callback/7c9e…0ae7")),
                ("redirectUrl", .string("https://acs.bank.example")),
                ("steps", .array([.object([("methodUrl", .string("https://acs.bank.example"))])])),
            ])),
        ]))
    }

    @Test("The logged url: no user info, query or fragment, long path segments shortened, other hosts as their origin")
    func loggedURL() throws {
        func url(_ raw: String) throws -> String? {
            let entry = HTTPLog.describeRequest(method: "GET", url: raw, headers: [:], body: nil)
            return try #require(try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any])["url"] as? String
        }
        #expect(try url("https://user:pass@api.payriff.com/api/v3/client/orders/7c9e6679-7425-40de-944b-e07fc1f90ae7/pay?x=1#y") == "https://api.payriff.com/api/v3/client/orders/7c9e…0ae7/pay")
        #expect(try url("HTTPS://SB-API.payriff.com:443/api/v3/client/orders/o1/three-ds") == "https://sb-api.payriff.com:443/api/v3/client/orders/o1/three-ds")
        #expect(try url("https://acs.bank.example/challenge?id=1") == "https://acs.bank.example")
        #expect(try url("") == "")
    }

    @Test("Body: empty, non-JSON, very long and very deep bodies are described, not logged")
    func describedBodies() {
        #expect(HTTPLog.redactedBody(nil) == .null)
        #expect(HTTPLog.redactedBody(Data()) == .null)
        #expect(HTTPLog.redactedBody(Data("<html>secret</html>".utf8)) == .string("(19 bytes, not JSON)"))
        #expect(HTTPLog.redactedBody(Data("  ".utf8)) == .string("(2 bytes, not JSON)"))
        #expect(HTTPLog.redactedBody(Data("null".utf8)) == .null)

        let limit = HTTPLog.maximumBodyLength
        #expect(limit == 16_000)
        let tooLong = "\"" + String(repeating: "a", count: limit) + "\""
        #expect(HTTPLog.redactedBody(Data(tooLong.utf8)) == .string("(\(limit + 2) characters of JSON, too long to log)"))
        let fits = String(repeating: "a", count: limit - 2)
        #expect(HTTPLog.redactedBody(Data("\"\(fits)\"".utf8)) == .string(fits))
        // The limit applies to the redacted JSON.
        let longSecret = String(repeating: "A", count: 20_000)
        #expect(HTTPLog.redactedBody(Data(#"{"encryptedMessage":"\#(longSecret)"}"#.utf8)) == .object([
            ("encryptedMessage", .string("***(20000)")),
        ]))

        // iOS safeguard: redacting recurses per level, so very deep nesting is not logged.
        let depth = HTTPLog.maximumBodyDepth
        let deepest = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(HTTPLog.redactedBody(Data(deepest.utf8)).serialized == deepest)
        let tooDeep = String(repeating: #"{"a":"#, count: depth + 1) + "1" + String(repeating: "}", count: depth + 1)
        #expect(HTTPLog.redactedBody(Data(tooDeep.utf8)) == .string("(\(tooDeep.utf8.count) bytes of JSON, nested too deeply to log)"))
    }

    @Test("Body: numbers and booleans keep their JSON type")
    func scalars() {
        #expect(HTTPLog.redactedBody(Data(#"{"a":1,"b":10.50,"c":true,"d":false,"e":884213,"f":-0.5,"g":1e2}"#.utf8)).serialized
            == #"{"a":1,"b":10.5,"c":true,"d":false,"e":884213,"f":-0.5,"g":100.0}"#)
    }

    // MARK: Entries

    @Test("Requests and responses are pretty-printed JSON objects")
    func describe() throws {
        let request = HTTPLog.describeRequest(
            method: "POST",
            url: "https://api.payriff.com/api/v3/client/orders/o1/pay?x=1",
            headers: ["X-Client-Secret": "pr_cs_0123456789"],
            body: Data(#"{"amount":0.1}"#.utf8)
        )
        #expect(request == """
        {
          "method": "POST",
          "url": "https://api.payriff.com/api/v3/client/orders/o1/pay",
          "headers": {
            "X-Client-Secret": "***(16)"
          },
          "body": {
            "amount": 0.1
          }
        }
        """)
        #expect(request.contains("\n  \"method\": \"POST\""))

        let response = HTTPLog.describeResponse(
            status: 200,
            method: "GET",
            url: "https://api.payriff.com/api/v3/client/orders/o1",
            headers: ["content-type": "application/json"],
            body: Data(#"{"payload":{"clientSecret":"pr_cs_abc"}}"#.utf8)
        )
        #expect(response == """
        {
          "status": 200,
          "method": "GET",
          "url": "https://api.payriff.com/api/v3/client/orders/o1",
          "headers": {
            "content-type": "application/json"
          },
          "body": {
            "payload": {
              "clientSecret": "***(9)"
            }
          }
        }
        """)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        #expect(parsed["status"] as? Int == 200)

        // A GET without a body and a response without headers.
        #expect(HTTPLog.describeResponse(status: 404, method: "GET", url: "https://api.payriff.com/a", headers: [:], body: Data()) == """
        {
          "status": 404,
          "method": "GET",
          "url": "https://api.payriff.com/a",
          "headers": {},
          "body": null
        }
        """)
    }

    @Test("The entries name the request's method, URL, headers and body, and the response's status and headers")
    func entries() throws {
        var request = URLRequest(url: try #require(URL(string: "https://api.payriff.com/api/v3/client/orders/o1/pay?debug=1")))
        request.httpMethod = "POST"
        request.setValue("pr_cs_SECRET", forHTTPHeaderField: "X-Client-Secret")
        request.httpBody = Data(#"{"method":"CARD","encryptedMessage":"CIPHERTEXT"}"#.utf8)
        let requestEntry = HTTPLog.requestEntry(request)
        #expect(requestEntry.hasPrefix("HTTP request\n{\n  \"method\": \"POST\",\n  \"url\": \"https://api.payriff.com/api/v3/client/orders/o1/pay\",\n"))
        #expect(requestEntry.contains(#""X-Client-Secret": "***(12)""#))
        #expect(requestEntry.contains(#""encryptedMessage": "***(10)""#))
        #expect(!requestEntry.contains("SECRET") && !requestEntry.contains("CIPHERTEXT") && !requestEntry.contains("debug=1"))

        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "1", "Content-Type": "application/json"]
        ))
        let responseEntry = HTTPLog.responseEntry(response, body: Data(#"{"code":"01000"}"#.utf8), of: request)
        #expect(responseEntry == """
        HTTP response
        {
          "status": 429,
          "method": "POST",
          "url": "https://api.payriff.com/api/v3/client/orders/o1/pay",
          "headers": {
            "Content-Type": "application/json",
            "Retry-After": "1"
          },
          "body": {
            "code": "01000"
          }
        }
        """)
    }

    @Test("prettyPrinted: 2-space indentation, \"name\": value, {} and [] when empty")
    func prettyPrinted() {
        let value = JSONValue.object([
            ("a", .array([])),
            ("b", .object([])),
            ("c", .array([.number("1"), .array([.string("x")]), .null, .bool(true)])),
            ("d", .string("q\"\n")),
        ])
        #expect(value.prettyPrinted == #"""
        {
          "a": [],
          "b": {},
          "c": [
            1,
            [
              "x"
            ],
            null,
            true
          ],
          "d": "q\"\n"
        }
        """#)
        #expect(JSONValue.string("x").prettyPrinted == #""x""#)
        #expect(JSONValue.object([]).prettyPrinted == "{}")
    }
}

// MARK: - Through the API clients and the public API (process-wide logger state)

extension GlobalStateTests {
    /// The entries that are request or response details.
    static func httpDetails(_ entries: [PayriffLogEntry]) -> [PayriffLogEntry] {
        entries.filter { $0.message.hasPrefix("HTTP request\n") || $0.message.hasPrefix("HTTP response\n") }
    }

    /// The JSON object of a details entry.
    static func detailsJSON(_ entry: PayriffLogEntry) throws -> [String: Any] {
        let json = try #require(entry.message.split(separator: "\n", maxSplits: 1).last)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("The Client API logs every attempt as redacted JSON: keys, x-secret-key, the encrypted card and 3DS form values never show")
    func clientAPIHTTPDetails() async throws {
        let recorder = LogRecorder()
        recorder.install()
        PayriffLogger.isEnabled = true
        defer {
            PayriffLogger.isEnabled = false
            PayriffLogger.onLog = nil
        }
        let api = RoutedClientAPI([
            .order: [CardBodies.order()],
            .pay: [CardBodies.error(429, code: "01000"), .network, CardBodies.challenge],
            .threeDS: [CardBodies.challenge],
            .status: [CardBodies.status("APPROVED")],
        ])
        let client = ClientAPIClient(
            baseURL: "https://api.payriff.com",
            credentials: ClientCredentials(publishableKey: Self.publishableKey, clientSecret: Self.clientSecret),
            appId: "com.payriff.example.ios",
            transport: api.transport,
            clock: FakeClock(),
            logsHTTPDetails: true
        )
        _ = try await client.order("o1").get()
        _ = try await client.pay("o1", card: CardFlowHarness.encrypted, idempotencyKey: CardFlowHarness.idempotencyKey).get()
        _ = try await client.threeDS("o1").get()
        _ = try await client.status("o1").get()

        let details = Self.httpDetails(recorder.all).filter { $0.message.contains("https://api.payriff.com/api/v3/client/orders/o1") }
        #expect(details.allSatisfy { $0.level == .debug })
        // One request per attempt; no response for the attempt that got none.
        #expect(details.map { String($0.message.prefix { $0 != "\n" }) } == [
            "HTTP request", "HTTP response", // order
            "HTTP request", "HTTP response", // pay: 429
            "HTTP request", // pay: no response
            "HTTP request", "HTTP response", // pay
            "HTTP request", "HTTP response", // three-ds
            "HTTP request", "HTTP response", // status
        ])

        let order = try Self.detailsJSON(details[0])
        #expect(order["headers"] as? [String: String] == [
            "Accept": "application/json",
            "X-Client-App-Id": "com.payriff.example.ios",
            "X-Client-Secret": "***(\(Self.clientSecret.count))",
            "X-Public-Key": "pr_pk_live_***(\(Self.publishableKey.count))",
        ])
        #expect(order["body"] is NSNull)

        #expect(details[5].message == """
        HTTP request
        {
          "method": "POST",
          "url": "https://api.payriff.com/api/v3/client/orders/o1/pay",
          "headers": {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Client-App-Id": "com.payriff.example.ios",
            "X-Client-Secret": "***(21)",
            "X-Idempotency-Key": "0f8fad5b-d9cb-469f-a165-70867728950e",
            "X-Public-Key": "pr_pk_live_***(24)",
            "x-secret-key": "***(16)"
          },
          "body": {
            "encryptedMessage": "***(24)",
            "method": "CARD"
          }
        }
        """)
        #expect(details[2].message == details[5].message, "a retry logs the same request")
        #expect(try Self.detailsJSON(details[3])["status"] as? Int == 429)

        #expect(details[8].message == """
        HTTP response
        {
          "status": 200,
          "method": "GET",
          "url": "https://api.payriff.com/api/v3/client/orders/o1/three-ds",
          "headers": {
            "Content-Type": "application/json"
          },
          "body": {
            "code": "00000",
            "message": "OK",
            "payload": {
              "accessUrl": "https://acs.bank.example",
              "channel": "KAPITAL",
              "clientRequest": [
                {
                  "key": "creq",
                  "value": "***(23)"
                },
                {
                  "key": "threeDSSessionData",
                  "value": null
                }
              ],
              "nextAction": "THREE_DS",
              "orderId": "o1"
            },
            "responseId": "r-1",
            "route": "/api/v3/client/orders"
          }
        }
        """)

        let secrets = [
            Self.publishableKey, Self.clientSecret, CardFlowHarness.encrypted.encryptedMessage,
            CardFlowHarness.encrypted.wrappedKey, CardBodies.creq,
        ]
        for entry in recorder.all {
            for secret in secrets {
                #expect(!entry.message.contains(secret), "log line contains a secret: \(entry.level.label)")
            }
        }
    }

    @Test("Debug builds log HTTP details through retrieveOrder; release builds never do")
    func httpDetailsInDebugBuildsOnly() async throws {
        let recorder = LogRecorder()
        recorder.install()
        defer {
            Payriff.reset()
            PayriffLogger.onLog = nil
        }
        for isDebugBuild in [true, false] {
            Payriff.reset()
            Payriff.services.isDebugBuild = isDebugBuild
            Payriff.services.transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"o1","status":"CREATED","paymentMethods":["CARD"]}}"#)
            Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox, enableLogging: true))
            recorder.clear()
            _ = try await Payriff.retrieveOrder(orderId: "o1", clientSecret: Self.clientSecret)

            let details = Self.httpDetails(recorder.all)
            #expect(details.count == (isDebugBuild ? 2 : 0), "debug build: \(isDebugBuild)")
            #expect(recorder.contains("GET https://sb-api.payriff.com/api/v3/client/orders/o1 -> HTTP 200"), "the one-line entries stay")
            if isDebugBuild {
                let urls = try details.map { try Self.detailsJSON($0)["url"] as? String }
                #expect(urls == ["https://sb-api.payriff.com/api/v3/client/orders/o1", "https://sb-api.payriff.com/api/v3/client/orders/o1"])
            }
            for secret in [Self.clientSecret, Self.publishableKey] {
                #expect(!recorder.all.contains { $0.message.contains(secret) })
            }
        }
    }

    @Test("Every entry shows the request URL with a long order id shortened, in debug and release builds")
    func requestURLsShortenTheOrderId() async throws {
        let recorder = LogRecorder()
        recorder.install()
        defer {
            Payriff.reset()
            PayriffLogger.onLog = nil
        }
        let orderId = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        let shown = "https://sb-api.payriff.com/api/v3/client/orders/7c9e…0ae7"
        for isDebugBuild in [true, false] {
            Payriff.reset()
            Payriff.services.isDebugBuild = isDebugBuild
            Payriff.services.transport = FakeTransport(status: 200, body: #"{"code":"00000","payload":{"orderId":"\#(orderId)","status":"CREATED","paymentMethods":["CARD"]}}"#)
            Payriff.configure(PayriffConfig(publishableKey: Self.publishableKey, environment: .sandbox, enableLogging: true))
            recorder.clear()
            _ = try await Payriff.retrieveOrder(orderId: orderId, clientSecret: Self.clientSecret)

            #expect(recorder.contains("GET \(shown) -> HTTP 200"), "debug build: \(isDebugBuild)")
            let details = Self.httpDetails(recorder.all)
            let urls = try details.map { try Self.detailsJSON($0)["url"] as? String }
            #expect(urls == (isDebugBuild ? [shown, shown] : []))
            // Only the response body, a debug-build detail, holds the id itself (as `orderId`).
            let outsideBodies = recorder.all.filter { entry in !details.contains { $0.message == entry.message } }
            #expect(!outsideBodies.contains { $0.message.contains(orderId) })
            #expect(!details.contains { $0.message.contains("/orders/\(orderId)") })
        }
    }
}
