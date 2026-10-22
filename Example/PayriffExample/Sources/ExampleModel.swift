import Foundation
import Payriff
import SwiftUI
import UIKit

/// A finished payment shown in a sheet.
struct PresentedResult: Identifiable {
    let id = UUID()
    let result: PayriffResult
}

/// Where the payment view appears. All three show the same `PayriffPaymentScreen`; only the
/// container differs.
enum PaymentPresentation: String, CaseIterable, Identifiable {
    case page = "Pay in page"
    case bottomSheet = "Pay in bottom sheet"
    case popup = "Pay in popup"

    var id: String { rawValue }
}

/// The example's state: the order your server created and the presentation on screen. The app
/// never creates orders and never holds a secret key.
@MainActor
final class ExampleModel: ObservableObject {
    /// Compiled in from `Example/Config/*.xcconfig` (the publishable key, the environment).
    let settings = ExampleSettings.fromInfoPlist()

    @Published var orderId = ""
    @Published var clientSecret = ""
    @Published private(set) var pasteError: String?

    @Published var presentation: PaymentPresentation?
    @Published var presentedResult: PresentedResult?

    init() {
        PayriffLogger.onLog = { entry in
            #if DEBUG
            Task { @MainActor in Self.appendToLogFile(entry.formatted) }
            #endif
        }
        Payriff.configure(settings.config)
    }

    /// Whether the publishable key and both order values are there.
    var canPay: Bool {
        settings.hasPublishableKey && !Self.trimmed(orderId).isEmpty && !Self.trimmed(clientSecret).isEmpty
    }

    var trimmedOrderId: String { Self.trimmed(orderId) }
    var trimmedClientSecret: String { Self.trimmed(clientSecret) }

    /// Fills both fields from the clipboard: the `{"orderId", "clientSecret"}` JSON your server
    /// returns for a new order, or the two values separated by white space.
    func pasteOrder() {
        guard let pasted = Self.parsePastedOrder(UIPasteboard.general.string ?? "") else {
            pasteError = "The clipboard has no order. Copy the orderId and clientSecret your server returned."
            return
        }
        pasteError = nil
        orderId = pasted.orderId
        clientSecret = pasted.clientSecret
    }

    /// The payment view's result: closes the presentation and opens the result sheet. An order
    /// is paid once, so it is forgotten after every result except a failure.
    func finish(_ result: PayriffResult) {
        presentation = nil
        if case .failed = result {} else {
            orderId = ""
            clientSecret = ""
        }
        // Let the payment view's container go away before the result sheet comes up.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            presentedResult = PresentedResult(result: result)
        }
    }

    /// The order in pasted text: a JSON object with the strings `orderId` and `clientSecret`, or
    /// exactly two values separated by white space. `nil` when the text holds no order.
    nonisolated static func parsePastedOrder(_ text: String) -> (orderId: String, clientSecret: String)? {
        let text = trimmed(text)
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let orderId = trimmed(object["orderId"] as? String ?? "")
            let clientSecret = trimmed(object["clientSecret"] as? String ?? "")
            return orderId.isEmpty || clientSecret.isEmpty ? nil : (orderId, clientSecret)
        }
        let parts = text.split(whereSeparator: \.isWhitespace)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    }

    /// An amount as on Payriff's screens: two decimals, a `.` and the currency code (`10.50 AZN`).
    nonisolated static func amountText(_ amount: Decimal, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        let number = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        return "\(number) \(currency ?? "")".trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if DEBUG
    /// Debug builds keep the SDK log in Documents/payriff-sdk.log, so it can be read from a
    /// device: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
    /// --domain-identifier com.payriff.example.ios --source Documents/payriff-sdk.log
    /// --destination payriff-sdk.log`. The SDK redacts every secret (CONTRACT §11).
    private static let logFile = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("payriff-sdk.log")

    private static func appendToLogFile(_ line: String) {
        guard let url = logFile, let data = (line + "\n").data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
    #endif
}
