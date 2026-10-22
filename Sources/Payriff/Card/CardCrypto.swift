import CryptoKit
import Foundation
import Security

/// The card details sent to Payriff, encrypted (CONTRACT §16.6). Created only from a validated
/// ``PayriffCardForm``. The textual representations never contain the values.
struct CardDetails: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let pan: String
    let cardHolder: String
    /// 4 digits.
    let expiryYear: String
    /// 2 digits.
    let expiryMonth: String
    let cvv: String

    /// The cardholder name sent when the form has no holder field, as on web.
    static let unknownHolder = "Unknown"

    var description: String { "CardDetails(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The encrypted card: the `/pay` body field and the `x-secret-key` header. Neither is ever
/// logged; the textual representations never contain them.
struct EncryptedCard: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `Base64(AES-256-GCM(aesKey, iv, cardJson))`: ciphertext ‖ 16-byte tag, no IV prefix.
    let encryptedMessage: String
    /// `Base64(RSA-OAEP-SHA256(PayriffKey, aesKey ‖ iv))`: the wrapped AES key, sent as the
    /// `x-secret-key` header.
    let wrappedKey: String

    var description: String { "EncryptedCard(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Card encryption failures. They carry no key material or card data.
enum CardCryptoError: Error, Sendable, Equatable {
    case randomUnavailable
    case invalidPublicKey
    case pinMismatch
    case encryptionFailed
}

/// Card encryption, byte-compatible with the web SDK (`fields/crypto.js`) and the backend
/// (CONTRACT §16.6, `card_crypto.json`):
///
/// 1. `aesKey` = 32 and `iv` = 12 bytes from the system CSPRNG, fresh for every pay attempt;
/// 2. `cardJson` = `JSON.stringify({pan, cardHolder, expiryYear, expiryMonth, cvv})`, byte for byte;
/// 3. `encryptedMessage` = Base64(AES-256-GCM(aesKey, iv, cardJson)) = ciphertext ‖ tag;
/// 4. `x-secret-key` = Base64(RSA-OAEP(SHA-256, MGF1-SHA-256)(PayriffKey, aesKey ‖ iv));
/// 5. the key, the IV, `aesKey ‖ iv` and the plaintext bytes are zeroed afterwards.
enum CardCrypto {
    static let aesKeyLength = 32
    static let ivLength = 12

    /// Payriff's RSA public key (X.509 SubjectPublicKeyInfo, 2048-bit), as pinned by the web SDK.
    /// The sandbox uses the same key (CONTRACT §16.2).
    static let payriffPublicKeySpki =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxRq5a+44T6Dac60XmVRQ"
        + "/7cpPyFsBnamXbJlRVJk8CnES5Re5tVMohyD0hZr3zcQj+bxodYB4zZpQTPlrXvF"
        + "BC3zz+rXnGlevxBQ6W2d3QC9q8vWH8p3ZOwTO3qVvDSHH9o+hMMRNbJ7kueq/KZl"
        + "X/F+bjZ23CZw7iXEGQT3HYVYnnHsvpaguYDteWBag2sPPLLsVjeB3zhTfQ7OsWp5"
        + "XTkDuRwLugHPvs6RHLcwGCnodukWyvwUaEUQR/kMGC+RbMsAIVkcLMP5csfR3Xo7"
        + "Gi98+i44iLN00f7gE8QvEmvv8xDspyTAjDEL1a5gK7TijJ3yLG/Bwa1rr1uskYy7"
        + "lwIDAQAB"

    /// SHA-256 of the DER of ``payriffPublicKeySpki`` (lower-case hex). The key is checked against
    /// it before every use, so a changed constant can never encrypt cards.
    static let payriffPublicKeySHA256 = "57bea5eb8ac72125dcda83306b98453840a80fc8ef5aac2798789587666024a5"

    /// A source of random bytes; tests pass fixed bytes.
    typealias RandomSource = @Sendable (_ count: Int) throws -> [UInt8]

    /// Random bytes from `SecRandomCopyBytes`.
    static let systemRandom: RandomSource = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CardCryptoError.randomUnavailable }
        return bytes
    }

    /// Encrypts `card` for Payriff with the pinned key.
    static func encrypt(_ card: CardDetails, random: RandomSource = systemRandom) throws -> EncryptedCard {
        try encrypt(card, publicKey: pinnedPublicKey(), random: random)
    }

    /// Encrypts `card` with `publicKey` (tests use their own key pair).
    static func encrypt(_ card: CardDetails, publicKey: SecKey, random: RandomSource = systemRandom) throws -> EncryptedCard {
        var aesKey = try random(aesKeyLength)
        defer { zero(&aesKey) }
        var iv = try random(ivLength)
        defer { zero(&iv) }
        guard aesKey.count == aesKeyLength, iv.count == ivLength else { throw CardCryptoError.randomUnavailable }

        var plaintext = cardJSON(card)
        defer { zero(&plaintext) }
        let sealed = try sealAESGCM(plaintext, key: aesKey, iv: iv)

        var keyAndIV = [UInt8]()
        keyAndIV.reserveCapacity(aesKeyLength + ivLength)
        keyAndIV.append(contentsOf: aesKey)
        keyAndIV.append(contentsOf: iv)
        defer { zero(&keyAndIV) }
        let wrapped = try wrapKey(keyAndIV, with: publicKey)

        return EncryptedCard(
            encryptedMessage: sealed.base64EncodedString(),
            wrappedKey: wrapped.base64EncodedString()
        )
    }

    /// The card JSON exactly as JavaScript's `JSON.stringify` writes it: keys in the order
    /// `pan, cardHolder, expiryYear, expiryMonth, cvv`, no spaces, UTF-8 with non-ASCII kept,
    /// `"` and `\` escaped (control characters as JavaScript does; validation never lets them
    /// through), `/` not escaped. Built straight into a byte buffer the caller zeroes.
    ///
    /// The buffer is allocated once with ``cardJSONCapacity(_:)``: growing it would free a copy
    /// of the plaintext (with the card number) without zeroing it.
    static func cardJSON(_ card: CardDetails) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(cardJSONCapacity(card))
        let members = cardJSONMembers(card)
        output.append(UInt8(ascii: "{"))
        for (index, member) in members.enumerated() {
            if index > 0 { output.append(UInt8(ascii: ",")) }
            appendJSONString(member.0, to: &output)
            output.append(UInt8(ascii: ":"))
            appendJSONString(member.1, to: &output)
        }
        output.append(UInt8(ascii: "}"))
        return output
    }

    private static func cardJSONMembers(_ card: CardDetails) -> [(String, String)] {
        [
            ("pan", card.pan),
            ("cardHolder", card.cardHolder),
            ("expiryYear", card.expiryYear),
            ("expiryMonth", card.expiryMonth),
            ("cvv", card.cvv),
        ]
    }

    /// An upper bound of the size of ``cardJSON(_:)``: `{}`, and per member two quoted strings,
    /// `:` and `,`, with at most 6 bytes per value scalar (`\u00xx`; UTF-8 needs at most 4).
    static func cardJSONCapacity(_ card: CardDetails) -> Int {
        cardJSONMembers(card).reduce(2) { total, member in
            total + 6 + member.0.utf8.count + 6 * member.1.unicodeScalars.count
        }
    }

    private static func appendJSONString(_ value: String, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output.append(contentsOf: [0x5C, 0x22])
            case "\\": output.append(contentsOf: [0x5C, 0x5C])
            case "\u{08}": output.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case "\u{0C}": output.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case "\n": output.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case "\r": output.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case "\t": output.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            default:
                if scalar.value < 0x20 {
                    // JSON.stringify writes other control characters as \u00xx with lower-case hex.
                    let hex = Array("0123456789abcdef".utf8)
                    output.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
                    output.append(hex[Int(scalar.value >> 4)])
                    output.append(hex[Int(scalar.value & 0x0F)])
                } else {
                    output.append(contentsOf: UTF8.encode(scalar)!)
                }
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    /// AES-256-GCM with a 128-bit tag: ciphertext ‖ tag, without the IV.
    static func sealAESGCM(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        var output = Data(box.ciphertext)
        output.append(box.tag)
        return output
    }

    /// RSA-OAEP with SHA-256 and MGF1-SHA-256 and an empty label. The plaintext buffer is passed
    /// to Security without an intermediate copy.
    static func wrapKey(_ keyAndIV: [UInt8], with publicKey: SecKey) throws -> Data {
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionOAEPSHA256) else {
            throw CardCryptoError.invalidPublicKey
        }
        let wrapped: Data? = keyAndIV.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                  let input = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, base, buffer.count, kCFAllocatorNull) else {
                return nil
            }
            var error: Unmanaged<CFError>?
            let output = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, input, &error)
            error?.release()
            return output as Data?
        }
        guard let wrapped else { throw CardCryptoError.encryptionFailed }
        return wrapped
    }

    /// The pinned Payriff key, after checking its SHA-256.
    static func pinnedPublicKey() throws -> SecKey {
        guard let der = Data(base64Encoded: payriffPublicKeySpki), sha256Hex(der) == payriffPublicKeySHA256 else {
            throw CardCryptoError.pinMismatch
        }
        return try rsaPublicKey(spki: der)
    }

    /// An RSA public key from an X.509 SubjectPublicKeyInfo (DER). Security expects the inner
    /// PKCS#1 `RSAPublicKey`, so the wrapper is removed after checking the algorithm.
    static func rsaPublicKey(spki: Data) throws -> SecKey {
        guard let pkcs1 = DER.rsaPublicKey(fromSpki: [UInt8](spki)) else { throw CardCryptoError.invalidPublicKey }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error)
        error?.release()
        guard let key else { throw CardCryptoError.invalidPublicKey }
        return key
    }

    /// Lower-case hex SHA-256.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }

    /// Overwrites `bytes` with zeros in a way the optimizer keeps (`memset_s`).
    static func zero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}

