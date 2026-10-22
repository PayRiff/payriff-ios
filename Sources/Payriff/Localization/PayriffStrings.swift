/// The 3-D Secure sheet's UI copy (CONTRACT §10): exactly the `vectors/strings.json` texts of
/// the keys the sheet uses; a unit test enforces this. Texts are kept in code, not in a resource
/// bundle, so SPM and CocoaPods builds behave the same.
struct PayriffStrings: Sendable {
    enum Key: String, CaseIterable, Sendable {
        case title
        case verifying
        case close
        case retry
        case cancelConfirmTitle = "cancel_confirm_title"
        case cancelConfirmMessage = "cancel_confirm_message"
        case cancelConfirmYes = "cancel_confirm_yes"
        case cancelConfirmNo = "cancel_confirm_no"
        case pageLoadError = "page_load_error"
    }

    /// The language the texts are shown in.
    let language: PayriffLanguage

    /// The text for `key` in ``language``.
    subscript(_ key: Key) -> String {
        Self.table[key]?[language] ?? Self.table[key]?[.en] ?? key.rawValue
    }

    static let table: [Key: [PayriffLanguage: String]] = [
        .title: [
            .az: "Ödəniş",
            .en: "Payment",
            .ru: "Оплата",
        ],
        .verifying: [
            .az: "Ödəniş yoxlanılır…",
            .en: "Checking payment…",
            .ru: "Проверяем платёж…",
        ],
        .close: [
            .az: "Bağla",
            .en: "Close",
            .ru: "Закрыть",
        ],
        .retry: [
            .az: "Yenidən cəhd et",
            .en: "Try again",
            .ru: "Повторить",
        ],
        .cancelConfirmTitle: [
            .az: "Ödənişi ləğv edək?",
            .en: "Cancel payment?",
            .ru: "Отменить оплату?",
        ],
        .cancelConfirmMessage: [
            .az: "Ödəniş hələ tamamlanmayıb. Pəncərəni bağlasanız, ödəniş ləğv olunacaq.",
            .en: "The payment isn't complete yet. If you close this window, the payment will be cancelled.",
            .ru: "Оплата ещё не завершена. Если закрыть окно, оплата будет отменена.",
        ],
        .cancelConfirmYes: [
            .az: "Ləğv et",
            .en: "Cancel payment",
            .ru: "Отменить",
        ],
        .cancelConfirmNo: [
            .az: "Ödənişə davam et",
            .en: "Continue payment",
            .ru: "Продолжить оплату",
        ],
        .pageLoadError: [
            .az: "Səhifə yüklənmədi. İnternet bağlantınızı yoxlayın.",
            .en: "The page couldn't be loaded. Check your internet connection.",
            .ru: "Не удалось загрузить страницу. Проверьте подключение к интернету.",
        ],
    ]
}
