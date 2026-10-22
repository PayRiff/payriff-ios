/// The card form's copy: labels, placeholders, the "Card information" title and field errors in
/// az/en/ru (CONTRACT §16.4), and the texts of the payment view (`view.*`, CONTRACT §16.14).
///
/// The table must equal `vectors/card_strings.json` exactly; a unit test enforces this. The texts
/// are kept in code, not in a resource bundle, so SPM and CocoaPods builds behave the same.
struct CardStrings: Sendable, Equatable {
    /// The language the texts are shown in.
    let language: PayriffLanguage

    /// The field's label: the title above it, and its VoiceOver label.
    func label(_ field: PayriffCardField) -> String {
        Self.labels[language]?[field] ?? Self.labels[.en]?[field] ?? field.rawValue
    }

    /// The title of the card box of the grouped layout (`group.cardInformation`).
    var cardInformation: String {
        Self.cardInformationTitles[language] ?? Self.cardInformationTitles[.en] ?? "Card information"
    }

    /// The field's placeholder.
    func placeholder(_ field: PayriffCardField) -> String {
        Self.placeholders[language]?[field] ?? Self.placeholders[.en]?[field] ?? ""
    }

    /// A text of the payment view (`view.*` of `card_strings.json`).
    func view(_ text: ViewText) -> String {
        Self.viewTexts[language]?[text] ?? Self.viewTexts[.en]?[text] ?? ""
    }

    /// `view.poweredBy` split at "Payriff" (CONTRACT §16.14): the text before and after the word,
    /// spaces included, where the payment view puts the logo. "Powered by Payriff" gives
    /// ("Powered by ", ""), "Payriff tərəfindən hazırlanıb" gives ("", " tərəfindən hazırlanıb").
    /// `nil` when the text has no "Payriff"; the view then shows the text alone.
    var poweredByParts: (before: String, after: String)? {
        let text = view(.poweredBy)
        guard let range = text.range(of: Self.logoWord) else { return nil }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    /// The word of `view.poweredBy` that the logo replaces.
    static let logoWord = "Payriff"

    /// The keys of `view.*`.
    enum ViewText: String, CaseIterable, Sendable {
        /// The Pay button; the amount and the currency follow it.
        case pay
        /// The line next to the lock.
        case secure
        /// The footer; "Payriff" is replaced by the logo.
        case poweredBy
    }

    /// The error text for `error` in `field`. An error without a specific text falls back to the
    /// field's `invalid` text.
    func message(_ field: PayriffCardField, _ error: PayriffCardFieldError) -> String {
        let table = Self.messages[language] ?? Self.messages[.en] ?? [:]
        return table[field]?[error] ?? table[field]?[.invalid] ?? error.rawValue
    }

    static let messages: [PayriffLanguage: [PayriffCardField: [PayriffCardFieldError: String]]] = [
        .az: [
            .number: [
                .required: "Kart nömrəsini daxil edin",
                .incomplete: "Kart nömrəsi tam deyil",
                .invalid: "Kart nömrəsi yanlışdır",
                .unsupported: "Bu kart növü dəstəklənmir",
            ],
            .expiry: [
                .required: "Bitmə tarixini daxil edin",
                .incomplete: "Bitmə tarixi tam deyil",
                .invalid: "Bitmə tarixi yanlışdır",
                .expired: "Kartın müddəti bitib",
            ],
            .cvv: [
                .required: "CVV daxil edin",
                .incomplete: "CVV tam deyil",
                .invalid: "CVV yanlışdır",
            ],
            .holder: [
                .required: "Kart sahibinin adını daxil edin",
                .invalid: "Kart sahibinin adı yanlışdır",
            ],
        ],
        .en: [
            .number: [
                .required: "Enter your card number",
                .incomplete: "Card number is incomplete",
                .invalid: "Card number is invalid",
                .unsupported: "This card type is not supported",
            ],
            .expiry: [
                .required: "Enter the expiry date",
                .incomplete: "Expiry date is incomplete",
                .invalid: "Expiry date is invalid",
                .expired: "This card has expired",
            ],
            .cvv: [
                .required: "Enter the CVV",
                .incomplete: "CVV is incomplete",
                .invalid: "CVV is invalid",
            ],
            .holder: [
                .required: "Enter the cardholder name",
                .invalid: "Cardholder name is invalid",
            ],
        ],
        .ru: [
            .number: [
                .required: "Введите номер карты",
                .incomplete: "Номер карты введён не полностью",
                .invalid: "Неверный номер карты",
                .unsupported: "Этот тип карты не поддерживается",
            ],
            .expiry: [
                .required: "Введите срок действия",
                .incomplete: "Срок действия введён не полностью",
                .invalid: "Неверный срок действия",
                .expired: "Срок действия карты истёк",
            ],
            .cvv: [
                .required: "Введите CVV",
                .incomplete: "CVV введён не полностью",
                .invalid: "Неверный CVV",
            ],
            .holder: [
                .required: "Введите имя владельца карты",
                .invalid: "Неверное имя владельца карты",
            ],
        ],
    ]

    /// The placeholders of Payriff's hosted payment page; only the holder's is translated.
    static let placeholders: [PayriffLanguage: [PayriffCardField: String]] = [
        .az: [.number: "1234 1234 1234 1234", .expiry: "MM / YY", .cvv: "CVC", .holder: "Kart sahibinin adı"],
        .en: [.number: "1234 1234 1234 1234", .expiry: "MM / YY", .cvv: "CVC", .holder: "Card holder"],
        .ru: [.number: "1234 1234 1234 1234", .expiry: "MM / YY", .cvv: "CVC", .holder: "Владелец карты"],
    ]

    static let labels: [PayriffLanguage: [PayriffCardField: String]] = [
        .az: [.number: "Kart nömrəsi", .expiry: "Bitmə tarixi", .cvv: "CVV kodu", .holder: "Kart sahibinin adı"],
        .en: [.number: "Card number", .expiry: "Expiry date", .cvv: "Security code", .holder: "Card holder"],
        .ru: [.number: "Номер карты", .expiry: "Срок действия", .cvv: "Код безопасности", .holder: "Владелец карты"],
    ]

    /// `group.cardInformation`.
    static let cardInformationTitles: [PayriffLanguage: String] = [
        .az: "Kart məlumatları",
        .en: "Card information",
        .ru: "Информация о карте",
    ]

    /// `view.*`: the payment view's Pay button, secure line and footer.
    static let viewTexts: [PayriffLanguage: [ViewText: String]] = [
        .az: [.pay: "Ödə", .secure: "PCI DSS ilə təhlükəsiz ödəniş", .poweredBy: "Payriff tərəfindən hazırlanıb"],
        .en: [.pay: "Pay", .secure: "Proceed securely by PCI DSS", .poweredBy: "Powered by Payriff"],
        .ru: [.pay: "Оплатить", .secure: "Безопасная оплата по PCI DSS", .poweredBy: "При поддержке Payriff"],
    ]
}
