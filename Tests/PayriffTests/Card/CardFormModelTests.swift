import Foundation
import Testing
@testable import Payriff

/// The card form's rules without UIKit (CONTRACT §16.4): formatting while typing, the caret,
/// auto-advance, visible errors, change events and collecting the card.
@Suite("Card form model")
struct CardFormModelTests {
    /// 2026-10-15, the date of `card_validation.json`.
    static let now: @Sendable () -> Date = {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 15, hour: 12).date!
    }

    static func model(showsHolder: Bool = false, language: PayriffLanguage = .en) -> CardFormModel {
        var model = CardFormModel(showsHolder: showsHolder, language: language)
        model.now = now
        return model
    }

    /// Types `text` one character at a time at the end of the field.
    @discardableResult
    static func type(_ text: String, into field: PayriffCardField, _ model: inout CardFormModel) -> CardFormModel.Edit? {
        var last: CardFormModel.Edit?
        for character in text {
            let length = (model.text(field) as NSString).length
            last = model.edit(field, range: NSRange(location: length, length: 0), replacement: String(character))
        }
        return last
    }

    @Test("Typing the number formats in groups of 4, caps it at the brand's length and advances when valid")
    func typingNumber() {
        var model = Self.model()
        let partial = Self.type("42424", into: .number, &model)
        #expect(partial == CardFormModel.Edit(text: "4242 4", caret: 6, advance: false))
        let full = Self.type("24242424242", into: .number, &model)
        #expect(full == CardFormModel.Edit(text: "4242 4242 4242 4242", caret: 19, advance: true))
        #expect(model.brand == .visa)
        // Mastercard stops at 16 digits.
        var mastercard = Self.model()
        Self.type("55555555555544449", into: .number, &mastercard)
        #expect(mastercard.text(.number) == "5555 5555 5555 4444")
        // So does Visa (CONTRACT §16.4: at most 16 digits; the web SDK allows 19), typed or pasted.
        var visa = Self.model()
        Self.type("4242424242424242424", into: .number, &visa)
        #expect(visa.text(.number) == "4242 4242 4242 4242")
        #expect(visa.isValid(.number))
        var pasted = Self.model()
        let paste = pasted.edit(.number, range: NSRange(location: 0, length: 0), replacement: "4111 1111 1111 1111 111")
        #expect(paste?.text == "4111 1111 1111 1111")
        #expect(CardValidation.validateNumber("4111111111111111111").errorCode == .invalid, "19 digits are never valid")
        // An invalid checksum never advances.
        var invalid = Self.model()
        #expect(Self.type("4242424242424241", into: .number, &invalid)?.advance == false)
    }

    @Test("Paste keeps the caret after the same digits; deleting a separator works like the web form")
    func pasteAndDelete() {
        var model = Self.model()
        let paste = model.edit(.number, range: NSRange(location: 0, length: 0), replacement: "4242-4242-4242-4242")
        #expect(paste == CardFormModel.Edit(text: "4242 4242 4242 4242", caret: 19, advance: true))
        // A digit inserted in the middle keeps the caret after it.
        var middle = Self.model()
        Self.type("42424242", into: .number, &middle)
        let inserted = middle.edit(.number, range: NSRange(location: 2, length: 0), replacement: "1")
        #expect(inserted?.text == "4214 2424 2")
        #expect(inserted?.caret == 3)
        #expect(inserted?.advance == false)

        var expiry = Self.model()
        #expect(Self.type("4", into: .expiry, &expiry)?.text == "04 / ")
        #expect(Self.type("1", into: .expiry, &expiry)?.text == "04 / 1")
        // Backspace over the trailing separator removes it in one step.
        var separator = Self.model()
        Self.type("12", into: .expiry, &separator)
        #expect(separator.text(.expiry) == "12 / ")
        let deleted = separator.edit(.expiry, range: NSRange(location: 4, length: 1), replacement: "")
        #expect(deleted?.text == "12")
    }

    @Test("Auto-advance: number → expiry → cvv, only fields that exist; the holder never advances")
    func autoAdvance() {
        var model = Self.model(showsHolder: true)
        #expect(model.nextField(after: .number) == .expiry)
        #expect(model.nextField(after: .expiry) == .cvv)
        #expect(model.nextField(after: .cvv) == nil)
        #expect(model.nextField(after: .holder) == nil)
        #expect(Self.type("0728", into: .expiry, &model)?.advance == true)
        #expect(Self.type("12", into: .cvv, &model)?.advance == false)
        #expect(Self.type("3", into: .cvv, &model)?.advance == true)
        #expect(Self.type("AB", into: .holder, &model)?.advance == false)
        #expect(model.text(.cvv) == "123")
        // At most 3 CVV digits and 50 holder characters.
        #expect(Self.type("4", into: .cvv, &model)?.text == "123")
        var holder = Self.model(showsHolder: true)
        Self.type(String(repeating: "x", count: 50), into: .holder, &holder)
        #expect(holder.edit(.holder, range: NSRange(location: 50, length: 0), replacement: "y") == nil)
    }

    @Test("Visible errors follow focus, blur and submit; change events carry no values")
    func visibleErrorsAndChanges() {
        var model = Self.model()
        model.setFocused(.number, true)
        Self.type("4242", into: .number, &model)
        #expect(model.visibleError(.number) == nil, "incomplete is hidden while typing")
        model.setFocused(.number, false)
        #expect(model.visibleError(.number) == .incomplete, "and shown after blur")
        #expect(model.visibleError(.expiry) == nil, "required only after submit")
        var unsupported = Self.model()
        Self.type("29", into: .number, &unsupported)
        #expect(unsupported.visibleError(.number) == .unsupported, "definite errors show at once")
        let change = unsupported.change(.number)
        #expect(change == PayriffCardFormChange(
            field: .number,
            isValid: false,
            isEmpty: false,
            error: .unsupported,
            errorMessage: "This card type is not supported",
            brand: nil,
            isComplete: false
        ))
    }

    @Test("collect(): all errors in form order with localized texts; afterwards required errors show")
    func collectInvalid() throws {
        var model = Self.model(showsHolder: true, language: .az)
        Self.type("4242", into: .number, &model)
        Self.type("0926", into: .expiry, &model)
        let failure = try #require(model.collect().failureValue)
        #expect(failure.issues.map(\.field) == [.number, .expiry, .cvv, .holder])
        #expect(failure.issues.map(\.error) == [.incomplete, .expired, .required, .required])
        #expect(failure.issues[0].message == "Kart nömrəsi tam deyil")
        #expect(failure.issues[1].message == "Kartın müddəti bitib")
        #expect(model.visibleError(.cvv) == .required)
        let error = Payriff.validationFailed(failure.issues)
        #expect(error.code == .validationFailed)
        #expect(error.fields == failure.issues)
        #expect(!error.isFatal)
        #expect(!error.message.contains("4242"))
    }

    @Test("collect(): the card with 4-digit year, 2-digit month, normalized holder, or Unknown without a holder field")
    func collectValid() throws {
        var model = Self.model(showsHolder: true)
        Self.type("5555555555554444", into: .number, &model)
        Self.type("728", into: .expiry, &model)
        Self.type("783", into: .cvv, &model)
        _ = model.edit(.holder, range: NSRange(location: 0, length: 0), replacement: "  Əli   Həsənov ")
        let card = try model.collect().get()
        #expect(card.pan == "5555555555554444")
        #expect(card.expiryMonth == "07")
        #expect(card.expiryYear == "2028")
        #expect(card.cvv == "783")
        #expect(card.cardHolder == "ƏLI HƏSƏNOV")
        #expect(!"\(card)".contains("5555") && !String(reflecting: card).contains("783"))

        var noHolder = Self.model()
        Self.type("4111111111111111", into: .number, &noHolder)
        Self.type("1230", into: .expiry, &noHolder)
        Self.type("123", into: .cvv, &noHolder)
        #expect(noHolder.isComplete)
        #expect(try noHolder.collect().get().cardHolder == "Unknown")

        noHolder.clear()
        #expect(noHolder.text(.number).isEmpty && noHolder.text(.cvv).isEmpty)
        #expect(!noHolder.isComplete)
        #expect(noHolder.visibleError(.number) == nil, "clear() also resets the submitted state")
    }

    @Test("The holder is upper-cased on every edit: the caret stays unless the length changes; the cap counts the upper-cased name")
    func holderUpperCase() {
        var model = Self.model(showsHolder: true)
        Self.type("maria johnson", into: .holder, &model)
        #expect(model.text(.holder) == "MARIA JOHNSON")
        // An edit in the middle keeps the caret after it.
        let middle = model.edit(.holder, range: NSRange(location: 5, length: 0), replacement: "a")
        #expect(middle == CardFormModel.Edit(text: "MARIAA JOHNSON", caret: 6, advance: false))
        // ß → SS changes the length: the caret goes to the end.
        let sharp = model.edit(.holder, range: NSRange(location: 0, length: 0), replacement: "ß")
        #expect(sharp == CardFormModel.Edit(text: "SSMARIAA JOHNSON", caret: 16, advance: false))
        // The rule the form applies after the system keyboard's own edits.
        #expect(CardFormModel.holderCaret(2, from: "abc", to: "ABC") == 2)
        #expect(CardFormModel.holderCaret(1, from: "ßa", to: "SSA") == 3)
        // 49 characters and an ß would be 51 upper-cased: refused; AutoFill is cut at 50.
        var cap = Self.model(showsHolder: true)
        Self.type(String(repeating: "a", count: 49), into: .holder, &cap)
        #expect(cap.edit(.holder, range: NSRange(location: 49, length: 0), replacement: "ß") == nil)
        #expect(cap.setText(.holder, String(repeating: "ß", count: 26)) == String(repeating: "S", count: 50))
    }

    @Test("setText formats edits that bypass the delegate (AutoFill)")
    func setText() {
        var model = Self.model()
        #expect(model.setText(.number, "4111111111111111") == "4111 1111 1111 1111")
        #expect(model.setText(.expiry, "12/30") == "12 / 30")
        #expect(model.setText(.cvv, "12345") == "123")
    }
}
