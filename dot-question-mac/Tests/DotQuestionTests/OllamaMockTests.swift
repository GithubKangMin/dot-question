import XCTest
import Foundation
@testable import DotQuestion

private final class MockOllamaProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// URLProtocol handles every request in memory: no server, model or network.
final class OllamaMockTests: XCTestCase {
    override func tearDown() { MockOllamaProtocol.handler = nil }
    private func client() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOllamaProtocol.self]
        return OllamaClient(configuration: configuration)
    }
    private func run(tags: String, status: Int = 200, generation: String = "{\"response\":\"synthetic answer\"}") throws -> (Result<String, Error>, [String]) {
        var paths: [String] = []
        MockOllamaProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            let path = request.url!.path
            paths.append(path)
            if path == "/api/tags" { return (200, Data(tags.utf8)) }
            XCTAssertEqual(request.httpMethod, "POST")
            return (status, Data(generation.utf8))
        }
        let api = client()
        let done = expectation(description: "Mock local response")
        var outcome: Result<String, Error>?
        try api.answer(endpoint: "http://localhost:11434", model: "synthetic:latest", question: "Which planet is red?", system: "Use synthetic evidence.") {
            outcome = $0; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        withExtendedLifetime(api) {}
        return (try XCTUnwrap(outcome), paths)
    }
    func testInstalledModelPreflightThenSyntheticResponse() throws {
        let (result, paths) = try run(tags: "{\"models\":[{\"name\":\"synthetic:latest\"}]}")
        XCTAssertEqual(try result.get(), "synthetic answer")
        XCTAssertEqual(paths, ["/api/tags", "/api/generate"])
    }
    func testMissingAndRemoteModelsNeverGenerate() throws {
        for tags in ["{\"models\":[]}", "{\"models\":[{\"name\":\"synthetic:latest\",\"remote_host\":\"invalid.example\"}]}", "{\"models\":[{\"name\":\"synthetic:latest\",\"remote_model\":\"remote\"}]}"] {
            let (result, paths) = try run(tags: tags)
            XCTAssertThrowsError(try result.get())
            XCTAssertEqual(paths, ["/api/tags"])
        }
    }
    func testHTTPErrorAndEmptyResponseAreFailures() throws {
        let tags = "{\"models\":[{\"name\":\"synthetic:latest\"}]}"
        let (failure, _) = try run(tags: tags, status: 500, generation: "{\"error\":\"synthetic failure\"}")
        XCTAssertThrowsError(try failure.get())
        let (empty, _) = try run(tags: tags, generation: "{\"response\":\"\"}")
        XCTAssertThrowsError(try empty.get())
    }
    func testRemoteEndpointAndOversizedContextRejectedBeforeTransport() {
        let api = client()
        MockOllamaProtocol.handler = { _ in XCTFail("No request should be created"); throw URLError(.badURL) }
        XCTAssertThrowsError(try api.answer(endpoint: "https://invalid.example", model: "synthetic", question: "Synthetic", system: "") { _ in XCTFail("No completion expected") })
        XCTAssertThrowsError(try api.answer(endpoint: "http://127.0.0.1:11434", model: "synthetic", question: "Synthetic", system: String(repeating: "x", count: 14_001)) { _ in XCTFail("No completion expected") })
    }
}
