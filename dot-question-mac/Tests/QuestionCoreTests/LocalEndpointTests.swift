import XCTest
@testable import QuestionCore
final class LocalEndpointTests: XCTestCase {
    func testLoopbackOnly() throws {
        XCTAssertEqual(try LocalEndpoint.generateURL("http://localhost:11434").absoluteString, "http://127.0.0.1:11434/api/generate")
        XCTAssertEqual(try LocalEndpoint.generateURL("http://127.0.0.1:11434/").path, "/api/generate")
        XCTAssertNoThrow(try LocalEndpoint.generateURL("http://[::1]:11434"))
        for bad in ["https://example.com", "http://localhost.evil.test:11434", "http://127.0.0.2", "http://user@localhost:11434", "http://localhost:11434/a", "http://localhost:11434?x=a", "http://localhost:11434#x", "http://localhost:0", "file:///tmp/a"] {
            XCTAssertThrowsError(try LocalEndpoint.generateURL(bad), bad)
        }
    }
    func testModelValidation() throws {
        XCTAssertEqual(try LocalEndpoint.modelName(" qwen3:4b-instruct "), "qwen3:4b-instruct")
        for bad in ["", "qwen:cloud", "qwen-cloud", "bad name", "bad\nname"] { XCTAssertThrowsError(try LocalEndpoint.modelName(bad)) }
    }
    func testQuestionValidation() throws {
        XCTAssertEqual(try LocalEndpoint.question(" 안녕 \n"), "안녕")
        XCTAssertThrowsError(try LocalEndpoint.question(" \n"))
        XCTAssertThrowsError(try LocalEndpoint.question(String(repeating: "가", count: 30_001)))
    }
}
