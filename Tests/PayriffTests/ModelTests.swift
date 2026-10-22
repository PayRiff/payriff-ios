import Foundation
import Testing
@testable import Payriff

@Suite("Models")
struct ModelTests {
    @Test("Results encode to the shared JSON shape: every key present, null when unknown (CONTRACT §5.3)")
    func resultJSON() throws {
        let payment = PayriffPayment(
            orderId: "o1", status: .approved, rawStatus: "PAID",
            amount: Decimal(string: "19.99"), currency: "AZN", transactionId: "884213"
        )
        #expect(try Self.json(PayriffResult.success(payment)) ==
            #"{"payment":{"amount":19.99,"currency":"AZN","orderId":"o1","originalOrderId":null,"rawStatus":"PAID","status":"APPROVED","transactionId":"884213"},"type":"success"}"#)
        #expect(try Self.json(PayriffResult.cancelled(nil, reason: .userClosed)) ==
            #"{"payment":null,"reason":"userClosed","type":"cancelled"}"#)
        #expect(try Self.json(PayriffResult.pending(PayriffPayment(orderId: "o1", status: .unknown), reason: .verificationFailed)) ==
            #"{"payment":{"amount":null,"currency":null,"orderId":"o1","originalOrderId":null,"rawStatus":null,"status":"UNKNOWN","transactionId":null},"reason":"verificationFailed","type":"pending"}"#)
        let error = PayriffError(code: .paymentFailed, message: "Card declined by issuer", isRetryable: true, httpStatus: 200, payriffCode: "16001", supportTicket: "1")
        #expect(try Self.json(PayriffResult.failed(error)) ==
            #"{"error":{"code":"PAYMENT_FAILED","httpStatus":200,"isRetryable":true,"message":"Card declined by issuer","payriffCode":"16001","supportTicket":"1"},"type":"failed"}"#)
        #expect(try Self.json(PayriffResult.failed(.network("offline"))) ==
            #"{"error":{"code":"NETWORK_ERROR","httpStatus":null,"isRetryable":true,"message":"offline","payriffCode":null,"supportTicket":null},"type":"failed"}"#)
        // Payments still decode, also from the null-filled shape.
        let decoded = try JSONDecoder().decode(PayriffPayment.self, from: JSONEncoder().encode(PayriffPayment(orderId: "o2", status: .created)))
        #expect(decoded == PayriffPayment(orderId: "o2", status: .created))
    }

