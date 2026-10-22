import Foundation

/// A change in one card field, the `change` event of CONTRACT §16.4. It never contains what the
/// customer typed.
public struct PayriffCardFormChange: Sendable, Hashable {
    /// The field that changed.
    public let field: PayriffCardField
    /// Whether the field's value is valid.
    public let isValid: Bool
    /// Whether the field is empty.
    public let isEmpty: Bool
    /// The error shown under the field now, if any. Definite errors show at once, `incomplete`
    /// after the field lost focus or a payment was attempted, `required` only after a payment
    /// was attempted.
    public let error: PayriffCardFieldError?
    /// The text of ``error`` in the form's language.
    public let errorMessage: String?
    /// The detected brand; set for the number field only.
    public let brand: PayriffCardBrand?
    /// Whether every field of the form is valid.
    public let isComplete: Bool

    /// Creates a change, for example to stub events in your tests.
    public init(
        field: PayriffCardField,
        isValid: Bool,
        isEmpty: Bool,
        error: PayriffCardFieldError?,
        errorMessage: String?,
        brand: PayriffCardBrand?,
        isComplete: Bool
    ) {
        self.field = field
        self.isValid = isValid
        self.isEmpty = isEmpty
        self.error = error
        self.errorMessage = errorMessage
        self.brand = brand
        self.isComplete = isComplete
    }
}

/// The invalid fields of a form, in form order.
struct CardFieldIssues: Error, Sendable, Equatable {
    let issues: [PayriffCardFieldIssue]
}

/// The state and rules of the card form, independent of UIKit: formatting while typing,
/// validation, the visible-error timing, auto-advance and collecting the card for a payment
/// (CONTRACT §16.4). ``PayriffCardForm`` renders it.
struct CardFormModel {
    struct FieldState {
        var text = ""
        var focused = false
        /// The field lost focus at least once.
        var touched = false
    }

    /// The result of an edit: the text to show, the caret offset (UTF-16) and whether focus
    /// moves to the next field.
    struct Edit: Equatable {
        let text: String
        let caret: Int
        let advance: Bool
    }

    static let advanceOrder: [PayriffCardField] = [.number, .expiry, .cvv]

    /// The mounted fields, in form order.
    let fields: [PayriffCardField]
    var strings: CardStrings
    /// Whether a payment was attempted (the `submitted` of `visibleError`).
    private(set) var submitted = false
    private var states: [PayriffCardField: FieldState]
    /// The current date, for the expiry rule.
    var now: @Sendable () -> Date = { Date() }

    init(showsHolder: Bool, language: PayriffLanguage) {
        fields = showsHolder ? [.number, .expiry, .cvv, .holder] : [.number, .expiry, .cvv]
        strings = CardStrings(language: language)
        states = Dictionary(uniqueKeysWithValues: fields.map { ($0, FieldState()) })
    }

    func text(_ field: PayriffCardField) -> String {
        states[field]?.text ?? ""
    }

    func state(_ field: PayriffCardField) -> FieldState {
        states[field] ?? FieldState()
    }

    /// Applies an edit of the field's text (`range` in UTF-16 units) and reformats it, keeping the
    /// caret after the same number of digits. The holder is upper-cased, with the caret rule of
    /// ``holderCaret(_:from:to:)``. Returns `nil` when the edit is refused (an upper-cased holder
    /// name longer than 50 characters).
    mutating func edit(_ field: PayriffCardField, range: NSRange, replacement: String) -> Edit? {
        let current = text(field) as NSString
        let safeRange = NSRange(
            location: min(range.location, current.length),
            length: min(range.length, max(0, current.length - min(range.location, current.length)))
        )
        let proposed = current.replacingCharacters(in: safeRange, with: replacement)
        let inserting = !replacement.isEmpty
        let caretInProposed = safeRange.location + (replacement as NSString).length
        if field == .holder {
            let formatted = Self.format(field, proposed, inserting: inserting)
            guard formatted.utf16.count <= CardValidation.maxHolderLength else { return nil }
            states[field, default: FieldState()].text = formatted
            return Edit(text: formatted, caret: Self.holderCaret(caretInProposed, from: proposed, to: formatted), advance: false)
        }
        let formatted = Self.format(field, proposed, inserting: inserting)
        let proposedLength = (proposed as NSString).length
        let atEnd = caretInProposed >= proposedLength
        let caret: Int
        if atEnd {
            caret = (formatted as NSString).length
        } else {
            let before = (proposed as NSString).substring(to: caretInProposed)
            caret = Self.offset(afterDigits: CardValidation.digitsOnly(before).count, in: formatted)
        }
        states[field, default: FieldState()].text = formatted
        let caretAtEnd = caret >= (formatted as NSString).length
        let advance = inserting && caretAtEnd && isValid(field)
        return Edit(text: formatted, caret: caret, advance: advance)
    }

    /// Replaces the whole text (AutoFill and other edits that bypass the delegate, and every holder
    /// edit, which the system keyboard applies itself), formatted. The holder is upper-cased, then
    /// cut at 50 characters.
    mutating func setText(_ field: PayriffCardField, _ text: String) -> String {
        var formatted = Self.format(field, text, inserting: false)
        if field == .holder { formatted = String(formatted.utf16.prefix(CardValidation.maxHolderLength)) ?? formatted }
        states[field, default: FieldState()].text = formatted
        return formatted
    }

