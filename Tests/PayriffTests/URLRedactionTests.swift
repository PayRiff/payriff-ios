import Foundation
import Testing
@testable import Payriff

/// CONTRACT §11: the one URL redaction of every log entry, `Log.redactedURL(_:)`, which the
/// general log, the HTTP details and the URLs inside logged bodies share.
@Suite("URL redaction in logs")
struct URLRedactionTests {
    @Test("Payriff's API hosts are the hosts of the two environments")
    func apiHosts() {
        #expect(Log.apiHosts == ["api.payriff.com", "sb-api.payriff.com"])
        #expect(Log.longPathSegment == 16)
        #expect(Log.shortenedSegmentEnds == 4)
    }

    @Test("Payriff's API hosts keep the path, never the query or the fragment", arguments: [
        ("https://api.payriff.com/api/v3/client/orders/o1?x=1", "https://api.payriff.com/api/v3/client/orders/o1"),
        ("https://sb-api.payriff.com/api/v3/client/orders/o1/status#frag", "https://sb-api.payriff.com/api/v3/client/orders/o1/status"),
        ("https://api.payriff.com/api/v3/gateway/kapital/callback/ORD-1", "https://api.payriff.com/api/v3/gateway/kapital/callback/ORD-1"),
        ("http://api.payriff.com/a?b=1", "http://api.payriff.com/a"),
        ("https://api.payriff.com", "https://api.payriff.com"),
        ("https://api.payriff.com/", "https://api.payriff.com/"),
        ("https://api.payriff.com/api//v3/?q=1", "https://api.payriff.com/api//v3/"),
        ("https://api.payriff.com#/orders/o1", "https://api.payriff.com"),
        // An @ in the path or the query is not user info.
        ("https://api.payriff.com/r/@o1", "https://api.payriff.com/r/@o1"),
        ("https://api.payriff.com?email=a@b.example", "https://api.payriff.com"),
    ])
    func apiHostPaths(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
    }

    @Test("Path segments of 16 or more characters show only their first and last 4", arguments: [
        ("https://api.payriff.com/api/v3/client/orders/7c9e6679-7425-40de-944b-e07fc1f90ae7/pay", "https://api.payriff.com/api/v3/client/orders/7c9e…0ae7/pay"),
        ("https://api.payriff.com/x/123456789012345", "https://api.payriff.com/x/123456789012345"),
        ("https://api.payriff.com/x/1234567890123456", "https://api.payriff.com/x/1234…3456"),
        ("https://sb-api.payriff.com/0123456789abcdefXYZ/x/fedcba9876543210/three-ds", "https://sb-api.payriff.com/0123…fXYZ/x/fedc…3210/three-ds"),
        ("https://api.payriff.com/api/v3/client/orders/%C3%96d%C9%99ni%C5%9F", "https://api.payriff.com/api/v3/client/orders/%C3%…5%9F"),
        ("https://user:secret@api.payriff.com/api/v3/client/orders/7c9e6679-7425-40de-944b-e07fc1f90ae7?clientSecret=pr_cs_x#y", "https://api.payriff.com/api/v3/client/orders/7c9e…0ae7"),
        // A backslash does not split segments, so it can only make one longer.
        ("https://api.payriff.com\\api\\v3\\client\\orders\\7c9e6679-7425-40de-944b-e07fc1f90ae7", "https://api.payriff.com\\api…0ae7"),
    ])
    func longSegments(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
    }

    @Test("The user info never shows, up to the authority's last @", arguments: [
        ("https://user:pass@acs.bank.example/challenge?id=1#x", "https://acs.bank.example"),
        ("HTTPS://user@Bank.example", "https://bank.example"),
        ("https://a@b:c@acs.bank.example:8443/acs", "https://acs.bank.example:8443"),
        ("https://@bank.example/", "https://bank.example"),
        ("https://token:x-oauth-basic@api.payriff.com/api/v3/client/orders/o1", "https://api.payriff.com/api/v3/client/orders/o1"),
        ("https://user:pass@api.payriff.com:443", "https://api.payriff.com:443"),
    ])
    func userInfo(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
        #expect(!Log.redactedURL(url).contains("@"))
    }

    @Test("Any other host, such as a bank's 3-D Secure page, shows as scheme://host[:port] only", arguments: [
        ("https://acs.bank.example/challenge/7c9e6679-7425-40de-944b-e07fc1f90ae7?token=1", "https://acs.bank.example"),
        ("https://acs.bank.example/challenge/SESSION-TOKEN-0123456789", "https://acs.bank.example"),
        ("https://pay.payriff.com/r/o1?type=direct", "https://pay.payriff.com"),
        ("http://bank.example", "http://bank.example"),
        ("https://bank.example/", "https://bank.example"),
        ("https://acs.bank.example\\session\\token", "https://acs.bank.example"),
        // Look-alikes of the API hosts.
        ("https://api.payriff.com.evil.example/api/v3/client/orders/o1", "https://api.payriff.com.evil.example"),
        ("https://xapi.payriff.com/api/v3/client/orders/o1", "https://xapi.payriff.com"),
        ("https://evil.example/api.payriff.com/x", "https://evil.example"),
        ("https://evil.example\\api.payriff.com/x", "https://evil.example"),
        ("https://api.payriff.com@evil.example/x", "https://evil.example"),
    ])
    func otherHosts(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
    }

