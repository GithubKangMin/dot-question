import XCTest
@testable import QuestionCore

final class RequestOriginTests: XCTestCase {
    func testQuickNeverRevealsWindow() {
        XCTAssertFalse(RequestOrigin.quick.shouldRevealWindow)
    }
    func testManualRetainsReviewWindow() {
        XCTAssertTrue(RequestOrigin.manual.shouldRevealWindow)
    }
    func testAutomaticSendIsLocalQuickOnly() {
        XCTAssertTrue(RequestOrigin.quick.allowsAutomaticSend(usingAPI: false))
        XCTAssertFalse(RequestOrigin.quick.allowsAutomaticSend(usingAPI: true))
        XCTAssertFalse(RequestOrigin.manual.allowsAutomaticSend(usingAPI: false))
        XCTAssertFalse(RequestOrigin.manual.allowsAutomaticSend(usingAPI: true))
    }
}
