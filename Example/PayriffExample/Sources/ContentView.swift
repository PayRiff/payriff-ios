import Payriff
import SwiftUI

/// The only screen: the order your server created, and three ways to show the SDK's payment
/// view (`PayriffPaymentScreen`): pushed as a page, in a bottom sheet as tall as the view, or in
/// a popup.
struct ContentView: View {
    @EnvironmentObject private var model: ExampleModel
    /// The payment view's fitting height, which sizes the bottom sheet once the view reports it.
    @State private var sheetHeight: CGFloat?

    var body: some View {
        NavigationStack {
            Form {
                if !model.settings.hasPublishableKey {
                    Section {
                        Text("Add PAYRIFF_PUBLISHABLE_KEY to Example/Config/Secrets.xcconfig and build again.")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("orderId", text: $model.orderId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("clientSecret", text: $model.clientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste", systemImage: "doc.on.clipboard", action: model.pasteOrder)
                    if let error = model.pasteError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Order from your backend")
                }
                Section {
                    ForEach(PaymentPresentation.allCases) { presentation in
                        Button(presentation.rawValue) { model.presentation = presentation }
                            .disabled(!model.canPay)
                    }
                }
            }
            .navigationTitle("Payriff")
            .navigationDestination(isPresented: binding(for: .page)) {
                paymentScreen
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: binding(for: .bottomSheet)) {
            paymentScreen
                .onFittingHeightChange { sheetHeight = $0 }
                // As tall as the payment view; full height until the view reports its height.
                .presentationDetents([sheetHeight.map { .height($0) } ?? .large])
                .presentationDragIndicator(.visible)
        }
        .overlay {
            if model.presentation == .popup {
                PopupContainer(onClose: { model.presentation = nil }) { paymentScreen }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.presentation == .popup)
        .sheet(item: $model.presentedResult) { presented in
            NavigationStack {
                List { ResultDetails(result: presented.result) }
                    .navigationTitle("Result")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The SDK's default payment view for the entered order; its result closes the presentation.
    private var paymentScreen: PayriffPaymentScreen {
        PayriffPaymentScreen(
            orderId: model.trimmedOrderId,
            clientSecret: model.trimmedClientSecret,
            onResult: { model.finish($0) }
        )
    }

    private func binding(for presentation: PaymentPresentation) -> Binding<Bool> {
        Binding(
            get: { model.presentation == presentation },
            set: { if !$0, model.presentation == presentation { model.presentation = nil } }
        )
    }
}

/// A centred card over a dimmed screen, closed with its ✕ or a tap outside.
private struct PopupContainer<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            content()
                .padding(.top, 28)
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    .accessibilityLabel("Close")
                }
                // The payment view's own background, light and dark, so the close strip matches it.
                .background(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
                    ? UIColor(red: 0x22 / 255, green: 0x22 / 255, blue: 0x24 / 255, alpha: 1)
                    : UIColor(red: 0xFC / 255, green: 0xFC / 255, blue: 0xFD / 255, alpha: 1) }))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 440, maxHeight: 640)
                .padding(16)
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        }
    }
}

/// The rows of a payment result, with its shared JSON (CONTRACT §5.3).
struct ResultDetails: View {
    let result: PayriffResult

    var body: some View {
        row("Variant", variant)
        if let payment = result.payment {
            row("Order", payment.orderId)
            row("Status", payment.status.rawValue)
            row("Raw status", payment.rawStatus ?? "—")
            row("Amount", payment.amount.map { ExampleModel.amountText($0, currency: payment.currency) } ?? "—")
        }
        if let error = result.error {
            row("Error code", error.code.rawValue)
            row("Message", error.message)
            if error.isFatal { row("Fatal", "Create a new order") }
            if let payriffCode = error.payriffCode { row("Payriff code", payriffCode) }
            if let httpStatus = error.httpStatus { row("HTTP status", String(httpStatus)) }
            if let ticket = error.supportTicket { row("Support ticket", ticket) }
        }
        Text(json)
            .font(.caption.monospaced())
            .textSelection(.enabled)
    }

    private var variant: String {
        switch result {
        case .cancelled(_, let reason): return "cancelled (\(reason.rawValue))"
        case .pending(_, let reason): return "pending (\(reason.rawValue))"
        default: return result.type
        }
    }

    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(result)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
