import XCTest
import Foundation
@testable import DotQuestion

/// Response-only mocks: no API client instance, credentials, or request execution.
final class APIResponseTests: XCTestCase {
    private let syntheticURL = URL(string: "https://synthetic.invalid/response")!

    private func response(status: Int = 200) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: syntheticURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
    }

    private func payload(message: [String: Any], finishReason: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finishReason]]])
    }

    func testSuccessPreservesModelContentExactly() throws {
        let text = "{\"answer\":\"Mars\",\"explanation\":\"Synthetic response\"}"
        let data = try payload(message: ["content": text])
        XCTAssertEqual(try OpenAIClient.decodeResponse(data: data, response: response(), error: nil), text)
    }

    func testRefusalIsReturnedWhenContentIsNull() throws {
        let refusal = "Synthetic refusal for parser testing."
        let data = try payload(message: ["content": NSNull(), "refusal": refusal])
        XCTAssertEqual(try OpenAIClient.decodeResponse(data: data, response: response(), error: nil), refusal)
    }

    func testOutputLimitAppendsTruncationNotice() throws {
        let data = try payload(message: ["content": "Partial synthetic answer"], finishReason: "length")
        XCTAssertEqual(try OpenAIClient.decodeResponse(data: data, response: response(), error: nil),
                       "Partial synthetic answer\n\n[출력 한도로 답변이 잘렸습니다.]")
    }

    func testEmptyContentIsRejected() throws {
        let messages: [[String: Any]] = [["content": ""], ["content": NSNull()], [:]]
        for message in messages {
            let data = try payload(message: message)
            XCTAssertThrowsError(try OpenAIClient.decodeResponse(data: data, response: response(), error: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains("응답이 비어 있습니다."))
            }
        }
    }

    func testMalformedOrAbsentPayloadIsRejected() throws {
        let samples: [Data?] = [nil, Data(), Data("not JSON".utf8), Data("{}".utf8), Data("{\"choices\":[]}".utf8),
                               Data("{\"choices\":[{\"message\":{\"content\":42}}]}".utf8)]
        for data in samples {
            XCTAssertThrowsError(try OpenAIClient.decodeResponse(data: data, response: response(), error: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains("API 응답 형식이 예상과 다릅니다."))
            }
        }
    }

    func testHTTPFailuresUseOnlySanitizedStatusHints() throws {
        let providerDetail = "synthetic private provider diagnostic that must never reach the UI"
        let data = try JSONSerialization.data(withJSONObject: ["error": ["message": providerDetail]])
        let expectedHints = [401: "API 키를 확인하세요.", 403: "계정/모델 접근 권한을 확인하세요.",
                             404: "이 계정에서 사용 가능한 Chat Completions 모델명을 확인하세요.",
                             429: "할당량, 결제 또는 요청 한도를 확인하세요.",
                             500: "공식 API 상태와 모델 호환성을 확인하세요."]
        for (status, hint) in expectedHints {
            XCTAssertThrowsError(try OpenAIClient.decodeResponse(data: data, response: response(status: status), error: nil)) { error in
                XCTAssertEqual(error.localizedDescription, "OpenAI API 오류 \(status). \(hint)")
                XCTAssertFalse(error.localizedDescription.contains(providerDetail))
            }
        }
    }

    func testTransportErrorIsPreservedAndMissingHTTPResponseIsRejected() throws {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertThrowsError(try OpenAIClient.decodeResponse(data: nil, response: nil, error: timeout)) { error in
            XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
            XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut)
        }
        XCTAssertThrowsError(try OpenAIClient.decodeResponse(data: nil, response: nil, error: nil)) { error in
            XCTAssertEqual(error.localizedDescription, "API 서버 응답이 없습니다.")
        }
        let nonHTTP = URLResponse(url: syntheticURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertThrowsError(try OpenAIClient.decodeResponse(data: nil, response: nonHTTP, error: nil))
    }

    func testRedirectDelegateRejectsRedirectWithoutExecutingTask() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // URLSession creates tasks suspended. This task is never resumed.
        let task = session.dataTask(with: syntheticURL)
        defer { task.cancel() }
        XCTAssertEqual(task.state, .suspended)
        let delegate = NoRedirectDelegate()
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: try response(status: 302),
                            newRequest: URLRequest(url: URL(string: "https://redirect-target.invalid/")!)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
        XCTAssertEqual(task.state, .suspended)
    }
}
