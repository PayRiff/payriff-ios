import Foundation
import Security
import Testing
@testable import Payriff

/// Certificate pinning (CONTRACT §16.15) against `tls_pins.json`. The checks run on the vector's
/// certificates; no TLS connection is opened.
@Suite("Certificate pinning")
struct CertificatePinningTests {
    private static func vectors() throws -> TLSPinVectors {
        try #require(TLSPinVectors.file, "tls_pins.json decodes")
    }

    private static func ders(_ chain: TLSPinVectors.Chain) throws -> [Data] {
        try chain.pems.map { try #require(TLSPinVectors.der($0)) }
    }

    /// Every certificate of the vector: the trust anchors and both chains.
    private static func allCertificates() throws -> [Data] {
        let vectors = try vectors()
        return try vectors.trustAnchors.map { try #require(TLSPinVectors.der($0.pem), "\($0.name)") }
            + ders(vectors.currentChain) + ders(vectors.interceptedChain)
    }

    @Test("tls_pins.json decodes completely")
    func vectorDecodes() throws {
        let vectors = try Self.vectors()
        for (key, count) in [("hosts", vectors.hosts.count), ("pins", vectors.pins.count), ("trustAnchors", vectors.trustAnchors.count)] {
            let raw = try Vectors.rawCount("tls_pins", key: key)
            #expect(count > 0 && count == raw, "tls_pins.json \(key)")
        }
        #expect(vectors.currentChain.pems.count == 4)
        #expect(vectors.interceptedChain.pems.count == 2)
        #expect(try Self.allCertificates().count == vectors.trustAnchors.count + 6, "every PEM decodes")
    }

    @Test("The pinned hosts and pins equal tls_pins.json, and every trust anchor's key is the pin of the same name")
    func pinsEqualTheVector() throws {
        let vectors = try Self.vectors()
        #expect(CertificatePinning.hosts == Set(vectors.hosts))
        #expect(CertificatePinning.hosts.count == vectors.hosts.count)
        #expect(CertificatePinning.pins == Set(vectors.pins.map(\.spkiSha256)))
        #expect(CertificatePinning.pins.count == vectors.pins.count, "no pin twice")
        for environment in PayriffEnvironment.allCases {
            #expect(CertificatePinning.isPinned(host: ClientAPIHost.host(for: environment)), "\(environment) is pinned")
        }
        // The anchors (for SDKs that pin by trust anchor) are the pinned roots: the same CAs.
        let pinsByName = Dictionary(uniqueKeysWithValues: vectors.pins.map { ($0.name, $0.spkiSha256) })
        for anchor in vectors.trustAnchors {
            let der = try #require(TLSPinVectors.der(anchor.pem), "\(anchor.name)")
            let hash = try #require(CertificatePinning.spkiSHA256(certificate: der), "\(anchor.name)")
            #expect(hash == pinsByName[anchor.name], "\(anchor.name)")
        }
        #expect(Set(pinsByName.keys).subtracting(vectors.trustAnchors.map(\.name)) == ["Sectigo Public Server Authentication CA DV R36"], "only the intermediate has no anchor")
    }

    @Test("Only the Client API hosts are pinned, in any letter case; the 3-D Secure pages are not")
    func pinnedHosts() {
        #expect(CertificatePinning.isPinned(host: "api.payriff.com"))
        #expect(CertificatePinning.isPinned(host: "SB-API.Payriff.com"))
        for host in ["pay.payriff.com", "payriff.com", "acs.bank.example", "api.payriff.com.attacker.example", "xapi.payriff.com"] {
            #expect(!CertificatePinning.isPinned(host: host), "\(host)")
        }
    }

    // MARK: The SubjectPublicKeyInfo parser

    @Test("The SPKI SHA-256 of every certificate equals openssl's, for RSA (2048 to 4096 bits) and EC (P-256, P-384) keys")
    func spkiHashes() throws {
        let vectors = try Self.vectors()
        // openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
        #expect(try Self.ders(vectors.currentChain).map(CertificatePinning.spkiSHA256(certificate:)) == [
            "nEiZ85QmYctvU0TnjwUMYL1m38DKy5s0CIVjqahrMko=", // *.payriff.com (not pinned)
            "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=", // Sectigo DV R36
            "Douxi77vs4G+Ib/BogbTFymEYq0QSFXwSgVCaZcI09Q=", // Sectigo Root R46, cross-signed
            "x4QzPSC810K5/cMjb05Qm4k3Bw5zBn4lTdO/nEW/Td4=", // USERTrust RSA
        ])
        #expect(try Self.ders(vectors.interceptedChain).map(CertificatePinning.spkiSHA256(certificate:)) == [
            "mP72qr5bFFrqd6/QtrZKtA8BAFgOwrK7nUVNRfmnSZE=", // the proxy's api.payriff.com
            "bdOKKTWjCMLcCdTP9zxqBI36892nfmAbaSARCQFYb8A=", // Test Interception Proxy CA
        ])
    }

    @Test("The parsed SubjectPublicKeyInfo holds the key that Security reads from the certificate")
    func spkiMatchesSecurity() throws {
        for der in try Self.allCertificates() {
            let spki = try #require(DER.subjectPublicKeyInfo(fromCertificate: [UInt8](der)))
            let (element, rest) = try #require(DER.read(spki))
            #expect(rest.isEmpty && element.tag == 0x30)
            let parts = try #require(DER.children(element.contents))
            // SEQUENCE { AlgorithmIdentifier, BIT STRING { 0 unused bits, key } }
            #expect(parts.count == 2 && parts[0].tag == 0x30 && parts[1].tag == 0x03 && parts[1].contents.first == 0)
            let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
            let key = try #require(SecCertificateCopyKey(certificate))
            let external = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
            #expect(Data(parts[1].contents.dropFirst()) == external)
        }
    }

    /// A DER TLV with a short or long length.
    private static func tlv(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        let count = contents.count
        if count < 0x80 { return [tag, UInt8(count)] + contents }
        if count < 0x100 { return [tag, 0x81, UInt8(count)] + contents }
        return [tag, 0x82, UInt8(count >> 8), UInt8(count & 0xFF)] + contents
    }

    @Test("The parser reads a version 1 certificate and refuses everything that is not shaped like a certificate")
    func parserEdges() throws {
        let leaf = [UInt8](try #require(try Self.ders(try Self.vectors().currentChain).first))
        let spki = Array(try #require(DER.subjectPublicKeyInfo(fromCertificate: leaf)))
        let name = Self.tlv(0x30, Self.tlv(0x31, Self.tlv(0x30, Self.tlv(0x06, [0x55, 0x04, 0x03]) + Self.tlv(0x0C, Array("x".utf8)))))
        let algorithm = Self.tlv(0x30, Self.tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let validity = Self.tlv(0x30, Self.tlv(0x17, Array("260101000000Z".utf8)) + Self.tlv(0x17, Array("270101000000Z".utf8)))
        func certificate(version: [UInt8], key: [UInt8]) -> [UInt8] {
            let tbs = Self.tlv(0x30, version + Self.tlv(0x02, [0x01]) + algorithm + name + validity + name + key)
            return Self.tlv(0x30, tbs + algorithm + Self.tlv(0x03, [0x00, 0x01]))
        }
        // Version 1 has no [0] version field; version 3 has one.
        #expect(DER.subjectPublicKeyInfo(fromCertificate: certificate(version: [], key: spki)).map(Array.init) == spki)
        let v3 = Self.tlv(0xA0, Self.tlv(0x02, [0x02]))
        #expect(DER.subjectPublicKeyInfo(fromCertificate: certificate(version: v3, key: spki)).map(Array.init) == spki)

        // Not a certificate.
        #expect(DER.subjectPublicKeyInfo(fromCertificate: []) == nil)
        #expect(DER.subjectPublicKeyInfo(fromCertificate: Array("not a certificate".utf8)) == nil)
        #expect(DER.subjectPublicKeyInfo(fromCertificate: Array(leaf.dropLast())) == nil, "truncated")
        #expect(DER.subjectPublicKeyInfo(fromCertificate: leaf + [0x00]) == nil, "trailing bytes")
        #expect(DER.subjectPublicKeyInfo(fromCertificate: spki) == nil, "a bare SubjectPublicKeyInfo")
        #expect(DER.subjectPublicKeyInfo(fromCertificate: certificate(version: [], key: Self.tlv(0x04, spki))) == nil, "no SEQUENCE where the key belongs")
        #expect(DER.subjectPublicKeyInfo(fromCertificate: certificate(version: [], key: Self.tlv(0x30, algorithm))) == nil, "a key without its BIT STRING")
        let indefinite = [UInt8(0x30), 0x80] + leaf.dropFirst(4)
        #expect(DER.subjectPublicKeyInfo(fromCertificate: indefinite) == nil, "indefinite length is not DER")
        #expect(CertificatePinning.spkiSHA256(certificate: Data("garbage".utf8)) == nil)
    }

    // MARK: The pin check

    @Test("The pin check accepts the chain api.payriff.com serves and refuses an interception proxy's chain")
    func pinCheck() throws {
        let vectors = try Self.vectors()
        let current = try Self.ders(vectors.currentChain)
        let intercepted = try Self.ders(vectors.interceptedChain)
        #expect(CertificatePinning.containsPinnedKey(current))
        #expect(!CertificatePinning.containsPinnedKey(intercepted))
        // The leaf's key is not pinned; any one CA of the chain is enough, so a renewed leaf keeps working.
        #expect(!CertificatePinning.containsPinnedKey([current[0]]))
        for ca in current.dropFirst() {
            #expect(CertificatePinning.containsPinnedKey([current[0], ca]))
        }
        #expect(!CertificatePinning.containsPinnedKey([]))
        #expect(!CertificatePinning.containsPinnedKey([Data("garbage".utf8)]))
        #expect(!CertificatePinning.containsPinnedKey(current, pins: []))
    }

    // MARK: The trust evaluation

    /// A trust for `chain` that trusts only `anchors`, at a fixed date inside the validity of both
    /// chains (the leaf of api.payriff.com expires 2027-01-06), without network access.
    private static func trust(_ chain: [Data], anchors: [Data]) throws -> SecTrust {
        let certificates = try chain.map { try #require(SecCertificateCreateWithData(nil, $0 as CFData)) }
        let anchorCertificates = try anchors.map { try #require(SecCertificateCreateWithData(nil, $0 as CFData)) }
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let created = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(created, anchorCertificates as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(created, true) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(created, Date(timeIntervalSince1970: 1_796_083_200) as CFDate) == errSecSuccess) // 2026-12-01
        #expect(SecTrustSetNetworkFetchAllowed(created, false) == errSecSuccess)
        return created
    }

    @Test("evaluate: the platform's validation with the host name, then the pins on the validated chain")
    func evaluate() throws {
        let vectors = try Self.vectors()
        let current = try Self.ders(vectors.currentChain)
        let root = try #require(current.last)
        #expect(CertificatePinning.evaluate(try Self.trust(current, anchors: [root]), host: "api.payriff.com") == .trusted)
        #expect(CertificatePinning.evaluate(try Self.trust(current, anchors: [root]), host: "sb-api.payriff.com") == .trusted)
        // Validated for another host, it is not trusted.
        #expect(CertificatePinning.evaluate(try Self.trust(current, anchors: [root]), host: "pay.example.com") == .untrusted)
        // A chain the platform trusts but whose keys are not pinned is refused.
        #expect(CertificatePinning.evaluate(try Self.trust(current, anchors: [root]), host: "api.payriff.com", pins: []) == .notPinned)
        let intermediate = try #require(CertificatePinning.spkiSHA256(certificate: current[1]))
        #expect(CertificatePinning.evaluate(try Self.trust(current, anchors: [root]), host: "api.payriff.com", pins: [intermediate]) == .trusted)
        // The interception proxy's chain never passes, not even on a device that trusts its CA.
        let intercepted = try Self.ders(vectors.interceptedChain)
        #expect(CertificatePinning.evaluate(try Self.trust(intercepted, anchors: [intercepted[1]]), host: "api.payriff.com") != .trusted)
        #expect(CertificatePinning.evaluate(try Self.trust(intercepted, anchors: [root]), host: "api.payriff.com") == .untrusted)
    }

    /// Answers nothing; the decisions under test do not use the sender.
    private final class SilentSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private static func challenge(host: String, method: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: SilentSender())
    }

    @Test("Challenges: a pinned host's server trust without a certificate is refused; other hosts and other methods are left to URLSession")
    func challengeDecisions() {
        func isRefused(_ decision: CertificatePinning.Decision) -> Bool {
            if case .refuse = decision { return true }
            return false
        }
        func isDefault(_ decision: CertificatePinning.Decision) -> Bool {
            if case .defaultHandling = decision { return true }
            return false
        }
        #expect(isRefused(CertificatePinning.decide(Self.challenge(host: "api.payriff.com", method: NSURLAuthenticationMethodServerTrust))))
        #expect(isRefused(CertificatePinning.decide(Self.challenge(host: "sb-api.payriff.com", method: NSURLAuthenticationMethodServerTrust))))
        #expect(isDefault(CertificatePinning.decide(Self.challenge(host: "acs.bank.example", method: NSURLAuthenticationMethodServerTrust))))
        #expect(isDefault(CertificatePinning.decide(Self.challenge(host: "api.payriff.com", method: NSURLAuthenticationMethodHTTPBasic))))
        #expect(isDefault(CertificatePinning.decide(Self.challenge(host: "api.payriff.com", method: NSURLAuthenticationMethodClientCertificate))))
    }

    @Test("A refused certificate is NETWORK_ERROR, not retryable, with the contract's message")
    func failureError() {
        let error = ClientAPIClient.transportError(CertificatePinningError())
        #expect(error.code == .networkError)
        #expect(!error.isRetryable)
        #expect(!error.isFatal)
        #expect(error.message == "Payriff's server certificate could not be verified.")
        #expect(error.httpStatus == nil)
    }
}
