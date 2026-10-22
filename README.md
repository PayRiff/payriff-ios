# Payriff iOS SDK

Accept card payments with [Payriff](https://payriff.com) in your iOS app. Your server creates the order; the app shows `PayriffPaymentView` (UIKit) or `PayriffPaymentScreen` (SwiftUI), a ready-made payment screen that pays the order with your **publishable key** and the order's **`clientSecret`**. The SDK encrypts the card on the device, runs 3-D Secure in a native sheet, checks the order status and gives you a typed `PayriffResult`. For a screen of your own, use the card form (`PayriffCardForm`, `PayriffCardFormView`) and `Payriff.confirmCardPayment` that the payment view is built on.

- A ready-made payment screen that looks like the card part of Payriff's hosted payment page (pay.payriff.com) by default and can be restyled: the card form with Visa and Mastercard marks, a Pay button with the amount, localized labels and errors.
- The card never reaches your code or logs; it leaves the device only encrypted (AES-256-GCM, the key wrapped with Payriff's pinned RSA key).
- 3-D Secure in a sheet that reads as part of your app; web views appear only for 3-D Secure.
- The merchant secret key never ships in the app: it stays on your server.
- iOS 16+, Swift 6, no third-party dependencies, Swift Package Manager (CocoaPods coming soon).

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [The payment view](#the-payment-view)
  - [Page, bottom sheet or popup](#page-bottom-sheet-or-popup)
  - [Customise the payment view](#customise-the-payment-view)
- [Build your own screen](#build-your-own-screen)
  - [Card form](#card-form)
  - [Customise the card form](#customise-the-card-form)
- [Configuration](#configuration)
- [Handling `PayriffResult`](#handling-payriffresult)
- [Fulfil on your server](#fulfil-on-your-server)
- [Errors](#errors)
- [Logging](#logging)
- [Privacy and screen protection](#privacy-and-screen-protection)
- [Platform notes](#platform-notes)
- [Known limitations](#known-limitations)
- [Example app](#example-app)
- [Troubleshooting](#troubleshooting)
- [Support](#support)
- [License](#license)

## How it works

1. **Your server creates the order** with its secret key (`POST /api/v3/orders` on Payriff's API) and returns the order's `orderId` and `clientSecret` (`pr_cs_…`) to the app. Payriff returns the client secret when your application has an active publishable key.
2. **The app shows `PayriffPaymentView`** (`PayriffPaymentScreen` in SwiftUI) for the order. The view reads the order and shows the amount on its Pay button. When the customer taps Pay, it calls `Payriff.confirmCardPayment`.
3. The SDK loads the order, encrypts the card, sends it to Payriff's Client API and runs 3-D Secure in a sheet when the bank asks for it.
4. The SDK polls the order status and returns a `PayriffResult`. The result drives your UI; your server confirms the order with Payriff before it fulfils ([Fulfil on your server](#fulfil-on-your-server)).

The SDK never creates orders and never uses the secret key. It is the same split as on the web with Payriff.js.

## Requirements

- iOS 16 or later.
- Xcode 16 or later, Swift 6 toolchain.
- A Payriff merchant account with an application that has an active **publishable key** (`pr_pk_live_…`).
- **macOS: core only, no payment UI.** `Package.swift` also declares macOS 13, only so that the UI-free core (validation, encryption, the Client API and the card payment flow) builds and runs under `swift test`. The payment view, the card form and `confirmCardPayment` exist on iOS only. The CocoaPods pod is iOS-only.

## Installation

### Swift Package Manager

In Xcode choose **File ▸ Add Package Dependencies…** and enter the repository URL:

```
https://github.com/PayRiff/payriff-ios
```

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PayRiff/payriff-ios", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Payriff", package: "payriff-ios"),
    ]),
]
```

Until the `1.0.0` tag exists, depend on the `main` branch instead: `.package(url: "https://github.com/PayRiff/payriff-ios", branch: "main")`, or the **Branch** rule with `main` in Xcode.

### CocoaPods (coming soon)

The `Payriff` pod is coming soon: it is not on CocoaPods trunk yet. Once it is published:

```ruby
platform :ios, '16.0'

target 'MyApp' do
  use_frameworks!
  pod 'Payriff', '~> 1.0'
end
```

Then `import Payriff` wherever you use the SDK.

## Quick start

**On your server**, create the order with your secret key and return `orderId` and `clientSecret` to the app (never the secret key):

```http
POST https://api.payriff.com/api/v3/orders
Authorization: <your secret key>
Content-Type: application/json

{"amount": 10.5, "currency": "AZN", "language": "AZ", "description": "Order #42", "operation": "PURCHASE", "cardSave": false}
```

The response's `payload` carries `orderId` and `clientSecret`.

**In the app**, configure the SDK once at launch:

```swift
import Payriff

Payriff.configure(PayriffConfig(publishableKey: "pr_pk_live_…", environment: .production))
```

Then show the payment view for the order. **SwiftUI:**

```swift
struct CheckoutView: View {
    let order: Order    // orderId and clientSecret from your server
    @State private var showsPayment = false

    var body: some View {
        NavigationStack {
            Button("Checkout") { showsPayment = true }
                .navigationDestination(isPresented: $showsPayment) {
                    PayriffPaymentScreen(orderId: order.orderId, clientSecret: order.clientSecret) { result in
                        showsPayment = false
                        handle(result)
                    }
                    .navigationBarTitleDisplayMode(.inline)
                }
        }
    }
}
```

**UIKit:**

```swift
func pay(_ order: Order) {
    let payment = UIViewController()
    payment.view = PayriffPaymentView(orderId: order.orderId, clientSecret: order.clientSecret) { [weak self] result in
        guard let self else { return }
        navigationController?.popToViewController(self, animated: true)
        handle(result)
    }
    navigationController?.pushViewController(payment, animated: true)
}
```

Then handle the result ([Handling `PayriffResult`](#handling-payriffresult)):

```swift
func handle(_ result: PayriffResult) {
    switch result {
    case .success(let payment): showReceipt(payment)                // still confirm on your server
    case .failed(let error) where error.isFatal: startNewOrder()    // 401, 404 (expired secret), 429
    case .failed(let error): showError(error.message)               // the order can still be paid
    case .declined, .cancelled, .pending: reconcileOnServer()
    }
}
```

## The payment view

`PayriffPaymentView` (UIKit) and `PayriffPaymentScreen` (SwiftUI) are Payriff's ready-made card payment screen, like the card part of Payriff's hosted payment page (pay.payriff.com).

```swift
PayriffPaymentView(
    orderId: order.orderId,             // from your server
    clientSecret: order.clientSecret,   // from your server (pr_cs_…)
    language: nil,                      // nil: PayriffConfig.language, then the device language
    style: PayriffPaymentViewStyle(),   // see Customise the payment view
    onResult: { result in }             // every payment's result, and a fatal error once
)
// SwiftUI: PayriffPaymentScreen(orderId:clientSecret:language:style:onResult:) takes the same values.
```

- It shows the card form, a Pay button with the order's amount ("Pay 1.02 AZN"), the Mastercard and Visa badges, a "Proceed securely by PCI DSS" line and a "Powered by Payriff" footer.
- It reads the order with `Payriff.retrieveOrder` when it appears. The Pay button stays disabled while the order loads, while the form is incomplete and while a payment runs. It also stays disabled when the order cannot be paid by card or did not load: a line under the button then says why ("This order cannot be paid by card" in the view's language, or the error's message), and VoiceOver reads it out. If the order did not load for a reason that is not fatal, such as no network, the view reads it again the next time it appears.
- Pay runs `Payriff.confirmCardPayment` with the view's card form. While it runs, a spinner replaces the button's title and the form is locked. 3-D Secure opens in Payriff's sheet.
- `onResult` is called on the main actor with the result of each payment attempt. It is also called once with a fatal error that ends the order (`error.isFatal`, for example `SESSION_EXPIRED` for an expired client secret), even when the error comes from reading the order. After a result with a status (success, declined, cancelled or pending), the view does not pay the order again.
- A failure that is not fatal keeps the order payable, for example `NETWORK_ERROR` (`error.isRetryable`) or `PAYMENT_FAILED`. Pay stays enabled, so the customer can try again in the same view, and you can also show the view again with the same `orderId` and `clientSecret`. The view does not show the message of such a failure: show `error.message` yourself. `ORDER_NOT_PAYABLE` and fatal errors disable Pay and show their message under the button.
- The result drives your UI only: fulfil the order after your server confirms it ([Fulfil on your server](#fulfil-on-your-server)).
- Call `Payriff.configure` before you show the view. A new `style` or `language` applies at once and keeps what the customer typed. In SwiftUI, a new `orderId` or `clientSecret` makes the screen read the new order.
- The 3-D Secure sheet is presented from `presenter` (UIKit only) or, by default, from the top-most view controller of the view's window.

### Page, bottom sheet or popup

Give the view the whole screen or most of it. It adds the safe area to its padding, scrolls when the keyboard is up, keeps the field being edited above the keyboard, and keeps the footer at the bottom when there is room. It does not size itself to its content, so give it a height, as below. The [quick start](#quick-start) shows it as a page; a bottom sheet and a popup work the same way.

**SwiftUI:**

```swift
// A bottom sheet.
.sheet(isPresented: $showsSheet) {
    PayriffPaymentScreen(orderId: order.orderId, clientSecret: order.clientSecret) { result in
        showsSheet = false
        handle(result)
    }
    .presentationDetents([.fraction(0.85), .large])
    .presentationDragIndicator(.visible)
}

// A popup: a card in the middle of the dimmed screen.
.overlay {
    if showsPopup {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showsPopup = false }
            PayriffPaymentScreen(orderId: order.orderId, clientSecret: order.clientSecret) { result in
                showsPopup = false
                handle(result)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 440, maxHeight: 640)
            .padding(16)
        }
    }
}
```

**UIKit:**

```swift
// A bottom sheet.
let payment = UIViewController()
payment.view = PayriffPaymentView(orderId: order.orderId, clientSecret: order.clientSecret) { [weak self] result in
    self?.dismiss(animated: true)
    self?.handle(result)
}
if let sheet = payment.sheetPresentationController {
    sheet.detents = [.custom { $0.maximumDetentValue * 0.85 }, .large()]
    sheet.prefersGrabberVisible = true
}
present(payment, animated: true)

// A popup: the view as a card in the middle of the dimmed screen.
let popup = UIViewController()
popup.modalPresentationStyle = .overFullScreen
popup.modalTransitionStyle = .crossDissolve
popup.view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
let paymentView = PayriffPaymentView(orderId: order.orderId, clientSecret: order.clientSecret) { [weak self] result in
    self?.dismiss(animated: true)
    self?.handle(result)
}
paymentView.layer.cornerRadius = 16
paymentView.clipsToBounds = true
paymentView.translatesAutoresizingMaskIntoConstraints = false
popup.view.addSubview(paymentView)
let safeArea = popup.view.safeAreaLayoutGuide
let width = paymentView.widthAnchor.constraint(equalToConstant: 440)
let height = paymentView.heightAnchor.constraint(equalToConstant: 640)
width.priority = .defaultHigh
height.priority = .defaultHigh
NSLayoutConstraint.activate([
    paymentView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
    paymentView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
    paymentView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 16),
    paymentView.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor, constant: 16),
    width,
    height,
])
present(popup, animated: true)
```

The view paints its own background (`#FCFCFD`, `#222224` in dark mode), so the sheet and the popup show its colour. If the customer closes the page, the sheet or the popup before tapping Pay, nothing is paid and `onResult` may not be called. A payment that has started still ends with one `onResult` call. The example app (`Example/PayriffExample/Sources/ContentView.swift`) shows all three.

### Customise the payment view

Pass a `PayriffPaymentViewStyle`. Every property has a default, and the defaults reproduce the card part of Payriff's hosted payment page, in light and dark mode. Change only what you need. The card form inside the view takes `formStyle`, a `PayriffCardFormStyle` ([Customise the card form](#customise-the-card-form)).

```swift
var style = PayriffPaymentViewStyle()
style.buttonColor = .systemIndigo
style.buttonCornerRadius = 12
style.buttonHeight = 52
style.showPoweredBy = false
style.formStyle.layout = .stacked
style.formStyle.focusedBorderColor = .systemIndigo
style.formStyle.cornerRadius = 12

PayriffPaymentScreen(orderId: order.orderId, clientSecret: order.clientSecret, style: style) { handle($0) }   // SwiftUI
let paymentView = PayriffPaymentView(orderId: order.orderId, clientSecret: order.clientSecret, style: style)  // UIKit; paymentView.style = style also works
```

| Property | Default |
|---|---|
| `backgroundColor` | `#FCFCFD`; `#222224` in dark mode |
| `padding` | 20 pt on every side. The view adds the safe area to it, and the part of the keyboard that covers the view. |
| `buttonColor` | Payriff's brand colour `#4DBDC6` |
| `buttonTextStyle` | 16 pt semibold; a `nil` colour is white. The spinner shown while paying takes the same colour. |
| `buttonHeight`, `buttonCornerRadius` | 44, 16 pt. The button grows with large Dynamic Type sizes. |
| `secondaryTextColor` | `#76787F`, in light and dark mode: the secure line and the footer |
| `showBadges` | `true`: the Mastercard and Visa badges under the button |
| `showSecureNote` | `true`: the lock and "Proceed securely by PCI DSS" |
| `showPoweredBy` | `true`: "Powered by" and the Payriff logo at the bottom |
| `formStyle` | `PayriffCardFormStyle()`. Its `errorColor` and `errorTextStyle` also style the line under the Pay button; `showLabels = false` hides "Card holder" and "Card information". |

The spacing is fixed: 24 pt between the parts, 8 pt above the error line, 20 pt between the badges and the secure line, and at least 24 pt above the footer. The secure line and the footer are 12 pt. Every font of the view scales with Dynamic Type. Colours you set are used as they are, so pass dynamic colours (system colours or `UIColor(dynamicProvider:)`) to follow dark mode. For a layout the style cannot give, [build your own screen](#build-your-own-screen).

## Build your own screen

`PayriffPaymentView` is built from two public parts that you can use on a screen of your own: the card form (`PayriffCardForm` for UIKit, `PayriffCardFormView` for SwiftUI) and `Payriff.confirmCardPayment`.

**SwiftUI:**

```swift
struct CheckoutView: View {
    let orderId: String         // from your server
    let clientSecret: String    // from your server
    @State private var form = PayriffCardForm()
    @State private var isComplete = false
    @State private var result: PayriffResult?

    var body: some View {
        VStack {
            PayriffCardFormView(form) { change in isComplete = change.isComplete }
            Button("Pay") {
                Task { result = await Payriff.confirmCardPayment(form, orderId: orderId, clientSecret: clientSecret) }
            }
            .disabled(!isComplete)
        }
    }
}
```

**UIKit:**

```swift
let form = PayriffCardForm()
form.onChange = { change in payButton.isEnabled = change.isComplete }
view.addSubview(form)

// When the customer taps Pay:
let result = await Payriff.confirmCardPayment(form, orderId: orderId, clientSecret: clientSecret, from: self)
switch result {
case .success(let payment): showReceipt(payment)                    // still confirm on your server
case .failed(let error) where error.code == .validationFailed: break // the form shows the errors
case .failed(let error) where error.isFatal: await createNewOrder()  // 401, 404 (expired secret), 429
case .failed(let error): showError(error.message)                    // the customer may try again
case .declined, .cancelled, .pending: await backend.reconcile(orderId)
}
```

A completion-handler variant, `confirmCardPayment(_:orderId:clientSecret:from:completion:)`, is available too. `Payriff.retrieveOrder(orderId:clientSecret:)` returns the order's amount, currency, description, merchant name, status and `isPayableByCard`, for example to show the amount before the customer pays.

### Card form

- **Fields:** card number, expiry, CVV and the cardholder name. The holder is shown by default, as on Payriff's hosted payment page; `PayriffCardForm(showsHolder: false)` hides it, and the name is then sent as `Unknown`.
- **Brands:** Visa and Mastercard, with at most 16 digits: typing, pasting and AutoFill stop there. The number field shows the brand's mark as soon as the first digits identify it (Visa after `4`, Mastercard after `51`–`55` or `2221`–`2720`), and a neutral card outline before.
- **Validation:** Luhn check, an expiry that is not in the past and at most 20 years ahead, a 3-digit CVV, a holder of at most 50 characters. Definite errors show at once, incomplete fields after leaving them or tapping Pay, empty fields only after Pay.
- **Holder:** always upper case (shown, validated and sent), like the name printed on the card, with the locale-independent mapping (`i` → `I`, also on an Azerbaijani or Turkish device).
- **Behaviour:** focus moves number → expiry → CVV when a field becomes valid (`autoAdvance`). `onChange` reports validity, errors, the brand and `isComplete`, never the values. `clear()` and `focus(_:)` are available.
- **Appearance:** by default the card form of Payriff's hosted payment page: **Card holder**, then one **Card information** box with the number on top and expiry | CVC below, one error line per section. Change it with `PayriffCardFormStyle` ([Customise the card form](#customise-the-card-form)). It follows light and dark mode, Dynamic Type and VoiceOver. Labels, placeholders and errors are in Azerbaijani, English or Russian (`form.language`, else `PayriffConfig.language`, else the device language).
- **Input security:** numeric keyboards; no autocorrection, suggestions or inline predictions; AutoFill for number, expiry and name only; a masked CVV; the number and CVV cannot be copied, cut or dragged; an opaque cover hides the form while the app is inactive. Values are cleared after every result except a non-fatal failure.

While a payment runs, the form is locked and shows progress. 3-D Secure opens in Payriff's sheet (the 3DS method runs in hidden web views), and the status is polled every 2.5 s for up to 120 s. Closing the sheet asks for confirmation, then checks the status once: a final status maps as usual, anything else is `.pending(reason: .notFinal)`, because the card was already submitted.

### Customise the card form

By default `PayriffCardForm` looks like the card form of Payriff's hosted payment page (pay.payriff.com): the **Card holder** field (`showsHolder: false` hides it), then one **Card information** box with the card number and the brand's mark on top and the expiry and CVC side by side. Each section has one error line, and the box shows the first error of number → expiry → CVC. A section's outline turns red while it shows an error, or Payriff's brand colour (`focusedBorderColor`) while the customer types in it.

Change any part of it with `PayriffCardFormStyle`; in the payment view, set it as `PayriffPaymentViewStyle.formStyle`. Every property is optional and defaults to Payriff's look:

```swift
var style = PayriffCardFormStyle()
style.cornerRadius = 16
style.borderColor = .systemGray4
style.focusedBorderColor = .systemIndigo                    // default: Payriff's #4DBDC6; nil: the form's tintColor
style.labelTextStyle = .init(size: 13, weight: .bold, color: .secondaryLabel)
style.cardLabel = "Card details"                            // default: "Card information", localized
// style.layout = .stacked                                  // every field in its own box

let form = PayriffCardForm(style: style)                    // UIKit; form.style = style also works
PayriffCardFormView(form, style: style)                     // SwiftUI
```

| Property | Default |
|---|---|
| `labelTextStyle` | 14 pt semibold; a `nil` colour is `#34363A` (`#E1E4E8` in dark mode) |
| `inputTextStyle` | 14 pt regular; a `nil` colour is `#4D4F54` (`#8E8E93` in dark mode). The placeholders use its font. |
| `placeholderColor` | `#76787F` (`#5F6167` in dark mode) |
| `errorTextStyle` | 13 pt regular; a `nil` colour is `errorColor` |
| `showLabels`, `holderLabel`, `cardLabel` | `true`, `nil`, `nil` (`nil`: "Card holder" and "Card information" in the form's language) |
| `fieldBackgroundColor` | transparent: the fields show the background behind the form |
| `borderColor` | `#ECEEF0` (`#3F4145` in dark mode). Also the 1-point lines inside the card box. |
| `focusedBorderColor` | Payriff's brand colour `#4DBDC6`, also the caret's colour. `nil` uses the form's `tintColor`, your app's accent colour. |
| `errorColor` | `#EC4D3D` (`#EC5545` in dark mode) |
| `borderWidth`, `cornerRadius` | 1, 12 pt |
| `holderHeight`, `rowHeight` | 46, 40 pt, outlines included; the card box is 2 × 40 − 1 = 79 pt tall. Both grow with large Dynamic Type sizes. |
| `horizontalPadding`, `labelSpacing`, `sectionSpacing` | 14, 10, 16 pt |
| `layout` | `.grouped`; `.stacked` gives every field its own box, label and error line |

Fonts scale with Dynamic Type and rows grow with them. Colours you set are used as they are, so pass dynamic colours (system colours or `UIColor(dynamicProvider:)`) to follow dark mode. A new style applies at once and keeps what the customer typed. The fields' VoiceOver labels stay "Card number", "Expiry date" and "Security code" even without titles.

## Configuration

`Payriff.configure(_:)` can be called again; the new configuration applies to later calls only. It never throws. A call made before `configure` fails with `NOT_CONFIGURED`. A missing or invalid publishable key is logged as a warning (`Invalid configuration: …`), and every call then fails with `INVALID_CONFIG`.

| `PayriffConfig` property | Type | Default | Description |
|---|---|---|---|
| `publishableKey` | `String?` | `nil` | Your publishable key, `pr_pk_live_…`. Trimmed. A key with another prefix (a secret key is always refused) is `INVALID_CONFIG`. |
| `environment` | `PayriffEnvironment` | `.production` | `.production` (`https://api.payriff.com`) or `.sandbox` (`https://sb-api.payriff.com`, provisional until Payriff confirms the sandbox host). |
| `language` | `PayriffLanguage?` | `nil` | `.az`, `.en` or `.ru` for the payment view, the card form and the 3-D Secure sheet. `nil` uses the device language (`az*` → AZ, `ru*` → RU, otherwise EN). |
| `enableLogging` | `Bool` | `false` | Emit log entries (see [Logging](#logging)). |

The look is set on the view itself: `PayriffPaymentViewStyle` for the payment view, `PayriffCardFormStyle` for the card form. `print(config)`, `debugPrint(config)` and `dump(config)` show the publishable key only as `pr_pk_live_***(<length>)`.

## Handling `PayriffResult`

Payment outcomes are returned, never thrown, and every call completes with exactly one result. **Only `.success` means paid**, and even `.success` only drives your UI: your server decides what to fulfil ([Fulfil on your server](#fulfil-on-your-server)).

| Result | When | What to do |
|---|---|---|
| `.success(payment)` | Status `APPROVED` or `PREAUTH_APPROVED`. | Show success; fulfil once your server has confirmed the order. |
| `.declined(payment)` | Status `DECLINED`. | Let the customer try another card. |
| `.cancelled(payment, reason:)` | `.canceled` / `.expired`: the order was cancelled or expired. | Create a new order if the customer wants to pay again. |
| `.pending(payment, reason:)` | `.notFinal`: still processing after 120 s, or the customer closed the 3-D Secure sheet before a final status. `.verificationFailed`: status polling stopped on an error. `.unexpectedStatus`: a final status such as `REFUNDED`. | Verify on your server before fulfilling. |
| `.failed(error)` | The payment could not start or run: configuration, an invalid card form, an order that cannot be paid, or an error from Payriff. | Show `error.message`. `error.isFatal` means "create a new order"; otherwise the customer may try again. |

`PayriffPayment` carries `orderId`, `status` (`PayriffPaymentStatus`), `rawStatus`, and the `amount` and `currency` from the order's status. `transactionId` and `originalOrderId` are part of the result shape shared by every Payriff SDK and are `nil` in the card flow; so is the `.cancelled` reason `.userClosed` and the `.pending` reason `.unverified`, which the card flow never returns.

Helpers: `result.isSuccess`, `result.payment`, `result.error` and `result.type`; `PayriffPaymentStatus(rawStatus:)` parses a raw status; `Payriff.version` and `Payriff.isPaymentInProgress`.

### Result JSON

Results serialize to the same JSON on every Payriff SDK, handy for logs and cross-platform bridges. Every key is present and unknown values are `null`:

```json
{"type":"success","payment":{"orderId":"o1","status":"APPROVED","rawStatus":"APPROVED","amount":10.5,"currency":"AZN","transactionId":null,"originalOrderId":null}}
{"type":"failed","error":{"code":"NETWORK_ERROR","message":"…","isRetryable":true,"httpStatus":null,"payriffCode":null,"supportTicket":null}}
```

`PayriffResult` is `Encodable` (use `JSONEncoder`), and `result.jsonObject` gives the same shape as a `[String: Any]` (with `NSNull` for `null`).

## Fulfil on your server

The SDK's result is for your UI only. Anyone who controls the device can change what the app sees. Fulfil an order (ship goods, credit a balance, unlock content) only after **your server** has confirmed it with Payriff:

1. **Ask Payriff, not the app.** Your server looks the order up on Payriff's API with your secret key (`GET /api/v3/orders/{orderId}`), or handles Payriff's server-to-server callback. Never fulfil because the app reported `.success`.
2. **Check that it is your order.** The `orderId` must be an order your server created for this cart.
3. **Check what was paid.** The order's amount and currency must match the cart, and its status must be `APPROVED` (or `PREAUTH_APPROVED` for a pre-authorization you will capture).
4. **Fulfil once.** Record the order as fulfilled so a repeated callback or a second confirmation from the app does nothing.

A pending result is not proof that nothing was paid. Before you let the customer pay the same cart again, reconcile the order on your server.

## Errors

`PayriffError` has a stable `code`, a readable `message`, `isRetryable`, `isFatal` (create a new order), `fields` (for `VALIDATION_FAILED`) and, when Payriff answered, `httpStatus`, `payriffCode` and `supportTicket`.

| `code` | When |
|---|---|
| `NOT_CONFIGURED` | `configure` was not called. |
| `INVALID_CONFIG` | `publishableKey` is missing or is not `pr_pk_live_…`. |
| `INVALID_ORDER` | The order id is blank, or the client secret is not `pr_cs_…`. |
| `PAYMENT_IN_PROGRESS` | Another card payment of the SDK is still running. |
| `VALIDATION_FAILED` | The card form is not valid; nothing was sent. `fields` lists the fields, and the form shows the errors. |
| `ORDER_NOT_PAYABLE` | The order is not `CREATED` or `PENDING`, `CARD` is not one of its payment methods, or HTTP 400. |
| `UNAUTHORIZED` | HTTP 401: the publishable key or this app was rejected. Fatal. |
| `SESSION_EXPIRED` | HTTP 404: the order was not found or its client secret expired. Fatal. |
| `RATE_LIMITED` | HTTP 429 after three retries (1 s, 2 s, 4 s). Fatal. |
| `INVALID_REQUEST` | HTTP 400 with code `15400`: an integration problem. |
| `PAYMENT_FAILED` | Payriff refused the payment; `message` carries its reason. The customer may try again. |
| `UNEXPECTED_RESPONSE` | Payriff answered with a next step the SDK cannot run safely, and the status was not final. |
| `NETWORK_ERROR` | Offline, DNS, TLS or timeout. Retryable. |
| `UNKNOWN` | Anything else, for example the card could not be encrypted. Never retryable. |

## Logging

```swift
Payriff.configure(PayriffConfig(publishableKey: "pr_pk_live_…", environment: .sandbox, enableLogging: true))

PayriffLogger.onLog = { entry in
    print(entry.formatted) // "[Payriff] [INFO] …"
}
```

Each `PayriffLogEntry` has a `level` (`debug`, `info`, `warning`, `error`), a `message`, a `timestamp` and `formatted`, the `[Payriff] [LEVEL] message` line. Entries also go to the unified log (subsystem `com.payriff.sdk`): readable in debug builds, marked private in release builds. The handler can be called on any thread.

- Logs never contain card data, the client secret, the publishable key, the encrypted card, `x-secret-key` or 3-D Secure form values.
- They do contain order ids, statuses, amounts and URL paths. Keep them in your own diagnostics and do not forward `onLog` to third-party analytics or crash reporters.
- http(s) URLs are logged without query, fragment, user name and password; other schemes only as `<scheme>:…`.
- Debug builds also log every API request and response at `debug` level as pretty-printed JSON (`HTTP request` / `HTTP response`: method, URL, headers and body), with every secret shown only as `***(<length>)`. Release builds never log them.

## Privacy and screen protection

- **App switcher and screenshots.** While the app is inactive (the app switcher, Control Center, a call or another app in Split View), opaque covers hide the card form and the 3-D Secure sheet, so snapshots never show what the customer typed.
- **Session replay and screen recording.** Tools that record your app's screen would capture the form and the bank's pages. Exclude or mask them in such tools.
- **Privacy manifest.** The SDK ships `PrivacyInfo.xcprivacy`: no tracking; Payment Info and Purchase History collected for App Functionality, linked to the user. Reflect this in your App Store privacy details.
- **3-D Secure website data.** The 3-D Secure sheet and the hidden 3-D Secure Method web views of a payment share one non-persistent website data store (`WKWebsiteDataStore.nonPersistent()`), and every payment gets a new one. Their cookies and other website data never reach your app's default website data store or the disk, and they go away with the payment.

## Platform notes

- **No Info.plist entries are needed.** Bank-app links from 3-D Secure pages are handed to iOS with `UIApplication.open`.
- **Presenter.** Without `from:`, the 3-D Secure sheet is presented from the top-most view controller of the form's window. `PayriffPaymentView.presenter` does the same for the payment view.
- **One payment at a time.** A second call while a payment runs returns `.failed` with `PAYMENT_IN_PROGRESS`.
- **The 3-D Secure sheet** has a grabber, the localized title and a close button (a Liquid Glass button on iOS 26 and later), a native loader instead of a progress bar, and no address bar. Bank pages sit 16 pt from the sides and 12 pt from the top and bottom on a white backdrop. There is no zoom, rubber-band scrolling or link preview. JavaScript `alert`, `confirm` and `prompt` of bank pages are answered at once with their default. A swipe down never dismisses the sheet by itself: it runs the close path. While the status is checked, the close button is disabled.
- **No JavaScript is injected** into the bank's pages, and the user agent is unchanged.
- **App extensions.** The payment APIs are unavailable in app extensions.
- **Type names.** The facade type and the module are both called `Payriff`; refer to SDK types by their own names, such as `PayriffError`.

## Known limitations

- **No payment UI on macOS.** The macOS target exists only for `swift test` of the UI-free core.
- **Sandbox host.** `https://sb-api.payriff.com` is provisional until Payriff confirms the sandbox host.
- **Process death.** If iOS terminates the app during a payment, the pending `confirmCardPayment` call is gone; reconcile the order on your server.

## Example app

`Example/PayriffExample` is a SwiftUI app (bundle id `com.payriff.example.ios`) with one screen. It holds no secret key and never creates orders: as in a real app, your server creates the order with its secret key (`POST /api/v3/orders`) and returns `{"orderId", "clientSecret"}`.

1. Copy the configuration template and add your **publishable key**:

   ```bash
   cp Example/Config/Secrets.example.xcconfig Example/Config/Secrets.xcconfig
   ```

   `Secrets.xcconfig` is git-ignored and only **Debug** builds read it. Its values reach the app through Info.plist. Payriff only accepts apps it knows: ask Payriff to allow the bundle id `com.payriff.example.ios` for your publishable key.

2. Create an order on your server ([Quick start](#quick-start)) and copy its `orderId` and `clientSecret`.

3. Open `Example/PayriffExample/PayriffExample.xcodeproj` and run the `PayriffExample` scheme (generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)).

4. Under **Order from your backend**, type the `orderId` and the `clientSecret`, or tap **Paste**. Paste reads the JSON `{"orderId", "clientSecret"}` from the clipboard, or the two values separated by white space.

5. **Pay in page**, **Pay in bottom sheet** and **Pay in popup** show `PayriffPaymentScreen` pushed as a page, in a sheet (85% of the screen, or full height) or as a card in the middle of the dimmed screen (`ContentView.swift`). The buttons are enabled once the publishable key and both values are there; without a publishable key, the screen says so. 3-D Secure opens in the SDK's sheet.

6. The result closes the payment view and opens in a result sheet: the result's type, the order id, the status, the amount, the error and the result's JSON. After a failure the order stays in the fields, so you can pay it again; after any other result the fields are cleared.

Debug builds also write the SDK log to `Documents/payriff-sdk.log` in the app's container.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `.failed` with `NOT_CONFIGURED` | Call `Payriff.configure` first. |
| `INVALID_CONFIG` | Set `publishableKey` to your `pr_pk_live_…` key; a secret key is never accepted. |
| `INVALID_ORDER` | Pass the order id and the `pr_cs_…` client secret your server received. |
| `UNAUTHORIZED` | The publishable key is wrong or revoked, or the app is not allowed for it, or it belongs to the other environment. |
| `SESSION_EXPIRED` | The order does not exist in this environment, or its client secret expired: create a new order. |
| `ORDER_NOT_PAYABLE` | The order was already paid, cancelled or expired, or does not accept cards. |
| The payment view's Pay button stays disabled | The order is still loading, cannot be paid by card or did not load (the line under the button says why), or the form is not complete. |
| Need more detail | Set `enableLogging: true` and read `PayriffLogger.onLog` or the Xcode console. |

## Support

- Documentation: [docs.payriff.com](https://docs.payriff.com)
- Issues: [github.com/PayRiff/payriff-ios/issues](https://github.com/PayRiff/payriff-ios/issues)
- Security: see [SECURITY.md](SECURITY.md). Do not report vulnerabilities in public issues.

## License

The Payriff SDK License, the same terms as Payriff.js: you may include the SDK
unmodified in your app to accept payments through Payriff. See
[LICENSE](LICENSE) for the full text.