    @Test("A port shows after the host when it is a number", arguments: [
        ("https://acs.bank.example:8443/acs?x=1", "https://acs.bank.example:8443"),
        ("https://api.payriff.com:443/api/v3/client/orders/o1?x=1", "https://api.payriff.com:443/api/v3/client/orders/o1"),
        ("http://localhost:8080/x", "http://localhost:8080"),
        ("https://[2001:db8::1]:8443/acs?x=1", "https://[2001:db8::1]:8443"),
        ("https://[2001:DB8::1]/acs", "https://[2001:db8::1]"),
        ("https://acs.bank.example:/acs", "https://acs.bank.example"),
        ("https://acs.bank.example:tok3n/acs", "https://acs.bank.example"),
    ])
    func ports(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
    }

    @Test("Upper-case schemes and hosts match and show lower-cased; the path keeps its case", arguments: [
        ("HTTPS://API.PAYRIFF.COM/api/v3/client/orders/o1?x=1", "https://api.payriff.com/api/v3/client/orders/o1"),
        ("HTTPS://Sb-Api.Payriff.Com/API/V3/Client/Orders/O1", "https://sb-api.payriff.com/API/V3/Client/Orders/O1"),
        ("HTTPS://API.payriff.com/api/v3/client/orders/7C9E6679-7425-40DE-944B-E07FC1F90AE7", "https://api.payriff.com/api/v3/client/orders/7C9E…0AE7"),
        ("HtTp://ACS.Bank.Example/acs#frag", "http://acs.bank.example"),
        ("HTTPS://Pay.payriff.com/r/1#frag?x", "https://pay.payriff.com"),
        ("MAILTO:someone@example.com", "mailto:…"),
        ("BIRBANK://payment?id=1", "birbank:…"),
    ])
    func upperCase(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
    }

    @Test("Any other scheme shows only as <scheme>:…", arguments: [
        ("tel:+994501234567", "tel:…"),
        ("mailto:someone@example.com?subject=x", "mailto:…"),
        ("data:text/html;base64,PGh0bWw+", "data:…"),
        ("javascript:alert(1)", "javascript:…"),
        ("intent://pay?id=1#Intent;scheme=abbpay;end", "intent:…"),
        ("about:blank", "about:…"),
        ("file:///private/var/mobile/payriff", "file:…"),
        ("wss://api.payriff.com/socket?token=1", "wss:…"),
        ("ftp://user:pass@files.example/x", "ftp:…"),
    ])
    func otherSchemes(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
    }

    @Test("Without a scheme and a host, nothing of the URL shows", arguments: [
        ("https:acs.bank.example/acs", "https:…"),
        ("https:/acs?x=1", "https:…"),
        ("/api/v3/client/orders/o%201?x=1", "…"),
        ("//user:pass@acs.bank.example/acs", "…"),
        ("acs.bank.example/challenge", "…"),
        ("1http://bank.example/x", "…"),
        ("", ""),
    ])
    func withoutHost(url: String, expected: String) {
        #expect(Log.redactedURL(url) == expected)
    }

    /// URLs that `URL(string:)` accepts as they are.
    static let wellFormed = [
        "https://user:pass@acs.bank.example/challenge?id=1#x",
        "https://api.payriff.com/api/v3/client/orders/7c9e6679-7425-40de-944b-e07fc1f90ae7/pay?x=1",
        "HTTPS://SB-API.PAYRIFF.COM/api/v3/client/orders/o1#frag",
        "https://acs.bank.example:8443/acs/SESSION-TOKEN-0123456789",
        "https://[2001:db8::1]:8443/acs",
        "tel:+994501234567",
        "BIRBANK://payment?id=1",
    ]

    @Test("The general log redacts a URL as its text", arguments: wellFormed)
    func urlVariant(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(Log.redactedURL(url) == Log.redactedURL(text))
    }

    @Test("A missing URL logs as nil")
    func missingURL() {
        #expect(Log.redactedURL(nil as URL?) == "nil")
    }

    /// http(s) URLs of every kind above.
    static let httpURLs = [
        "https://user:pass@acs.bank.example/challenge?id=1#x",
        "https://api.payriff.com/api/v3/client/orders/7c9e6679-7425-40de-944b-e07fc1f90ae7/pay?x=1",
        "HTTPS://SB-API.PAYRIFF.COM/api/v3/client/orders/o1#frag",
        "https://acs.bank.example:8443/acs/SESSION-TOKEN-0123456789",
        "https://[2001:db8::1]:8443/acs",
        "HtTp://ACS.Bank.Example/acs#frag",
        "https://evil.example\\api.payriff.com/x",
        "https://api.payriff.com@evil.example/x",
    ]

    @Test("The url of the HTTP details uses the same redaction", arguments: httpURLs + ["https:acs.bank.example/acs", "tel:+994501234567", "/api/v3/client/orders/o1", ""])
    func httpDetailsURL(text: String) throws {
        let entry = HTTPLog.describeRequest(method: "GET", url: text, headers: [:], body: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any])
        #expect(json["url"] as? String == Log.redactedURL(text))
    }

    @Test("http(s) URLs inside bodies use the same redaction, at any depth", arguments: httpURLs)
    func urlsInBodies(text: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["payload": ["redirectUrl": text, "urls": [text]]])
        let shown = JSONValue.string(Log.redactedURL(text))
        #expect(HTTPLog.redactedBody(body) == .object([
            ("payload", .object([("redirectUrl", shown), ("urls", .array([shown]))])),
        ]))
    }
}
