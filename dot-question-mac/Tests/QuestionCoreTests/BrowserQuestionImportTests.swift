import XCTest
@testable import QuestionCore

final class BrowserQuestionImportTests: XCTestCase {
    private func bundle(_ questions: [[String: Any]], context: String = "Shared table: A = 10; B = 20") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": "dot-question/v1", "groups": [["id": "g1", "context": context, "questions": questions]]])
    }
    private func question(_ id: String = "q1", type: String = "short_answer", choices: [[String: String]] = []) -> [String: Any] {
        ["id": id, "type": type, "text": "What is A?", "choices": choices]
    }
    func testTypesAndSharedContextSurviveSelectionAndPrompt() throws {
        let items = try BrowserQuestionImport.parse(bundle([
            question(type: "multiple_choice", choices: [["label": "B", "text": "20"], ["label": "A", "text": "10"]]),
            question("q2"), question("q3", type: "true_false"), question("q4", type: "long_answer")]))
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[1].context, items[0].context)
        let prompt = try StudyPromptBuilder.build(question: items[1].parsed, sources: [])
        XCTAssertEqual(prompt.question.type, .shortAnswer)
        let data = try XCTUnwrap(prompt.user.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["context"] as? String, items[1].context)
        XCTAssertEqual(payload["type"] as? String, "short_answer")
        XCTAssertFalse(prompt.user.contains("q4"))
    }
    func testRejectsDuplicateMissingInvalidAndTruncatedFields() throws {
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([question(), question()])))
        var missing = question(); missing.removeValue(forKey: "text")
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([missing])))
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([question(type: "unknown")])))
        let data = try bundle([question()])
        XCTAssertThrowsError(try BrowserQuestionImport.parse(data.dropLast()))
        var extra = question(); extra["answer"] = "10"
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([extra])))
        let duplicateGroups = "{\"schema\":\"dot-question/v1\",\"groups\":[{\"id\":\"g\",\"context\":\"\",\"questions\":[]},{\"id\":\"g\",\"context\":\"\",\"questions\":[]}]}"
        XCTAssertThrowsError(try BrowserQuestionImport.parse(Data(duplicateGroups.utf8)))
    }
    func testRejectsDuplicateJSONKeysIncludingEscapedKeys() throws {
        let valid = String(decoding: try bundle([question()]), as: UTF8.self)
        let duplicate = valid.replacingOccurrences(of: "\"schema\":", with: "\"schema\":\"dot-question/v1\",\"schema\":")
        XCTAssertThrowsError(try BrowserQuestionImport.parse(Data(duplicate.utf8)))
        let escaped = valid.replacingOccurrences(of: "\"schema\":", with: "\"schema\":\"dot-question/v1\",\"\\u0073chema\":")
        XCTAssertThrowsError(try BrowserQuestionImport.parse(Data(escaped.utf8)))
        let duplicateText = valid.replacingOccurrences(of: "\"text\":", with: "\"text\":\"first\",\"text\":")
        XCTAssertThrowsError(try BrowserQuestionImport.parse(Data(duplicateText.utf8)))
    }
    func testStringBoundsNULAndUnicodeScalars() throws {
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([question(String(repeating: "i", count: 129))])))
        let longLabel = question(type: "multiple_choice", choices: [["label": String(repeating: "L", count: 33), "text": "value"], ["label": "B", "text": "other"]])
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([longLabel])))
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([question()], context: "bad\0context")))
        var nul = question(); nul["text"] = "bad\0text"
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([nul])))
        // Each e + combining accent is two scalar values but one grapheme.
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([question()], context: String(repeating: "e\u{301}", count: 15_001))))
        let valid = try bundle([question()])
        XCTAssertEqual(try BrowserQuestionImport.parse(Data([0xEF, 0xBB, 0xBF]) + valid).count, 1)
    }
    func testLimitsRejectWholeBundleRatherThanTruncating() throws {
        XCTAssertThrowsError(try BrowserQuestionImport.parse(Data(repeating: 32, count: BrowserQuestionImport.maximumBytes + 1)))
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([question()], context: String(repeating: "x", count: 30_001))))
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle((1...51).map { question("q\($0)") })))
        XCTAssertThrowsError(try BrowserQuestionImport.parse(bundle([question(type: "multiple_choice", choices: (1...6).map { ["label": "\($0)", "text": "value"] })])))
        XCTAssertEqual(try BrowserQuestionImport.parse(bundle((1...50).map { question("q\($0)") })).count, 50)
    }
    private func answer(_ choice: String?, warning: String? = nil) throws -> String {
        let payload: [String: Any] = ["selected_choice": choice.map { $0 as Any } ?? NSNull(), "answer": "10", "explanation": "From the table", "citations": [], "uncertainty": warning.map { $0 as Any } ?? NSNull()]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
    func testSubjectiveCopyContainsAnswerOnlyAndUncertaintyNeverCopies() throws {
        for type in [QuestionType.shortAnswer, .longAnswer] {
            let q = ParsedQuestion(text: "A?", choices: [], type: type)
            let result = try StructuredAnswerParser.parse(answer(nil), question: q, sources: [])
            XCTAssertEqual(result.automaticCopyText, "10")
            XCTAssertTrue(result.formattedText.contains("From the table"))
            XCTAssertNil(try StructuredAnswerParser.parse(answer(nil, warning: "unclear"), question: q, sources: []).automaticCopyText)
            XCTAssertThrowsError(try StructuredAnswerParser.parse(answer("1"), question: q, sources: []))
        }
    }
    func testTruthValuesDoNotDependOnChoiceOrder() throws {
        let q = try XCTUnwrap(BrowserQuestionImport.parse(bundle([question(type: "true_false", choices: [["label": "거짓", "text": "False"], ["label": "참", "text": "True"]])])).first).parsed
        for truth in [false, true] {
            let result = try StructuredAnswerParser.parse(answer(truth ? "true" : "false"), question: q, sources: [])
            XCTAssertEqual(result.confirmedChoice, truth ? "true" : "false")
            let state = WifiAnswerState(truth: truth)
            XCTAssertEqual(state.filledBars, truth ? 5 : 0)
            XCTAssertNotEqual(state, .idle)
            XCTAssertNotEqual(state, .unavailable)
            for _ in 0..<100 { XCTAssertEqual(state.filledBars, truth ? 5 : 0) }
        }
        XCTAssertThrowsError(try StructuredAnswerParser.parse(answer("1"), question: q, sources: []))
        XCTAssertNil(try StructuredAnswerParser.parse(answer("true", warning: "uncertain"), question: q, sources: []).confirmedChoice)
        XCTAssertEqual(WifiAnswerState(truth: nil), .unavailable)
    }
}
