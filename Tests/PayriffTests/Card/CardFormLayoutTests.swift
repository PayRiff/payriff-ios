import Foundation
import Testing
@testable import Payriff

/// The card form's layout rules without UIKit (CONTRACT §16.4 "Layout and appearance"): the
/// sections of the grouped and the stacked layout, the one error line per section and the
/// outline colour of each section.
@Suite("Card form layout")
struct CardFormLayoutTests {
    typealias Model = CardFormModelTests

    @Test("Grouped (the default): the holder section first when shown, then one card box with number, then expiry | CVC")
    func groupedSections() {
        #expect(PayriffCardFormLayout.allCases == [.grouped, .stacked])
        let withHolder = PayriffCardFormLayout.grouped.rows(showsHolder: true)
        #expect(withHolder == [
            [CardFormSection(title: .field(.holder), fields: [.holder])],
            [CardFormSection(title: .cardInformation, fields: [.number, .expiry, .cvv])],
        ])
        #expect(PayriffCardFormLayout.grouped.rows(showsHolder: false) == [[.cardInformation]])
        #expect(PayriffCardFormLayout.grouped.visualOrder(showsHolder: true) == [.holder, .number, .expiry, .cvv])
    }

    @Test("Stacked: every field in its own section with its own label; number, expiry | CVV, then the holder")
    func stackedSections() {
        let rows = PayriffCardFormLayout.stacked.rows(showsHolder: true)
        #expect(rows == [
            [.single(.number)],
            [.single(.expiry), .single(.cvv)],
            [.single(.holder)],
        ])
        for section in rows.joined() {
            #expect(section.title == .field(section.fields[0]))
            #expect(section.fields.count == 1)
        }
        #expect(PayriffCardFormLayout.stacked.rows(showsHolder: false) == [[.single(.number)], [.single(.expiry), .single(.cvv)]])
        #expect(PayriffCardFormLayout.stacked.visualOrder(showsHolder: true) == [.number, .expiry, .cvv, .holder])
    }

    @Test("One error line per section: the holder's own error; under the card box the first of number → expiry → CVC")
    func errorLines() {
        var model = Model.model(showsHolder: true)
        let holder = CardFormSection.single(.holder)
        let card = CardFormSection.cardInformation
        #expect(model.sectionError(card) == nil, "required shows only after submit")
        #expect(model.sectionError(holder) == nil)

        _ = model.collect()
        #expect(model.sectionError(card) == PayriffCardFieldIssue(field: .number, error: .required, message: "Enter your card number"))
        #expect(model.sectionError(holder) == PayriffCardFieldIssue(field: .holder, error: .required, message: "Enter the cardholder name"))

        Model.type("4242424242424242", into: .number, &model)
        #expect(model.sectionError(card)?.field == .expiry, "the number is valid: the expiry's error is next")
        #expect(model.sectionError(card)?.message == "Enter the expiry date")
        Model.type("1230", into: .expiry, &model)
        #expect(model.sectionError(card) == PayriffCardFieldIssue(field: .cvv, error: .required, message: "Enter the CVV"))
        Model.type("123", into: .cvv, &model)
        #expect(model.sectionError(card) == nil)
        #expect(model.sectionError(holder)?.field == .holder, "the holder's error stays under the holder")

        // A definite error later in the box does not hide an earlier field's error.
        var both = Model.model()
        Model.type("29", into: .number, &both)
        Model.type("1320", into: .expiry, &both)
        #expect(both.visibleError(.number) == .unsupported)
        #expect(both.visibleError(.expiry) == .invalid, "month 13")
        #expect(both.sectionError(card)?.field == .number)
        #expect(both.sectionError(card)?.message == "This card type is not supported")

        // The texts follow the form's language.
        var russian = Model.model(showsHolder: true, language: .ru)
        _ = russian.collect()
        #expect(russian.sectionError(card)?.message == "Введите номер карты")

        // Stacked: each field's section shows only its own error.
        var stacked = Model.model(showsHolder: true)
        _ = stacked.collect()
        let errors = PayriffCardFormLayout.stacked.rows(showsHolder: true).joined().map { stacked.sectionError($0)?.field }
        #expect(errors == [.number, .expiry, .cvv, .holder])
    }

    @Test("Outline: the error colour while the section shows an error, else the focus colour while one of its fields has focus")
    func outlines() {
        var model = Model.model(showsHolder: true)
        let holder = CardFormSection.single(.holder)
        let card = CardFormSection.cardInformation
        #expect(model.outline(card) == .normal)
        #expect(model.outline(holder) == .normal)

        model.setFocused(.expiry, true)
        #expect(model.outline(card) == .focused, "any field of the box focuses the box")
        #expect(model.outline(holder) == .normal)
        Model.type("1", into: .expiry, &model)
        #expect(model.outline(card) == .focused, "incomplete is not shown while typing")
        model.setFocused(.expiry, false)
        #expect(model.outline(card) == .error, "incomplete shows after blur")
        model.setFocused(.cvv, true)
        #expect(model.outline(card) == .error, "the error wins over focus")
        Model.type("230", into: .expiry, &model)
        #expect(model.text(.expiry) == "12 / 30")
        #expect(model.outline(card) == .focused, "fixed: back to focus")
        model.setFocused(.cvv, false)
        #expect(model.outline(card) == .normal)

        model.setFocused(.holder, true)
        Model.type("A<", into: .holder, &model)
        #expect(model.visibleError(.holder) == .invalid)
        #expect(model.outline(holder) == .error, "a definite error shows at once, also with focus")
        #expect(model.outline(card) == .normal, "the other section is not affected")

        // A form without a holder: a holder section has nothing to show.
        let noHolder = Model.model()
        #expect(noHolder.sectionError(holder) == nil)
        #expect(noHolder.outline(holder) == .normal)
    }
}
