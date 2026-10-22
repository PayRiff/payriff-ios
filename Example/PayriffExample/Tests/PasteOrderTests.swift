import Foundation
import Testing
@testable import PayriffExample

/// Paste on the example's screen: it reads the `{"orderId", "clientSecret"}` JSON your server
/// returns for a new order, and the result sheet shows amounts like Payriff does.
@Suite("Paste order")
struct PasteOrderTests {
    @Test("The clipboard holds {orderId, clientSecret} as JSON, or the two values separated by white space")
    func parsesOrders() {
        let json = ExampleModel.parsePastedOrder(#"{"orderId": "ORD-1", "clientSecret": "pr_cs_abc"}"#)
        #expect(json?.orderId == "ORD-1")
        #expect(json?.clientSecret == "pr_cs_abc")
        let spaced = ExampleModel.parsePastedOrder("  ORD-2\n\tpr_cs_def \n")
        #expect(spaced?.orderId == "ORD-2")
        #expect(spaced?.clientSecret == "pr_cs_def")
        let refused = [
            "",
            "ORD-3",
            "ORD-3 pr_cs_ghi extra",
            #"{"orderId": "ORD-4"}"#,
            #"{"orderId": 5, "clientSecret": "pr_cs_jkl"}"#,
            #"{"orderId": " ", "clientSecret": "pr_cs_mno"}"#,
        ]
        for text in refused {
            #expect(ExampleModel.parsePastedOrder(text) == nil, "\(text)")
        }
    }

    @Test("Amounts show two decimals, a dot and the currency")
    func amounts() throws {
        #expect(ExampleModel.amountText(try #require(Decimal(string: "10.5")), currency: "AZN") == "10.50 AZN")
        #expect(ExampleModel.amountText(try #require(Decimal(string: "1234")), currency: nil) == "1234.00")
    }
}
