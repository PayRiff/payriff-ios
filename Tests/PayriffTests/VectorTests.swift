import Foundation
import Testing
@testable import Payriff

/// Every case of every section of `spec/vectors/*.json` (CONTRACT §5, §8, §10, §16).
@Suite("Shared test vectors")
struct VectorTests {
    @Test("Every vector file and section is bundled, covered here (or pinned as pending), and every case decodes")
    func everySectionIsCovered() throws {
        // A new file or a new section in spec/vectors fails here until a test covers it, and so
        // does an archived hosted-flow file (CONTRACT revision 5) that is bundled again.
        #expect(try Vectors.bundledFileNames() == Vectors.knownFileNames)
        for archived in ["api", "navigation", "payment_url_order_id", "amount"] {
            #expect(!Vectors.knownFileNames.contains(archived), "\(archived).json is archived")
        }
        #expect(Set(Vectors.coveredSections.keys).isDisjoint(with: Vectors.pendingSections.keys), "a file is covered or pending, never both")
        for (name, sections) in Vectors.coveredSections {
            #expect(try Vectors.topLevelKeys(name) == sections, "sections of \(name).json")
        }
        // Files no code implements yet are pinned: their sections must not change unnoticed, and
        // every list in them must have entries.
        for (name, sections) in Vectors.pendingSections {
            #expect(try Vectors.topLevelKeys(name) == sections, "sections of pending \(name).json")
            let object = try #require(try JSONSerialization.jsonObject(with: Vectors.data(name)) as? [String: Any])
            for (key, value) in object {
                if let list = value as? [Any] { #expect(!list.isEmpty, "\(name).json \(key)") }
            }
        }
        // Decoding problems must not silently shrink a parameterized test.
        let caseCounts: [(String, Int)] = [
            ("status", Vectors.status.count),
            ("language", Vectors.language.count),
            ("result_json", Vectors.resultJSON.count),
        ]
        for (name, count) in caseCounts {
            let raw = try Vectors.rawCount(name, key: "cases")
            #expect(count > 0 && count == raw, "cases of \(name).json")
        }
        #expect(!Vectors.strings.isEmpty)
    }

    // MARK: status.json

    @Test("status.json", arguments: Vectors.status)
    func status(_ vector: StatusVector) {
        let status = PayriffPaymentStatus(rawStatus: vector.raw)
        #expect(status.rawValue == vector.status)
        let (outcome, reason) = Self.describe(status.outcome)
        #expect(outcome == vector.outcome)
        #expect(reason == vector.cancelReason)
        #expect(status.isFinal == (vector.outcome != "nonFinal"))
    }

    private static func describe(_ outcome: StatusOutcome) -> (String, String?) {
        switch outcome {
        case .success: return ("success", nil)
        case .declined: return ("declined", nil)
        case .cancelled(let reason): return ("cancelled", reason.rawValue)
        case .unexpectedFinal: return ("unexpectedFinal", nil)
        case .nonFinal: return ("nonFinal", nil)
        }
    }

    // MARK: language.json

    @Test("language.json", arguments: Vectors.language)
    func language(_ vector: LanguageVector) {
        #expect(PayriffLanguage(localeIdentifier: vector.locale).rawValue == vector.expected)
    }

    // MARK: strings.json

    @Test("strings.json: every text of the 3-D Secure sheet equals the vector exactly (CONTRACT §10)")
    func strings() {
        // The sheet carries only the keys it uses (CONTRACT revision 5); the vector keeps the
        // hosted flow's keys for the other SDKs.
        #expect(Set(PayriffStrings.Key.allCases.map(\.rawValue)) == [
            "title", "verifying", "close", "retry", "cancel_confirm_title", "cancel_confirm_message",
            "cancel_confirm_yes", "cancel_confirm_no", "page_load_error",
        ])
        #expect(Set(PayriffStrings.table.keys) == Set(PayriffStrings.Key.allCases))
        for key in PayriffStrings.Key.allCases {
            let expected = Vectors.strings[key.rawValue]
            #expect(expected != nil, "\(key.rawValue) is in strings.json")
            let table = PayriffStrings.table[key].map { values in
                Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue.lowercased(), $0.value) })
            }
            #expect(table == expected, "string \(key.rawValue)")
            for language in PayriffLanguage.allCases {
                let text = PayriffStrings(language: language)[key]
                #expect(text == expected?[language.rawValue.lowercased()], "\(key.rawValue) \(language.rawValue)")
            }
        }
    }

    // MARK: result_json.json

    @Test("result_json.json: the result serializes to exactly the shared JSON", arguments: Vectors.resultJSON)
    func resultJSON(_ vector: ResultJSONVector) throws {
        // A case with an error code that only the removed hosted flow produced keeps its shape
        // with PAYMENT_FAILED (``JSONAny/replacingRemovedErrorCode``).
        let json = vector.json.replacingRemovedErrorCode
        let result = try PayriffResult(vectorJSON: json)
        // The cases predate revision 4, whose payments always carry `originalOrderId`
        // (null without an order switch, CONTRACT §16.0 item 2); every other key is unchanged.
        let expected = json.addingNullOriginalOrderId
        // Encodable
        let encoded = try JSONAny.parse(JSONEncoder().encode(result))
        #expect(encoded == expected, "Encodable: \(encoded) != \(expected)")
        // jsonObject, through JSONSerialization
        let object = try JSONAny.parse(JSONSerialization.data(withJSONObject: result.jsonObject))
        #expect(object == expected, "jsonObject: \(object) != \(expected)")
    }

    @Test("result_json.json: only codes of the removed hosted flow are replaced, and only the code")
    func resultJSONRemovedCodes() throws {
        let replaced = Vectors.resultJSON.filter { $0.json.replacingRemovedErrorCode != $0.json }
        #expect(replaced.map(\.name) == ["failed with a full error"], "API_ERROR is the only removed code in the vector")
        for vector in replaced {
            guard case .object(var members) = vector.json.replacingRemovedErrorCode,
                  case .object(var error)? = members["error"] else {
                Issue.record("\(vector.name): not a failed result")
                continue
            }
            #expect(error["code"] == .string("PAYMENT_FAILED"))
            error["code"] = vector.json.objectValue?["error"]?.objectValue?["code"]
            members["error"] = .object(error)
            #expect(JSONAny.object(members) == vector.json, "\(vector.name): every other key is unchanged")
        }
    }

    @Test("result_json.json with an order switch: originalOrderId is present and keeps its value (CONTRACT §16.0 item 2)", arguments: Vectors.resultJSON)
    func resultJSONWithOriginalOrderId(_ vector: ResultJSONVector) throws {
        guard case .object(var members) = vector.json, case .object(var payment)? = members["payment"] else { return }
        payment["originalOrderId"] = .string("o0")
        members["payment"] = .object(payment)
        let json = JSONAny.object(members)
        let result = try PayriffResult(vectorJSON: json)
        #expect(result.payment?.originalOrderId == "o0")
        #expect(try JSONAny.parse(JSONEncoder().encode(result)) == json)
        #expect(try JSONAny.parse(JSONSerialization.data(withJSONObject: result.jsonObject)) == json)
    }
}