    @Test("result.jsonObject has the same shape and writes amounts exactly")
    func resultJSONObject() throws {
        let payment = PayriffPayment(orderId: "o1", status: .approved, rawStatus: "PAID", amount: Decimal(string: "19.99"), currency: "AZN")
        let data = try JSONSerialization.data(withJSONObject: PayriffResult.success(payment).jsonObject, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) ==
            #"{"payment":{"amount":19.99,"currency":"AZN","orderId":"o1","originalOrderId":null,"rawStatus":"PAID","status":"APPROVED","transactionId":null},"type":"success"}"#)
        let cancelled = PayriffResult.cancelled(nil, reason: .userClosed).jsonObject
        #expect(cancelled["payment"] is NSNull)
        #expect(Set(cancelled.keys) == ["type", "reason", "payment"])
        let failed = PayriffResult.failed(.paymentInProgress).jsonObject
        #expect(Set(failed.keys) == ["type", "error"])
        #expect(Set((failed["error"] as? [String: Any])?.keys.map { $0 } ?? []) == [
            "code", "message", "isRetryable", "httpStatus", "payriffCode", "supportTicket",
        ])
    }

    @Test("originalOrderId is always in the payment JSON and decodes from older JSON without it (CONTRACT §16.0 item 2)")
    func originalOrderIdJSON() throws {
        let switched = PayriffPayment(orderId: "o2", status: .approved, rawStatus: "APPROVED", originalOrderId: "o1")
        #expect(try Self.json(PayriffResult.success(switched)) ==
            #"{"payment":{"amount":null,"currency":null,"orderId":"o2","originalOrderId":"o1","rawStatus":"APPROVED","status":"APPROVED","transactionId":null},"type":"success"}"#)
        let object = try #require(PayriffResult.success(switched).jsonObject["payment"] as? [String: Any])
        #expect(object["originalOrderId"] as? String == "o1")
        #expect(PayriffResult.success(PayriffPayment(orderId: "o1", status: .approved)).payment?.jsonObject["originalOrderId"] is NSNull)
        #expect(try JSONDecoder().decode(PayriffPayment.self, from: JSONEncoder().encode(switched)) == switched)
        // JSON written before revision 4 has no originalOrderId.
        let older = try JSONDecoder().decode(PayriffPayment.self, from: Data(#"{"orderId":"o1","status":"PAID","rawStatus":"PAID","amount":1,"currency":"AZN","transactionId":null}"#.utf8))
        #expect(older == PayriffPayment(orderId: "o1", status: .approved, rawStatus: "PAID", amount: 1, currency: "AZN"))
        #expect(older.originalOrderId == nil)
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("Helpers: version, environment hosts, status parsing and result accessors")
    @MainActor
    func helperNames() {
        #expect(Payriff.version == "1.0.0")
        #expect(PayriffEnvironment.sandbox.apiBaseURL == URL(string: "https://sb-api.payriff.com"))
        #expect(PayriffPaymentStatus(rawStatus: "settled") == .approved)
        let result = PayriffResult.pending(PayriffPayment(orderId: "o1", status: .created), reason: .notFinal)
        #expect(!result.isSuccess && result.payment?.orderId == "o1" && result.error == nil)
        #expect(result.jsonObject["type"] as? String == "pending")
    }

    @Test("Result helpers")
    func resultHelpers() {
        let payment = PayriffPayment(orderId: "o1", status: .declined)
        #expect(PayriffResult.declined(payment).payment == payment)
        #expect(!PayriffResult.declined(payment).isSuccess)
        #expect(PayriffResult.success(payment).isSuccess)
        #expect(PayriffResult.failed(.paymentInProgress).error?.code == .paymentInProgress)
        #expect(PayriffResult.failed(.paymentInProgress).payment == nil)
        #expect(PayriffResult.cancelled(nil, reason: .userClosed).payment == nil)
        #expect(["success", "declined", "cancelled", "pending", "failed"] == [
            PayriffResult.success(payment), .declined(payment), .cancelled(nil, reason: .canceled),
            .pending(payment, reason: .notFinal), .failed(.paymentInProgress),
        ].map(\.type))
    }

    @Test("UNKNOWN is never retryable")
    func unknownNeverRetryable() {
        #expect(!PayriffError(code: .unknown, message: "x", isRetryable: true).isRetryable)
        #expect(PayriffError(code: .networkError, message: "x", isRetryable: true).isRetryable)
    }

    @Test("Errors compare every field but the cause and describe themselves")
    func errors() {
        let a = PayriffError(code: .networkError, message: "offline", isRetryable: true, cause: URLError(.notConnectedToInternet))
        let b = PayriffError(code: .networkError, message: "offline", isRetryable: true)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != PayriffError(code: .networkError, message: "offline", isRetryable: false))
        #expect(a.errorDescription == "offline")
        #expect(PayriffError(code: .orderNotPayable, message: "m", httpStatus: 400, payriffCode: "01000", supportTicket: "9").description ==
            "PayriffError(ORDER_NOT_PAYABLE: m, HTTP 400, payriffCode 01000, ticket 9)")
        // The codes the card flow produces; the hosted flow's API_ERROR, INVALID_RESPONSE and
        // PRESENTATION_FAILED were removed with it (CONTRACT revision 5).
        #expect(Set(PayriffError.Code.allCases.map(\.rawValue)) == [
            "NOT_CONFIGURED", "INVALID_CONFIG", "INVALID_ORDER", "PAYMENT_IN_PROGRESS",
            "UNAUTHORIZED", "RATE_LIMITED", "NETWORK_ERROR", "UNKNOWN",
            "VALIDATION_FAILED", "SESSION_EXPIRED", "ORDER_NOT_PAYABLE", "INVALID_REQUEST", "PAYMENT_FAILED",
            "UNEXPECTED_RESPONSE",
        ])
        // isFatal and fields take part in equality and the description; the result JSON keeps its shape.
        let fatal = PayriffError(code: .sessionExpired, message: "gone", httpStatus: 404, isFatal: true)
        #expect(fatal != PayriffError(code: .sessionExpired, message: "gone", httpStatus: 404))
        #expect(fatal.description == "PayriffError(SESSION_EXPIRED: gone, HTTP 404, fatal)")
        #expect(Set(fatal.jsonObject.keys) == ["code", "message", "isRetryable", "httpStatus", "payriffCode", "supportTicket"])
        let issue = PayriffCardFieldIssue(field: .cvv, error: .incomplete, message: "CVV is incomplete")
        let validation = PayriffError(code: .validationFailed, message: "invalid", fields: [issue])
        #expect(validation.fields == [issue])
        #expect(validation.description == "PayriffError(VALIDATION_FAILED: invalid, fields cvv=incomplete)")
        #expect(validation != PayriffError(code: .validationFailed, message: "invalid"))
    }

    @Test("Transport errors map to NETWORK_ERROR")
    func transportErrors() {
        #expect(ClientAPIClient.transportError(URLError(.timedOut)).code == .networkError)
        #expect(ClientAPIClient.transportError(URLError(.notConnectedToInternet)).isRetryable)
        #expect(ClientAPIClient.transportError(URLError(.secureConnectionFailed)).code == .networkError)
        #expect(ClientAPIClient.transportError(CancellationError()).code == .networkError)
        struct Other: Error {}
        #expect(ClientAPIClient.transportError(Other()).code == .networkError)
        #expect(ClientAPIClient.transportError(Other()).isRetryable)
    }

    @Test("Messages are split at the first newline into message and support ticket")
    func messageSplitting() {
        #expect(ResponseParser.splitMessage("Application not found!.\n Support ticket: 219959") == ("Application not found!.", "219959"))
        #expect(ResponseParser.splitMessage("  Plain  ") == ("Plain", nil))
        #expect(ResponseParser.splitMessage("Line one\nLine two") == ("Line one", nil))
        #expect(ResponseParser.splitMessage("A\r\n Support ticket:42 trailing") == ("A", "42"))
        #expect(ResponseParser.splitMessage(nil) == (nil, nil))
    }

    @Test("Order ids are percent-encoded as one path segment (CONTRACT §16.3)")
    func pathSegments() {
        #expect(ClientAPIClient.encodePathSegment("7c9e6679-7425-40de-944b-e07fc1f90ae7") == "7c9e6679-7425-40de-944b-e07fc1f90ae7")
        #expect(ClientAPIClient.encodePathSegment("..") == "%2E%2E")
        #expect(ClientAPIClient.encodePathSegment("a+b=c%d") == "a%2Bb%3Dc%25d")
        #expect(ClientAPIClient.encodePathSegment("Ödəniş") == "%C3%96d%C9%99ni%C5%9F")
    }

    @Test("Status normalization accepts aliases and decodes leniently")
    func statusDecoding() throws {
        #expect(PayriffPaymentStatus(rawStatus: " settle-pending ") == .approved)
        #expect(PayriffPaymentStatus(rawStatus: "Cancelled") == .canceled)
        let decoded = try JSONDecoder().decode([PayriffPaymentStatus].self, from: Data(#"["paid","WEIRD","PREAUTH_APPROVED"]"#.utf8))
        #expect(decoded == [.approved, .unknown, .preAuthApproved])
        #expect(String(decoding: try JSONEncoder().encode(PayriffPaymentStatus.refundInProgress), as: UTF8.self) == #""REFUND_IN_PROGRESS""#)
    }

    @Test("Logs show non-http(s) URLs only as <scheme>:… (CONTRACT §11)")
    func urlRedaction() {
        #expect(Log.redactedURL(URL(string: "tel:+994121234567")) == "tel:…")
        #expect(Log.redactedURL(URL(string: "mailto:support@payriff.com")) == "mailto:…")
        #expect(Log.redactedURL(URL(string: "data:text/html;base64,PGh0bWw+")) == "data:…")
        #expect(Log.redactedURL(URL(string: "javascript:alert(1)")) == "javascript:…")
        #expect(Log.redactedURL(URL(string: "intent://pay?id=1#Intent;scheme=abbpay;end")) == "intent:…")
        #expect(Log.redactedURL(URL(string: "BIRBANK://payment?id=1")) == "birbank:…")
        #expect(Log.redactedURL(URL(string: "HTTPS://pay.payriff.com/r/1?type=direct#x")) == "HTTPS://pay.payriff.com/r/1")
        #expect(Log.redactedURL(nil) == "nil")
    }

    @Test("Language from locale, device language and string lookups")
    func language() {
        #expect(PayriffLanguage(localeIdentifier: "ru-Cyrl-RU") == .ru)
        #expect(PayriffLanguage.allCases.contains(PayriffLanguage.device))
        #expect(PayriffStrings(language: .az)[.title] == "Ödəniş")
        #expect(PayriffStrings(language: .ru)[.close] == "Закрыть")
        #expect(PayriffStrings(language: .en)[.pageLoadError] == "The page couldn't be loaded. Check your internet connection.")
    }
}
