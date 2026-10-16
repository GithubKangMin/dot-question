import XCTest
@testable import QuestionCore

final class AnswerIndicatorTests: XCTestCase {
    func testAllTenChoicesHaveDistinctBatteryEncoding() {
        let options = (1...10).map(String.init)
        for ordinal in 1...10 {
            let result = AnswerIndicator(choice: String(ordinal), options: options)
            XCTAssertEqual(result?.ordinal, ordinal)
            XCTAssertEqual(result?.batteryPercent, ordinal * 10)
            XCTAssertEqual(result?.wifiBars, ordinal <= 5 ? ordinal : nil)
        }
    }
    func testMapsPositionRatherThanLabel() {
        for options in [["A", "B", "C"], ["①", "②", "③"], ["ㄱ", "ㄴ", "ㄷ"]] {
            XCTAssertEqual(AnswerIndicator(choice: options[1], options: options)?.ordinal, 2)
            XCTAssertEqual(AnswerIndicator(choice: options[1], options: options)?.batteryPercent, 20)
        }
    }
    func testUnknownAndMalformedChoicesHaveNoSignal() {
        XCTAssertNil(AnswerIndicator(choice: nil, options: ["1", "2"]))
        XCTAssertNil(AnswerIndicator(choice: "3", options: ["1", "2"]))
        XCTAssertNil(AnswerIndicator(choice: "1", options: []))
        XCTAssertNil(AnswerIndicator(choice: "1", options: ["1"]))
        XCTAssertNil(AnswerIndicator(choice: "1", options: ["1", "1"]))
        XCTAssertNil(AnswerIndicator(choice: "1", options: (1...11).map(String.init)))
    }
}
