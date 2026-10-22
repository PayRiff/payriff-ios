import Foundation
@testable import Payriff

/// `tls_pins.json` (CONTRACT §16.15): the pinned hosts, the pins, the trust anchors, the chain
/// api.payriff.com serves and an interception proxy's chain.
struct TLSPinVectors: Decodable, Sendable {
    struct Pin: Decodable, Sendable {
        let name: String
        let spkiSha256: String
        let role: String
    }

    struct Anchor: Decodable, Sendable {
        let name: String
        let pem: String
    }

    struct Chain: Decodable, Sendable {
        let description: String
        /// Leaf first.
        let pems: [String]
    }

    let hosts: [String]
    let pins: [Pin]
    let trustAnchors: [Anchor]
    let currentChain: Chain
    let interceptedChain: Chain

    static let file = try? JSONDecoder().decode(TLSPinVectors.self, from: Vectors.data("tls_pins"))

    /// The DER of a PEM certificate.
    static func der(_ pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "-----BEGIN CERTIFICATE-----", lines.last == "-----END CERTIFICATE-----" else { return nil }
        return Data(base64Encoded: lines.dropFirst().dropLast().joined())
    }
}