    /// Where the caret goes when the holder text `text` is replaced by its upper-cased `formatted`:
    /// it stays at `caret` (UTF-16) when the length did not change, else it goes to the end
    /// (`ß` → `SS`).
    static func holderCaret(_ caret: Int, from text: String, to formatted: String) -> Int {
        let length = (formatted as NSString).length
        return length == (text as NSString).length ? min(max(caret, 0), length) : length
    }

    mutating func setFocused(_ field: PayriffCardField, _ focused: Bool) {
        guard states[field] != nil else { return }
        if !focused, states[field]?.focused == true { states[field]?.touched = true }
        states[field]?.focused = focused
    }

    /// The next field of auto-advance: number → expiry → cvv.
    func nextField(after field: PayriffCardField) -> PayriffCardField? {
        guard let index = Self.advanceOrder.firstIndex(of: field), index + 1 < Self.advanceOrder.count else { return nil }
        let next = Self.advanceOrder[index + 1]
        return fields.contains(next) ? next : nil
    }

    static func format(_ field: PayriffCardField, _ text: String, inserting: Bool) -> String {
        switch field {
        case .number: return CardFormatting.formatNumber(text)
        case .expiry: return CardFormatting.formatExpiry(text, inserting: inserting)
        case .cvv: return CardFormatting.formatCvv(text)
        case .holder: return CardFormatting.formatHolder(text)
        }
    }

    /// The UTF-16 offset right after the `count`-th digit of `text`.
    private static func offset(afterDigits count: Int, in text: String) -> Int {
        var seen = 0
        var position = 0
        for scalar in text.unicodeScalars {
            if seen >= count { break }
            position += scalar.utf16.count
            if scalar.value >= 0x30, scalar.value <= 0x39 { seen += 1 }
        }
        return position
    }

    // MARK: - Validation

    func validation(_ field: PayriffCardField) -> (valid: Bool, empty: Bool, error: PayriffCardFieldError?, brand: PayriffCardBrand?) {
        let raw = text(field)
        switch field {
        case .number:
            let result = CardValidation.validateNumber(raw)
            return (result.valid, result.empty, result.errorCode, result.brand)
        case .expiry:
            let result = CardValidation.validateExpiry(raw, now: now())
            return (result.valid, result.empty, result.errorCode, nil)
        case .cvv:
            let result = CardValidation.validateCvv(raw)
            return (result.valid, result.empty, result.errorCode, nil)
        case .holder:
            let result = CardValidation.validateHolder(raw)
            return (result.valid, result.empty, result.errorCode, nil)
        }
    }

    func isValid(_ field: PayriffCardField) -> Bool {
        validation(field).valid
    }

    /// Whether every mounted field is valid.
    var isComplete: Bool {
        fields.allSatisfy(isValid)
    }

    /// The brand of the number typed so far.
    var brand: PayriffCardBrand? {
        validation(.number).brand
    }

    /// The error the customer should see in `field` now.
    func visibleError(_ field: PayriffCardField) -> PayriffCardFieldError? {
        let state = state(field)
        return CardValidation.visibleError(validation(field).error, focused: state.focused, touched: state.touched, submitted: submitted)
    }

    func change(_ field: PayriffCardField) -> PayriffCardFormChange {
        let result = validation(field)
        let shown = visibleError(field)
        return PayriffCardFormChange(
            field: field,
            isValid: result.valid,
            isEmpty: result.empty,
            error: shown,
            errorMessage: shown.map { strings.message(field, $0) },
            brand: field == .number ? result.brand : nil,
            isComplete: isComplete
        )
    }

    // MARK: - Payment

    /// Marks the form as submitted and returns the card, or the invalid fields in form order.
    mutating func collect() -> Result<CardDetails, CardFieldIssues> {
        submitted = true
        var issues: [PayriffCardFieldIssue] = []
        for field in fields {
            let result = validation(field)
            if !result.valid {
                let error = result.error ?? .invalid
                issues.append(PayriffCardFieldIssue(field: field, error: error, message: strings.message(field, error)))
            }
        }
        guard issues.isEmpty else { return .failure(CardFieldIssues(issues: issues)) }
        let number = CardValidation.validateNumber(text(.number))
        let expiry = CardValidation.validateExpiry(text(.expiry), now: now())
        let cvv = CardValidation.validateCvv(text(.cvv))
        let holder = fields.contains(.holder) ? CardValidation.validateHolder(text(.holder)).value : CardDetails.unknownHolder
        guard let date = expiry.value else {
            return .failure(CardFieldIssues(issues: [PayriffCardFieldIssue(field: .expiry, error: .invalid, message: strings.message(.expiry, .invalid))]))
        }
        return .success(CardDetails(
            pan: number.value,
            cardHolder: holder,
            expiryYear: date.expiryYear,
            expiryMonth: date.expiryMonth,
            cvv: cvv.value
        ))
    }

    /// Clears every value and the interaction state.
    mutating func clear() {
        submitted = false
        for field in fields {
            states[field] = FieldState(text: "", focused: states[field]?.focused ?? false, touched: false)
        }
    }
}

/// The model holds what the customer typed, so `print`, `dump` and the debugger never show it,
/// also when they reach it through the form (`dump(form)`) (CONTRACT §16.5).
extension CardFormModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "CardFormModel(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension CardFormModel.FieldState: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "FieldState(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
