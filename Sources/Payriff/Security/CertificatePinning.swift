import CryptoKit
import Foundation
import Security

/// TLS certificate pinning of the SDK's own HTTP client (CONTRACT §16.15, `tls_pins.json`).
///
/// A connection to a Client API host is accepted only when the platform's normal TLS validation
/// (chain, expiry, host name) succeeds **and** at least one certificate of the validated chain has
/// its SubjectPublicKeyInfo SHA-256 in ``pins``. Every Client API call (order, pay, three-ds,
/// status) goes through ``URLSessionTransport``, whose task delegate applies this.
///
/// The pins are CA keys, not the leaf: the current Sectigo intermediate and roots, and backup roots
/// of other major CAs, so the yearly certificate renewal keeps working. No setting turns pinning
/// off. The 3-D Secure web views are not pinned: they load the banks' pages. A test transport
/// (`Payriff.services.transport`) replaces the whole transport, so tests are not affected.
enum CertificatePinning {
    /// The hosts whose connections are pinned: the Client API hosts of CONTRACT §16.2.
    static let hosts: Set<String> = ["api.payriff.com", "sb-api.payriff.com"]

    /// The SHA-256 (base64) of the SubjectPublicKeyInfo of every pinned CA key; a test checks that
    /// they equal `tls_pins.json`.
    static let pins: Set<String> = [
        "a9khLOZJxlnJyrxstg/P+seiDCm+Yf3OsrXyFocBaI0=", // Sectigo Public Server Authentication CA DV R36 (current intermediate)
        "Douxi77vs4G+Ib/BogbTFymEYq0QSFXwSgVCaZcI09Q=", // Sectigo Public Server Authentication Root R46 (current root)
        "x4QzPSC810K5/cMjb05Qm4k3Bw5zBn4lTdO/nEW/Td4=", // USERTrust RSA Certification Authority (current root)
        "ICGRfpgmOUXIWcQ/HXPLQTkFPEFPoDyjvH7ohhQpjzs=", // USERTrust ECC Certification Authority
        "sLVjNUaFYfW7n6EtgBeEpjOlcnBdNPMrZDRF36iwBdE=", // Sectigo Public Server Authentication Root E46
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=", // ISRG Root X1
        "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=", // ISRG Root X2
        "++MBgDH5WGvL9Bcn5Be30cRcL0f5O+NyoXuWtQdX1aI=", // Amazon Root CA 1
        "NqvDJlas/GRcYbcWE8S/IceH9cq77kg0jVhZeAPXq8k=", // Amazon Root CA 3
        "i7WTqTvh0OioIruIfFR4kMPnBqrS2rdiVPl/s2uC/CY=", // DigiCert Global Root G2
        "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=", // DigiCert Global Root CA
        "hxqRlPTu1bMS/0DITB1SSu0vd4u/8l8TjPgfaAp63Gc=", // GTS Root R1
        "cGuxAXyFXFkWm61cF4HPWX8S0srS9j0aSqN0k4AP+4A=", // GlobalSign Root CA - R3
        "rn+WLLnmp9v3uDP7GPqbcaiRdd+UnCMrap73yz3yu/w=", // GlobalSign Root R46
    ]

    /// The message of the `NETWORK_ERROR` a refused certificate becomes (CONTRACT §16.15).
    static let failureMessage = "Payriff's server certificate could not be verified."

    /// Whether connections to `host` are pinned.
    static func isPinned(host: String) -> Bool {
        hosts.contains(host.lowercased())
    }

    /// The base64 SHA-256 of the SubjectPublicKeyInfo of a DER certificate, or `nil` when `der` is
    /// not an X.509 certificate. The key is read from the certificate itself, so every key type
    /// (RSA, EC) gives the same value as `openssl x509 -pubkey | openssl pkey -pubin -outform der |
    /// openssl dgst -sha256`.
    static func spkiSHA256(certificate der: Data) -> String? {
        guard let spki = DER.subjectPublicKeyInfo(fromCertificate: [UInt8](der)) else { return nil }
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// Whether at least one certificate of `chain` (DER) has a key in `pins`. A pure check on the
    /// certificates: their validity dates do not matter here.
    static func containsPinnedKey(_ chain: [Data], pins: Set<String> = CertificatePinning.pins) -> Bool {
        chain.contains { certificate in
            guard let hash = spkiSHA256(certificate: certificate) else { return false }
            return pins.contains(hash)
        }
    }

    /// The outcome of checking a server's certificate chain.
    enum Verdict: Equatable {
        /// The platform trusts the chain for the host, and the chain has a pinned key.
        case trusted
        /// The platform does not trust the chain for the host: not a valid chain, expired, or
        /// issued for another host.
        case untrusted
        /// The platform trusts the chain, but none of its keys is pinned: a proxy's CA that the
        /// device trusts, or a certificate from a CA outside the pins.
        case notPinned
    }

    /// Checks `trust` for `host`: the platform's TLS validation with the host name, then the pins
    /// on the validated chain. It may block while the system checks the chain; URLSession calls it
    /// on its delegate queue.
    static func evaluate(_ trust: SecTrust, host: String, pins: Set<String> = CertificatePinning.pins) -> Verdict {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            return .untrusted
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return containsPinnedKey(chain.map { SecCertificateCopyData($0) as Data }, pins: pins) ? .trusted : .notPinned
    }

    /// What a task does with an authentication challenge.
    enum Decision {
        /// Not a server-trust challenge of a pinned host: URLSession handles it as usual.
        case defaultHandling
        /// The pinned host's certificate passed: continue with this trust.
        case accept(SecTrust)
        /// The pinned host's certificate failed (or the challenge had no certificate): cancel the
        /// connection before anything is sent.
        case refuse(Verdict)
    }

    /// The decision for `challenge`. Only server-trust challenges of the pinned hosts are checked.
    static func decide(_ challenge: URLAuthenticationChallenge) -> Decision {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, isPinned(host: space.host) else {
            return .defaultHandling
        }
        guard let trust = space.serverTrust else { return .refuse(.untrusted) }
        let verdict = evaluate(trust, host: space.host)
        return verdict == .trusted ? .accept(trust) : .refuse(verdict)
    }
}

extension DER {
    /// The DER of the SubjectPublicKeyInfo of an X.509 certificate (RFC 5280), read by structure:
    ///
    /// ```
    /// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue BIT STRING }
    /// TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber INTEGER, signature,
    ///                               issuer, validity, subject, subjectPublicKeyInfo, … }
    /// SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
    /// ```
    ///
    /// `nil` when the bytes are not shaped like a certificate.
    static func subjectPublicKeyInfo(fromCertificate der: [UInt8]) -> ArraySlice<UInt8>? {
        guard let (certificate, rest) = read(der[...]), rest.isEmpty, certificate.tag == 0x30,
              let parts = children(certificate.contents), parts.count == 3,
              parts[0].tag == 0x30, parts[1].tag == 0x30, parts[2].tag == 0x03,
              var fields = children(parts[0].contents) else {
            return nil
        }
        // [0] EXPLICIT version; a version 1 certificate has none.
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo.
        let tags: [UInt8] = [0x02, 0x30, 0x30, 0x30, 0x30, 0x30]
        guard fields.count >= tags.count, zip(fields, tags).allSatisfy({ $0.tag == $1 }) else { return nil }
        let spki = fields[tags.count - 1]
        guard let key = children(spki.contents), key.count == 2, key[0].tag == 0x30, key[1].tag == 0x03 else {
            return nil
        }
        return spki.encoded
    }
}