/// The few DER structures the card flow needs.
enum DER {
    /// The DER of the `rsaEncryption` algorithm OID, 1.2.840.113549.1.1.1.
    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    struct Element {
        let tag: UInt8
        let contents: ArraySlice<UInt8>
    }

    /// Reads one TLV from the start of `bytes`; returns it and the bytes after it.
    static func read(_ bytes: ArraySlice<UInt8>) -> (Element, ArraySlice<UInt8>)? {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { return nil }
        let tag = bytes[index]
        index += 1
        guard index < bytes.endIndex else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), bytes.endIndex - index >= count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard length >= 0, bytes.endIndex - index >= length else { return nil }
        let contents = bytes[index..<(index + length)]
        return (Element(tag: tag, contents: contents), bytes[(index + length)...])
    }

    /// The elements of a constructed value's contents.
    static func children(_ contents: ArraySlice<UInt8>) -> [Element]? {
        var rest = contents
        var elements: [Element] = []
        while !rest.isEmpty {
            guard let (element, after) = read(rest) else { return nil }
            elements.append(element)
            rest = after
        }
        return elements
    }

    private static func isRSAAlgorithm(_ element: Element) -> Bool {
        guard element.tag == 0x30, let parts = children(element.contents), let oid = parts.first else { return false }
        return oid.tag == 0x06 && Array(oid.contents) == rsaEncryptionOID
    }

    /// The PKCS#1 `RSAPublicKey` inside a SubjectPublicKeyInfo:
    /// `SEQUENCE { SEQUENCE { rsaEncryption, NULL }, BIT STRING { 0, RSAPublicKey } }`.
    static func rsaPublicKey(fromSpki der: [UInt8]) -> [UInt8]? {
        guard let (outer, rest) = read(der[...]), rest.isEmpty, outer.tag == 0x30,
              let parts = children(outer.contents), parts.count == 2,
              isRSAAlgorithm(parts[0]), parts[1].tag == 0x03,
              parts[1].contents.first == 0x00 else {
            return nil
        }
        return Array(parts[1].contents.dropFirst())
    }

    /// The PKCS#1 `RSAPrivateKey` inside a PKCS#8 PrivateKeyInfo:
    /// `SEQUENCE { INTEGER 0, SEQUENCE { rsaEncryption, NULL }, OCTET STRING { RSAPrivateKey } }`.
    static func rsaPrivateKey(fromPkcs8 der: [UInt8]) -> [UInt8]? {
        guard let (outer, rest) = read(der[...]), rest.isEmpty, outer.tag == 0x30,
              let parts = children(outer.contents), parts.count >= 3,
              parts[0].tag == 0x02, isRSAAlgorithm(parts[1]), parts[2].tag == 0x04 else {
            return nil
        }
        return Array(parts[2].contents)
    }
}
