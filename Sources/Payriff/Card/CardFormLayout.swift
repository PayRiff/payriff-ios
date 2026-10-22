/// How ``PayriffCardForm`` arranges its fields (CONTRACT §16.4). Set it with
/// ``PayriffCardFormStyle/layout``.
public enum PayriffCardFormLayout: String, Sendable, Hashable, Codable, CaseIterable {
    /// The card form of Payriff's hosted payment page, and the default. The cardholder name comes
    /// first (when shown), under the title "Card holder". Then, under "Card information", one box
    /// holds the card number with the brand's mark, and below it the expiry and the CVC side by
    /// side. Each of the two sections has one error line.
    case grouped
    /// Every field in its own box, with its own label above it and its own error below it: the
    /// card number, then the expiry and the CVV side by side, then the cardholder name.
    case stacked
}

/// A section of the card form: a title, one outlined box with the section's fields and one error
/// line (CONTRACT §16.4). This file is free of UIKit, so `swift test` checks the layout rules on
/// a Mac; ``PayriffCardForm`` renders them.
struct CardFormSection: Hashable, Sendable {
    /// What the title above the box says.
    enum Title: Hashable, Sendable {
        /// The field's label: `label.<field>`, or the style's holder label.
        case field(PayriffCardField)
        /// `group.cardInformation`, or the style's card label.
        case cardInformation
    }

    let title: Title
    /// The fields, in order. The first field has a row of its own; the others share the next row
    /// in equal parts. The order is also the order in which the error line picks its error.
    let fields: [PayriffCardField]

    /// A section with one field under its own label.
    static func single(_ field: PayriffCardField) -> CardFormSection {
        CardFormSection(title: .field(field), fields: [field])
    }

    /// The card box of the grouped layout: the number row, then expiry | CVC.
    static let cardInformation = CardFormSection(title: .cardInformation, fields: [.number, .expiry, .cvv])
}

/// The outline of a section's box.
enum CardFormOutline: Hashable, Sendable {
    /// The border colour.
    case normal
    /// The focus colour: one of the section's fields is being edited.
    case focused
    /// The error colour: the section shows an error. It wins over focus.
    case error
}

extension PayriffCardFormLayout {
    /// The sections, top to bottom. Sections in the same row sit side by side in equal parts.
    func rows(showsHolder: Bool) -> [[CardFormSection]] {
        switch self {
        case .grouped:
            return showsHolder ? [[.single(.holder)], [.cardInformation]] : [[.cardInformation]]
        case .stacked:
            let rows: [[CardFormSection]] = [[.single(.number)], [.single(.expiry), .single(.cvv)]]
            return showsHolder ? rows + [[.single(.holder)]] : rows
        }
    }

    /// The fields in the order they appear, top to bottom and leading to trailing.
    func visualOrder(showsHolder: Bool) -> [PayriffCardField] {
        rows(showsHolder: showsHolder).flatMap { $0.flatMap(\.fields) }
    }
}

extension CardFormModel {
    /// The section's error line: the first visible error of its fields, in their order. In the
    /// card box that is number → expiry → CVC, so the box never shows more than one error.
    func sectionError(_ section: CardFormSection) -> PayriffCardFieldIssue? {
        for field in section.fields where fields.contains(field) {
            if let error = visibleError(field) {
                return PayriffCardFieldIssue(field: field, error: error, message: strings.message(field, error))
            }
        }
        return nil
    }

    /// The section's outline: the error colour while it shows an error, else the focus colour
    /// while one of its fields has focus.
    func outline(_ section: CardFormSection) -> CardFormOutline {
        if sectionError(section) != nil { return .error }
        return section.fields.contains { state($0).focused } ? .focused : .normal
    }
}
