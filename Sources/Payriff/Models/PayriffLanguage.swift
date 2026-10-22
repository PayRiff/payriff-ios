import Foundation

/// The language of the card form and the 3-D Secure sheet.
///
/// The effective language is `form.language ?? config.language ?? device language`
/// (CONTRACT §3.1).
public enum PayriffLanguage: String, Sendable, Hashable, Codable, CaseIterable {
    /// Azerbaijani.
    case az = "AZ"
    /// English.
    case en = "EN"
    /// Russian.
    case ru = "RU"

    /// Maps a locale identifier such as `az-AZ`, `ru_KZ` or `en-US` to a supported language.
    ///
    /// Only the primary language subtag (the text before the first `-` or `_`) is compared,
    /// case-insensitively: `az` gives ``az``, `ru` gives ``ru`` and anything else gives ``en``.
    ///
    /// - Parameter localeIdentifier: A BCP 47 or POSIX-style locale identifier.
    public init(localeIdentifier: String) {
        let primary = localeIdentifier
            .split(maxSplits: 1, whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { $0.lowercased() } ?? ""
        switch primary {
        case "az": self = .az
        case "ru": self = .ru
        default: self = .en
        }
    }

    /// The language derived from the user's preferred device language.
    public static var device: PayriffLanguage {
        PayriffLanguage(localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }
}
