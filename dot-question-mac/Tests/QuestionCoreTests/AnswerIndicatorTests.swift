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

    func testWifiIdlePendingAndUnavailableKeepZeroFilledBars() {
        for state in [WifiAnswerState.idle, .pending, .unavailable] {
            XCTAssertEqual(state.filledBars, 0)
        }
    }

    func testWifiSequentialCommandsClearThenRetainEachAnswer() {
        let options = (1...5).map(String.init)
        var state = WifiAnswerState.idle
        var observed = [state.filledBars]
        for choice in ["2", "3", "5"] {
            state = .pending
            XCTAssertEqual(state.filledBars, 0, "A new command must clear the previous answer immediately.")
            state = WifiAnswerState(choice: choice, options: options)
            observed.append(state.filledBars)
            let retained = state
            // Rendering is read-only; the value has no clock or expiry transition.
            for _ in 0..<100 {
                XCTAssertEqual(state.filledBars, Int(choice))
                XCTAssertEqual(state, retained)
            }
            if choice != "5" { observed.append(WifiAnswerState.pending.filledBars) }
        }
        XCTAssertEqual(observed, [0, 2, 0, 3, 0, 5])
    }

    func testWifiUncertainMalformedAndOutOfRangeAnswersUseZero() {
        let options = (1...10).map(String.init)
        XCTAssertEqual(WifiAnswerState(choice: "3", options: options, uncertain: true), .unavailable)
        XCTAssertEqual(WifiAnswerState(choice: nil, options: options), .unavailable)
        XCTAssertEqual(WifiAnswerState(choice: "11", options: options), .unavailable)
        XCTAssertEqual(WifiAnswerState(choice: "1", options: ["1", "1"]), .unavailable)
        for ordinal in 1...10 {
            XCTAssertEqual(WifiAnswerState(choice: String(ordinal), options: options).filledBars, ordinal <= 5 ? ordinal : 0)
        }
        XCTAssertEqual(WifiAnswerState(choice: "③", options: ["①", "②", "③"]).filledBars, 3)
    }
}
