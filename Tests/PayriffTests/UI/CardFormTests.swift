#if canImport(UIKit) && canImport(WebKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import Payriff

/// The UIKit card form and the 3DS UI pieces (CONTRACT §16.4, §16.5, §16.8).
@MainActor
@Suite("Card form (UIKit)", .serialized)
struct CardFormTests {
    @Test("Input security: keyboards, AutoFill hints only for number/expiry/holder, masked CVV, no autocorrection")
    func inputTraits() throws {
        let form = PayriffCardForm(showsHolder: true, language: .en)
        let number = try #require(form.textField(for: .number) as? CardTextField)
        let expiry = try #require(form.textField(for: .expiry) as? CardTextField)
        let cvv = try #require(form.textField(for: .cvv) as? CardTextField)
        let holder = try #require(form.textField(for: .holder) as? CardTextField)
        for field in [number, expiry, cvv, holder] {
            #expect(field.autocorrectionType == .no)
            #expect(field.spellCheckingType == .no)
            #expect(field.smartQuotesType == .no)
            #expect(field.smartDashesType == .no)
            #expect(field.smartInsertDeleteType == .no)
            if #available(iOS 17.0, *) {
                #expect(field.inlinePredictionType == .no)
            }
        }
        #expect(number.keyboardType == .numberPad && expiry.keyboardType == .numberPad && cvv.keyboardType == .numberPad)
        #expect(number.textContentType == .creditCardNumber)
        if #available(iOS 17.0, *) {
            #expect(expiry.textContentType == .creditCardExpiration)
            #expect(holder.textContentType == .creditCardName)
        }
        #expect(cvv.textContentType == nil)
        // The holder's keyboard opens in caps mode (CONTRACT §16.4).
        #expect(holder.autocapitalizationType == .allCharacters)
        #expect([number, expiry, cvv].allSatisfy { $0.autocapitalizationType == UITextAutocapitalizationType.none })
        #expect(cvv.isSecureTextEntry)
        #expect(!number.isSecureTextEntry && !expiry.isSecureTextEntry && !holder.isSecureTextEntry)
        #expect(number.textDragInteraction?.isEnabled == false)
        #expect(cvv.textDragInteraction?.isEnabled == false)
        // Labels and placeholders from card_strings.json (the hosted page's placeholders).
        #expect(number.placeholder == "1234 1234 1234 1234")
        #expect(expiry.placeholder == "MM / YY")
        #expect(cvv.placeholder == "CVC")
        #expect(holder.placeholder == "Card holder")
        #expect(cvv.accessibilityLabel == "Security code")
    }

    // MARK: - Layout and appearance (CONTRACT §16.4)

    /// Lays `form` out at `width` with its own height, as `PayriffCardFormView` sizes it.
    private func layOut(_ form: PayriffCardForm, width: CGFloat = 390) {
        let height = form.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        form.frame = CGRect(x: 0, y: 0, width: width, height: height)
        form.layoutIfNeeded()
    }

    private func frame(_ view: UIView, in form: PayriffCardForm) -> CGRect {
        view.convert(view.bounds, to: form)
    }

    /// Types `text` into `field` as one edit, the way the delegate receives a paste.
    private func type(_ text: String, into field: PayriffCardField, of form: PayriffCardForm) throws {
        let textField = try #require(form.textField(for: field))
        let length = (textField.text ?? "").utf16.count
        _ = form.textField(textField, shouldChangeCharactersIn: NSRange(location: length, length: 0), replacementString: text)
    }

    /// `color` as `0xRRGGBB` in the light or dark appearance.
    private func rgb(_ color: UIColor?, _ appearance: UIUserInterfaceStyle = .light) -> UInt32? {
        guard let color else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance)).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
    }

    /// The alpha of `color` in the light appearance.
    private func alpha(_ color: UIColor?) -> CGFloat? {
        var white: CGFloat = 0, alpha: CGFloat = 0
        guard let color, color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getWhite(&white, alpha: &alpha) else { return nil }
        return alpha
    }

    @Test("PayriffCardFormStyle defaults are the hosted page's (CONTRACT §16.4, §16.14), light and dark")
    func styleDefaults() throws {
        let style = PayriffCardFormStyle()
        #expect(style == .default)
        #expect(style.layout == .grouped)
        #expect(style.labelTextStyle.font.pointSize == 14)
        #expect(style.labelTextStyle.font.fontName == UIFont.systemFont(ofSize: 14, weight: .semibold).fontName)
        #expect(style.labelTextStyle.font.fontName != UIFont.systemFont(ofSize: 14, weight: .regular).fontName)
        #expect(style.inputTextStyle.font.pointSize == 14)
        #expect(style.inputTextStyle.font.fontName == UIFont.systemFont(ofSize: 14, weight: .regular).fontName)
        #expect(style.errorTextStyle.font.pointSize == 13)
        #expect(style.labelTextStyle.color == nil && style.inputTextStyle.color == nil && style.errorTextStyle.color == nil)
        #expect(rgb(style.placeholderColor) == 0x76787F)
        #expect(rgb(style.placeholderColor, .dark) == 0x5F6167)
        #expect(rgb(style.errorColor) == 0xEC4D3D)
        #expect(rgb(style.errorColor, .dark) == 0xEC5545)
        #expect(alpha(style.fieldBackgroundColor) == 0, "transparent: the fields show the page background")
        #expect(rgb(style.borderColor, .light) == 0xECEEF0)
        #expect(rgb(style.borderColor, .dark) == 0x3F4145)
        #expect(rgb(style.focusedBorderColor) == 0x4DBDC6, "Payriff's brand colour")
        #expect(rgb(style.focusedBorderColor, .dark) == 0x4DBDC6)
        #expect(style.showLabels)
        #expect(style.holderLabel == nil && style.cardLabel == nil)
        #expect(style.borderWidth == 1)
        #expect(style.cornerRadius == 12)
        #expect(style.holderHeight == 46)
        #expect(style.rowHeight == 40)
        #expect(style.horizontalPadding == 14)
        #expect(style.labelSpacing == 10)
        #expect(style.sectionSpacing == 16)

        // The colours a nil text colour stands for: titles #34363A, typed text #4D4F54.
        let form = PayriffCardForm(language: .en)
        #expect(form.style == style, "the form's default")
        let title = try #require(form.sectionViews.first?.titleLabel)
        #expect(rgb(title.textColor) == 0x34363A && rgb(title.textColor, .dark) == 0xE1E4E8)
        let number = try #require(form.textField(for: .number))
        #expect(rgb(number.textColor) == 0x4D4F54 && rgb(number.textColor, .dark) == 0x8E8E93)
        #expect(rgb(number.tintColor) == 0x4DBDC6, "the caret")
        let placeholder = number.attributedPlaceholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(rgb(placeholder) == 0x76787F)
        #expect(number.font?.pointSize == UIFontMetrics(forTextStyle: .body).scaledValue(for: 14), "placeholders share the 14 pt input font")
    }

    @Test("The default form is pay.payriff.com's: the holder is shown, first, then the card box (CONTRACT §16.4)")
    func holderShownByDefault() throws {
        #expect(PayriffCardForm().showsHolder)
        // Only the language is set, so that the titles are known.
        let form = PayriffCardForm(language: .en)
        #expect(form.showsHolder)
        #expect(form.textField(for: .holder) != nil)
        #expect(form.sectionViews.map(\.section.fields) == [[.holder], [.number, .expiry, .cvv]])
        #expect(form.sectionViews.map(\.titleLabel.text) == ["Card holder", "Card information"])
        // The holder is validated with the other fields: an empty form lists it.
        let failure = try #require(form.collectForPayment().failureValue)
        #expect(failure.issues.map(\.field) == [.number, .expiry, .cvv, .holder])
    }

    @Test("Grouped (the default) mirrors pay.payriff.com: 'Card holder', then one 'Card information' box: number with the brand mark, then expiry | CVC")
    func groupedLayout() throws {
        let form = PayriffCardForm(showsHolder: true, language: .en)
        #expect(form.sectionViews.map(\.section.fields) == [[.holder], [.number, .expiry, .cvv]])
        #expect(form.sectionViews.map(\.titleLabel.text) == ["Card holder", "Card information"])
        layOut(form)
        let holder = try #require(form.sectionView(containing: .holder))
        let card = try #require(form.sectionView(containing: .number))
        let number = try #require(form.textField(for: .number))
        let expiry = try #require(form.textField(for: .expiry))
        let cvv = try #require(form.textField(for: .cvv))
        let mark = try #require(form.brandMarkView)

        // The holder section, then the card section; each title above its box (CONTRACT §16.14:
        // 10 between a title and its box, 16 between the sections).
        #expect(frame(holder.box, in: form).maxY <= frame(card.titleLabel, in: form).minY)
        #expect(abs(frame(card.titleLabel, in: form).minY - frame(holder.box, in: form).maxY - 16) < 0.5, "sectionSpacing")
        #expect(abs(frame(holder.box, in: form).minY - frame(holder.titleLabel, in: form).maxY - 10) < 0.5, "labelSpacing")
        #expect(abs(frame(card.box, in: form).minY - frame(card.titleLabel, in: form).maxY - 10) < 0.5, "labelSpacing")
        // A 46-point holder field; two 40-point rows that share the line between them.
        #expect(abs(holder.box.bounds.height - 46) < 0.5, "holderHeight, the outline included")
        #expect(abs(card.box.bounds.height - (40 + 40 - 1)) < 0.5, "rowHeight, the rows sharing their line")
        #expect(holder.errorLabel.isHidden && card.errorLabel.isHidden, "no error, no error line")
        #expect(abs(frame(card.box, in: form).maxY - form.bounds.height) < 0.5)

        // One box: the number row on top with the brand mark trailing, then expiry | CVC in equal parts.
        #expect(card.cells.map(\.textField.field) == [.number, .expiry, .cvv])
        #expect(zip(card.cells.map(\.textField), [number, expiry, cvv]).allSatisfy { $0 === $1 }, "the form's own text fields")
        let box = frame(card.box, in: form)
        let numberRow = frame(card.cells[0], in: form)
        let expiryCell = frame(card.cells[1], in: form)
        let cvvCell = frame(card.cells[2], in: form)
        #expect(numberRow.maxY <= expiryCell.minY)
        #expect(abs(expiryCell.minY - cvvCell.minY) < 0.5, "one row")
        #expect(expiryCell.maxX <= cvvCell.minX)
        #expect(abs(expiryCell.width - cvvCell.width) < 0.5, "50/50")
        #expect(abs(numberRow.width - box.width) < 0.5)
        #expect(card.cells.allSatisfy { abs($0.bounds.height - 39) < 0.5 }, "rowHeight less the shared line")
        #expect(abs(expiryCell.minY - numberRow.maxY - 1) < 0.5, "one line between the rows")
        #expect(abs(frame(number, in: form).minX - box.minX - 14) < 0.5, "horizontalPadding")
        #expect(abs(frame(cvv, in: form).minX - cvvCell.minX - 14) < 0.5)
        let markFrame = frame(mark, in: form)
        #expect(markFrame.size == CGSize(width: 36, height: 24))
        #expect(markFrame.minX >= frame(number, in: form).maxX)
        #expect(abs(box.maxX - markFrame.maxX - 14) < 0.5, "on the trailing side")
        #expect(abs(markFrame.midY - numberRow.midY) < 0.5)
        #expect(mark.isDescendant(of: card.cells[0]))
        // The rows and cells are separated by 1-point lines in the border colour.
        #expect(card.dividers.count == 2)
        for divider in card.dividers {
            #expect(divider.backgroundColor == form.style.borderColor)
            #expect(min(divider.bounds.width, divider.bounds.height) == 1)
        }
        #expect(abs(card.dividers[0].bounds.width - box.width) < 0.5, "between the rows, edge to edge")
        #expect(abs(card.dividers[1].bounds.height - expiryCell.height) < 0.5, "between expiry and CVC")
        // Rounded outer corners only: one clipped box with the outline.
        #expect(card.box.clipsToBounds)
        #expect(card.box.layer.cornerRadius == 12)
        #expect(card.box.layer.borderWidth == 1)
        #expect(card.box.backgroundColor == form.style.fieldBackgroundColor)
        #expect(card.box.borderUIColor == form.style.borderColor)
        #expect(holder.box.layer.cornerRadius == 12)

        // The fields carry label.* for VoiceOver; the titles are not read twice.
        #expect(number.accessibilityLabel == "Card number")
        #expect(expiry.accessibilityLabel == "Expiry date")
        #expect(cvv.accessibilityLabel == "Security code")
        #expect(form.textField(for: .holder)?.accessibilityLabel == "Card holder")
        #expect(!card.titleLabel.isAccessibilityElement && !holder.titleLabel.isAccessibilityElement)

        // Other languages, and a form without a holder: only the card box.
        form.language = .az
        #expect(form.sectionViews.map(\.titleLabel.text) == ["Kart sahibinin adı", "Kart məlumatları"])
        form.language = .ru
        #expect(form.sectionViews.map(\.titleLabel.text) == ["Владелец карты", "Информация о карте"])
        #expect(number.placeholder == "1234 1234 1234 1234")
        let noHolder = PayriffCardForm(showsHolder: false, language: .en)
        #expect(noHolder.sectionViews.map(\.section.fields) == [[.number, .expiry, .cvv]])
        #expect(noHolder.sectionViews.map(\.titleLabel.text) == ["Card information"])
    }

    @Test("One error line under each section: the holder's error; under the box the first visible of number → expiry → CVC")
    func errorLines() throws {
        let form = PayriffCardForm(showsHolder: true, language: .en)
        layOut(form)
        let before = form.bounds.height
        let holder = try #require(form.sectionView(containing: .holder))
        let card = try #require(form.sectionView(containing: .number))
        let holderField = try #require(form.textField(for: .holder))

        _ = form.collectForPayment()
        #expect(holder.errorLabel.text == "Enter the cardholder name")
        #expect(card.errorLabel.text == "Enter your card number")
        #expect(!holder.errorLabel.isHidden && !card.errorLabel.isHidden)
        #expect(card.errorLabel.isAccessibilityElement)
        #expect(card.errorLabel.textColor == form.style.errorColor)
        #expect(form.textField(for: .expiry)?.accessibilityHint == "Enter the expiry date", "each field keeps its own error for VoiceOver")
        layOut(form)
        #expect(form.bounds.height > before, "the error lines take space only when shown")
        #expect(frame(card.errorLabel, in: form).minY >= frame(card.box, in: form).maxY)

        try type("4242424242424242", into: .number, of: form)
        #expect(card.errorLabel.text == "Enter the expiry date")
        try type("1230", into: .expiry, of: form)
        #expect(card.errorLabel.text == "Enter the CVV")
        try type("123", into: .cvv, of: form)
        #expect(card.errorLabel.isHidden)
        #expect(!card.errorLabel.isAccessibilityElement)
        #expect(holder.errorLabel.text == "Enter the cardholder name", "the holder's error stays under the holder")

        // The system keyboard edits the holder; the edit event upper-cases and validates it.
        holderField.text = "jane doe"
        holderField.sendActions(for: .editingChanged)
        #expect(holderField.text == "JANE DOE")
        #expect(holder.errorLabel.isHidden)
        #expect(form.isComplete)

        // A definite error shows at once; an earlier field's error wins.
        let definite = PayriffCardForm(language: .en)
        try type("29", into: .number, of: definite)
        try type("1320", into: .expiry, of: definite)
        #expect(definite.sectionView(containing: .number)?.errorLabel.text == "This card type is not supported")
    }

    @Test("Outline: the error colour while a section shows an error, else the focus colour while one of its fields is edited")
    func outlineColours() throws {
        let focus = UIColor(red: 0.5, green: 0.1, blue: 0.9, alpha: 1)
        let form = PayriffCardForm(showsHolder: true, language: .en, style: PayriffCardFormStyle(focusedBorderColor: focus))
        let holder = try #require(form.sectionView(containing: .holder))
        let card = try #require(form.sectionView(containing: .number))
        let expiry = try #require(form.textField(for: .expiry))
        #expect(card.outline == .normal)
        #expect(card.box.borderUIColor == form.style.borderColor)

        expiry.sendActions(for: .editingDidBegin)
        #expect(card.outline == .focused, "any field of the box focuses the whole box")
        #expect(card.box.borderUIColor == focus)
        #expect(card.box.layer.borderColor == focus.cgColor)
        #expect(holder.box.borderUIColor == form.style.borderColor)
        #expect(expiry.tintColor == focus, "the caret too")

        try type("4242424242424241", into: .number, of: form)
        #expect(card.outline == .error, "a definite error wins over focus")
        #expect(card.box.borderUIColor == form.style.errorColor)
        #expect(holder.box.borderUIColor == form.style.borderColor, "only the section with the error")
        form.textField(for: .number)?.text = ""
        form.textField(for: .number)?.sendActions(for: .editingChanged)
        #expect(card.outline == .focused)
        expiry.sendActions(for: .editingDidEnd)
        #expect(card.outline == .normal, "empty fields show no error before Pay")
        #expect(card.box.borderUIColor == form.style.borderColor)

        _ = form.collectForPayment()
        #expect(holder.outline == .error && card.outline == .error)
        #expect(holder.box.borderUIColor == form.style.errorColor)

        // The default focus colour is Payriff's brand colour (CONTRACT §16.14).
        let branded = PayriffCardForm(language: .en)
        branded.tintColor = UIColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        branded.textField(for: .number)?.sendActions(for: .editingDidBegin)
        #expect(rgb(branded.sectionView(containing: .number)?.box.borderUIColor) == 0x4DBDC6)

        // A nil focusedBorderColor is the tint colour: the app's accent.
        let accent = UIColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        let plain = PayriffCardForm(language: .en, style: PayriffCardFormStyle(focusedBorderColor: nil))
        plain.tintColor = accent
        plain.textField(for: .cvv)?.sendActions(for: .editingDidBegin)
        #expect(plain.sectionView(containing: .cvv)?.box.borderUIColor == accent)
    }

    @Test("A custom style takes effect at once and keeps what was typed")
    func customStyle() throws {
        let form = PayriffCardForm(showsHolder: true, language: .en)
        try type("4242424242424242", into: .number, of: form)
        layOut(form)
        let defaultTitleSize = try #require(form.sectionViews.first?.titleLabel.font.pointSize)
        let defaultInputSize = try #require(form.textField(for: .number)?.font?.pointSize)

        var custom = PayriffCardFormStyle()
        custom.labelTextStyle = .init(size: 18, weight: .bold, color: UIColor(red: 0.3, green: 0.1, blue: 0.6, alpha: 1))
        custom.inputTextStyle = .init(size: 20, color: UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        custom.placeholderColor = UIColor(red: 0.6, green: 0.6, blue: 0.7, alpha: 1)
        custom.errorTextStyle = .init(size: 12, color: UIColor(red: 0.7, green: 0, blue: 0.2, alpha: 1))
        custom.holderLabel = "Name on card"
        custom.cardLabel = "Card details"
        custom.fieldBackgroundColor = UIColor(red: 0.95, green: 0.96, blue: 1, alpha: 1)
        custom.borderColor = UIColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        custom.errorColor = UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        custom.borderWidth = 2
        custom.cornerRadius = 20
        custom.holderHeight = 64
        custom.rowHeight = 60
        custom.horizontalPadding = 20
        custom.labelSpacing = 4
        custom.sectionSpacing = 32
        form.style = custom
        layOut(form)

        let holder = try #require(form.sectionView(containing: .holder))
        let card = try #require(form.sectionView(containing: .number))
        let number = try #require(form.textField(for: .number))
        #expect(number.text == "4242 4242 4242 4242", "the values stay")
        #expect(form.brandMarkView?.visibleMark == .visa)
        #expect(form.sectionViews.map(\.titleLabel.text) == ["Name on card", "Card details"])
        #expect(form.textField(for: .holder)?.accessibilityLabel == "Name on card")
        #expect(number.accessibilityLabel == "Card number")
        for section in [holder, card] {
            #expect(section.box.layer.cornerRadius == 20)
            #expect(section.box.layer.borderWidth == 2)
            #expect(section.box.borderUIColor == custom.borderColor)
            #expect(section.box.backgroundColor == custom.fieldBackgroundColor)
            #expect(section.titleLabel.textColor == custom.labelTextStyle.color)
            #expect(section.titleLabel.font.pointSize > defaultTitleSize)
        }
        #expect(holder.cells.allSatisfy { $0.bounds.height >= 64 }, "holderHeight")
        #expect(card.cells.allSatisfy { $0.bounds.height >= 59 }, "rowHeight less the shared line")
        #expect(abs(card.box.bounds.height - (60 + 60 - 1)) < 0.5)
        #expect(card.dividers.allSatisfy { $0.backgroundColor == custom.borderColor })
        #expect(number.textColor == custom.inputTextStyle.color)
        #expect((number.font?.pointSize ?? 0) > defaultInputSize)
        #expect(number.attributedPlaceholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == custom.placeholderColor)
        #expect(abs(frame(number, in: form).minX - frame(card.box, in: form).minX - 20) < 0.5)
        #expect(abs(frame(card.titleLabel, in: form).minY - frame(holder.box, in: form).maxY - 32) < 0.5)
        #expect(abs(frame(card.box, in: form).minY - frame(card.titleLabel, in: form).maxY - 4) < 0.5)
        _ = form.collectForPayment()
        #expect(card.errorLabel.text == "Enter the expiry date")
        #expect(card.errorLabel.textColor == custom.errorTextStyle.color)
        #expect(card.box.borderUIColor == custom.errorColor)

        // Without titles the fields keep their VoiceOver labels.
        custom.showLabels = false
        form.style = custom
        layOut(form)
        #expect(form.sectionViews.allSatisfy { $0.titleLabel.isHidden })
        #expect(abs(frame(card.box, in: form).minY - frame(holder.errorLabel, in: form).maxY - 32) < 0.5)
        #expect(number.accessibilityLabel == "Card number")

        form.style = PayriffCardFormStyle()
        #expect(card.box.layer.cornerRadius == 12)
        #expect(form.sectionViews.map(\.titleLabel.text) == ["Card holder", "Card information"])
        #expect(!card.titleLabel.isHidden)
    }

    @Test("PayriffCardFormView gives the form its style and change handler; without a style the form keeps its own")
    func swiftUIStyle() {
        var style = PayriffCardFormStyle()
        style.cornerRadius = 24
        style.layout = .stacked
        let form = PayriffCardForm(showsHolder: false, language: .en)
        var changes = 0
        PayriffCardFormView(form, style: style) { _ in changes += 1 }.configure(form)
        #expect(form.style == style)
        #expect(form.sectionViews.map(\.section.fields) == [[.number], [.expiry], [.cvv]])
        #expect(form.sectionView(containing: .number)?.box.layer.cornerRadius == 24)
        form.clear()
        #expect(changes == 3, "one change per field")

        PayriffCardFormView(form).configure(form)
        #expect(form.style == style, "nil keeps the form's style")
        PayriffCardFormView(form, style: PayriffCardFormStyle()).configure(form)
        #expect(form.style == .default)
        #expect(form.sectionViews.map(\.section.fields) == [[.number, .expiry, .cvv]])
    }

    @Test("Stacked: every field in its own box with its own label and error; switching layouts keeps the values")
    func stackedLayout() throws {
        let form = PayriffCardForm(showsHolder: true, language: .en, style: PayriffCardFormStyle(layout: .stacked))
        #expect(form.sectionViews.map(\.section.fields) == [[.number], [.expiry], [.cvv], [.holder]])
        #expect(form.sectionViews.map(\.titleLabel.text) == ["Card number", "Expiry date", "Security code", "Card holder"])
        layOut(form)
        let sections = form.sectionViews
        for section in sections {
            #expect(section.cells.map(\.textField.field) == section.section.fields, "one field per box")
            #expect(section.dividers.isEmpty)
        }
        let boxes = sections.map { frame($0.box, in: form) }
        #expect(boxes[0].maxY < boxes[1].minY)
        #expect(abs(boxes[1].minY - boxes[2].minY) < 0.5, "expiry and CVV side by side")
        #expect(abs(boxes[1].width - boxes[2].width) < 0.5)
        #expect(boxes[1].maxX < boxes[2].minX)
        #expect(boxes[2].maxY < boxes[3].minY, "the holder last")
        #expect(form.brandMarkView?.isDescendant(of: sections[0].box) == true)

        _ = form.collectForPayment()
        #expect(sections.map(\.errorLabel.text) == ["Enter your card number", "Enter the expiry date", "Enter the CVV", "Enter the cardholder name"])
        #expect(sections.allSatisfy { $0.outline == .error })
        try type("4242424242424242", into: .number, of: form)
        #expect(sections[0].errorLabel.isHidden)
        #expect(sections[0].outline == .normal)
        #expect(sections[1].errorLabel.text == "Enter the expiry date")

        // Back to grouped: the same text fields move into the new boxes with what they hold.
        let number = try #require(form.textField(for: .number))
        form.style.layout = .grouped
        #expect(form.sectionViews.map(\.section.fields) == [[.holder], [.number, .expiry, .cvv]])
        let card = try #require(form.sectionView(containing: .number))
        #expect(card.cells.first?.textField === number)
        #expect(number.text == "4242 4242 4242 4242")
        #expect(form.brandMarkView?.visibleMark == .visa)
        #expect(form.brandMarkView?.isDescendant(of: card.cells[0]) == true)
        #expect(card.errorLabel.text == "Enter the expiry date", "the next error of the box")
        #expect(sections.allSatisfy { !$0.isDescendant(of: form) }, "the old sections are gone")
    }

    @Test("The number and the CVV can never be copied or cut; paste only into the number")
    func editMenu() throws {
        let form = PayriffCardForm(language: .en)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(form)
        form.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        window.isHidden = false
        defer { window.isHidden = true }
        let number = try #require(form.textField(for: .number) as? CardTextField)
        let cvv = try #require(form.textField(for: .cvv) as? CardTextField)
        number.text = "4242 4242 4242 4242"
        cvv.text = "123"
        let copy = #selector(UIResponderStandardEditActions.copy(_:))
        let cut = #selector(UIResponderStandardEditActions.cut(_:))
        let paste = #selector(UIResponderStandardEditActions.paste(_:))
        let share = NSSelectorFromString("_share:")
        for field in [number, cvv] {
            field.selectAll(nil)
            #expect(!field.canPerformAction(copy, withSender: nil))
            #expect(!field.canPerformAction(cut, withSender: nil))
            #expect(!field.canPerformAction(share, withSender: nil))
        }
        #expect(!cvv.canPerformAction(paste, withSender: nil))
        // Even a direct call cannot cut the number (the pasteboard itself is not read here: reading
        // it can show the system's paste prompt and block the test run).
        number.cut(nil)
        cvv.cut(nil)
        #expect(number.text == "4242 4242 4242 4242")
        #expect(cvv.text == "123")
    }

    @Test("Typing goes through the formatter, emits change events without values, and auto-advances")
    func typingAndChanges() throws {
        let form = PayriffCardForm(language: .en)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(form)
        form.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var changes: [PayriffCardFormChange] = []
        form.onChange = { changes.append($0) }
        let number = try #require(form.textField(for: .number))
        #expect(form.focus(.number))
        for digit in "4242424242424242" {
            let length = (number.text ?? "").utf16.count
            _ = form.textField(number, shouldChangeCharactersIn: NSRange(location: length, length: 0), replacementString: String(digit))
        }
        #expect(number.text == "4242 4242 4242 4242")
        #expect(form.brand == .visa)
        let numberChange = changes.last { $0.field == .number }
        #expect(numberChange?.isValid == true)
        #expect(numberChange?.brand == .visa)
        #expect(numberChange?.error == nil)
        #expect(form.textField(for: .expiry)?.isFirstResponder == true, "auto-advance to the expiry")
        #expect(changes.last?.field == .expiry, "focus moved: the expiry reports its state")
        #expect(!form.isComplete)
        form.clear()
        #expect(number.text == "")
        #expect(changes.last?.isEmpty == true)
    }

    @Test("The number field shows the brand's mark on a 36×24 badge, with a VoiceOver label (CONTRACT §16.4)")
    func brandMark() throws {
        let form = PayriffCardForm(language: .en)
        let number = try #require(form.textField(for: .number))
        let mark = try #require(form.brandMarkView)
        #expect(mark.intrinsicContentSize == CGSize(width: 36, height: 24))
        #expect(mark.visibleMark == .outline)
        #expect(!mark.isAccessibilityElement, "the neutral outline is not read")
        func type(_ digits: String) {
            for digit in digits {
                let length = (number.text ?? "").utf16.count
                _ = form.textField(number, shouldChangeCharactersIn: NSRange(location: length, length: 0), replacementString: String(digit))
            }
        }
        type("4")
        #expect(mark.visibleMark == .visa, "Visa after 4")
        #expect(mark.isAccessibilityElement)
        #expect(mark.accessibilityLabel == "Visa")
        form.clear()
        #expect(mark.visibleMark == .outline)
        type("5")
        #expect(mark.visibleMark == .outline)
        type("1")
        #expect(mark.visibleMark == .mastercard, "Mastercard after 51")
        #expect(mark.accessibilityLabel == "Mastercard")
        form.clear()
        type("222")
        #expect(mark.visibleMark == .outline)
        type("1")
        #expect(mark.visibleMark == .mastercard, "Mastercard after 2221")
        form.clear()
        #expect(mark.accessibilityLabel == nil)
        #expect(!mark.isAccessibilityElement)

        // Every mark fills the badge and draws in light and dark mode.
        let standalone = CardBrandMarkView(frame: CGRect(x: 0, y: 0, width: 36, height: 24))
        standalone.layoutIfNeeded()
        for brand in [PayriffCardBrand.visa, .mastercard, nil] {
            standalone.brand = brand
            for style in [UIUserInterfaceStyle.light, .dark] {
                standalone.overrideUserInterfaceStyle = style
                for layer in standalone.layer.sublayers ?? [] {
                    #expect(layer.bounds.size == CGSize(width: 36, height: 24))
                    layer.setNeedsDisplay()
                    layer.displayIfNeeded()
                }
            }
        }
        #expect(standalone.visibleMark == .outline)
    }

    @Test("The payment view's secure line starts with a lock drawn in code: 15×15 points, #56BE3D, hidden from VoiceOver (CONTRACT §16.14)")
    func paymentViewLock() throws {
        let view = PayriffPaymentView(orderId: "o1", clientSecret: "pr_cs_test", language: .en)
        let lock = view.lockView
        let row = try #require(lock.superview as? UIStackView)
        #expect(row.arrangedSubviews.first === lock && row.arrangedSubviews.last === view.secureLabel)
        #expect(row.spacing == 6)
        #expect(lock.systemLayoutSizeFitting(.zero) == CGSize(width: 15, height: 15))
        #expect(!lock.isAccessibilityElement && lock.accessibilityElementsHidden, "decoration")
        #expect(lock.outlineLayer.path == PaymentViewLock.outline())
        #expect(lock.outlineLayer.fillColor == nil)
        #expect(rgb(lock.outlineLayer.strokeColor.map { UIColor(cgColor: $0) }) == 0x56BE3D)
        #expect(lock.outlineLayer.lineWidth == PaymentViewLock.lineWidth())
        #expect(lock.outlineLayer.lineCap == .round && lock.outlineLayer.lineJoin == .round)
        #expect(lock.keyholeLayer.path == PaymentViewLock.keyhole())
        #expect(rgb(lock.keyholeLayer.fillColor.map { UIColor(cgColor: $0) }) == 0x56BE3D)
        #expect(rgb(lock.keyholeLayer.fillColor.map { UIColor(cgColor: $0) }, .dark) == 0x56BE3D, "the same green in dark mode")
    }

    @Test("collectForPayment shows the errors; the privacy cover follows the scene; processing locks the form")
    func collectCoverAndProcessing() throws {
        let form = PayriffCardForm(showsHolder: true, language: .ru)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(form)
        form.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        window.isHidden = false
        defer { window.isHidden = true }
        let failure = try #require(form.collectForPayment().failureValue)
        #expect(failure.issues.map(\.field) == [.number, .expiry, .cvv, .holder])
        #expect(failure.issues.first?.message == "Введите номер карты")

        form.sceneWillDeactivate(nil)
        #expect(form.isShowingPrivacyCover)
        form.sceneDidActivate(nil)
        #expect(!form.isShowingPrivacyCover)

        form.setProcessing(true)
        #expect(form.isProcessing)
        #expect(form.textField(for: .number)?.isEnabled == false)
        let number = try #require(form.textField(for: .number))
        #expect(!form.textField(number, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "4"))
        form.setProcessing(false)
        #expect(form.textField(for: .number)?.isEnabled == true)
    }

    @Test("print, dump and the debugger never show the typed values (UITextField's description includes its text)")
    func descriptionsAreRedacted() throws {
        let form = PayriffCardForm(showsHolder: true, language: .en)
        let number = try #require(form.textField(for: .number))
        let cvv = try #require(form.textField(for: .cvv))
        let holder = try #require(form.textField(for: .holder))
        _ = form.textField(number, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "5555555555554444")
        _ = form.textField(cvv, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "987")
        holder.text = "JANE SECRET"
        #expect(number.text == "5555 5555 5555 4444")
        var dumped = ""
        dump(form, to: &dumped)
        let texts = [number.description, number.debugDescription, cvv.description, holder.description, "\(number)", String(reflecting: cvv), dumped]
        for text in texts {
            // Formatted and raw values; memory addresses never contain a space or 16 digits in a row.
            for secret in ["5555 5555", "5555555555554444", "'987'", "JANE SECRET"] {
                #expect(!text.contains(secret), "\(text)")
            }
        }
        #expect(number.description.contains("text = <redacted>"))
    }

    @Test("Values are cleared after a final result and kept after a non-fatal failure")
    func clearingAfterResults() throws {
        let form = PayriffCardForm(language: .en)
        let number = try #require(form.textField(for: .number))
        func fill() { _ = form.textField(number, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "4242") }
        fill()
        form.paymentDidFinish(.failed(PayriffError(code: .paymentFailed, message: "declined", isRetryable: true)))
        #expect(number.text == "4242")
        form.paymentDidFinish(.failed(PayriffError(code: .sessionExpired, message: "gone", isFatal: true)))
        #expect(number.text == "")
        fill()
        form.paymentDidFinish(.declined(PayriffPayment(orderId: "o1", status: .declined)))
        #expect(number.text == "")
    }

    @Test("The sheet in 3DS mode loads a native form POST and reports finished loads")
    func sheetLoadsPost() async throws {
        let sheet = PaymentSheet(language: .en)
        var request = URLRequest(url: URL(string: "https://acs.bank.example/challenge")!)
        request.httpMethod = "POST"
        request.httpBody = Data("creq=abc".utf8)
        sheet.rootPage.loadViewIfNeeded()
        sheet.load(request: request)
        #expect(sheet.rootPage.webView.isLoading || sheet.rootPage.webView.url != nil)
        sheet.rootPage.webView.stopLoading()
    }

    @Test("Hidden 3DS-method web views: invisible, attached to the window, removed on stop")
    func methodFrames() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        let frames = ThreeDSMethodFrames()
        let request = CardPaymentFlow.formPost(URL(string: "https://acs.bank.example/method")!, fields: [("threeDSMethodData", "x")])
        // Hosts under the reserved .example TLD: the hidden web views never reach Payriff or a bank.
        frames.start([request, CardPaymentFlow.formPost(URL(string: "https://gateway.payriff.example/api/v3/gateway/atb/method")!, fields: [])], apiHost: "gateway.payriff.example", in: window)
        #expect(frames.count == 2)
        let hidden = window.subviews.compactMap { $0 as? WKWebView }
        #expect(hidden.count == 2)
        for webView in hidden {
            #expect(webView.alpha == 0)
            #expect(!webView.isUserInteractionEnabled)
            #expect(webView.accessibilityElementsHidden)
        }
        frames.stop()
        #expect(frames.count == 0)
        #expect(window.subviews.compactMap { $0 as? WKWebView }.isEmpty)
    }
}
#endif
