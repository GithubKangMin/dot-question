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
    func testSchemaRequiresNonemptyAnswerAndExplanation() throws {
        let schema = OllamaClient.answerSchema(questionPayload: "{\"allowed_choice_labels\":[\"1\",\"2\"],\"sources\":[]}")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])
        for field in ["answer", "explanation"] {
            let contract = try XCTUnwrap(properties[field] as? [String: Any])
            XCTAssertEqual(contract["type"] as? String, "string")
            XCTAssertEqual(contract["minLength"] as? Int, 1)
            XCTAssertTrue(required.contains(field))
        }
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
    func testSchemaConstrainsIdentifiersWithoutChoosingAnswer() throws {
        let schema = OllamaClient.answerSchema(questionPayload: "{\"allowed_choice_labels\":[\"A\",\"B\",\"C\"],\"sources\":[]}")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let choice = try XCTUnwrap(properties["selected_choice"] as? [String: Any])
        let values = try XCTUnwrap(choice["enum"] as? [Any])
        XCTAssertEqual(values.compactMap { $0 as? String }, ["A", "B", "C"])
        XCTAssertTrue(values.last is NSNull)
        let citations = try XCTUnwrap(properties["citations"] as? [String: Any])
        XCTAssertEqual(citations["maxItems"] as? Int, 0)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }
    func testSchemaAllowsOnlyProvidedSourceIDs() throws {
        let schema = OllamaClient.answerSchema(questionPayload: "{\"allowed_choice_labels\":[],\"sources\":[{\"id\":\"synthetic-1\"}]}")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let citations = try XCTUnwrap(properties["citations"] as? [String: Any])
        let items = try XCTUnwrap(citations["items"] as? [String: Any])
        XCTAssertEqual(items["enum"] as? [String], ["synthetic-1"])
    }
    func testInstalledModelPreflightThenSyntheticResponse() throws {
        let (result, paths) = try run(tags: "{\"models\":[{\"name\":\"synthetic:latest\"}]}")
        XCTAssertEqual(try result.get(), "synthetic answer")
        XCTAssertEqual(paths, ["/api/tags", "/api/generate"])
    }
    func testCancellationDuringPreflightSuppressesCompletion() throws {
        let api = client()
        MockOllamaProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            return (200, Data("{\"models\":[{\"name\":\"synthetic:latest\"}]}".utf8))
        }
        let unexpected = expectation(description: "Cancelled callback must not be published")
        unexpected.isInverted = true
        try api.answer(endpoint: "http://127.0.0.1:11434", model: "synthetic:latest", question: "Synthetic", system: "") { _ in unexpected.fulfill() }
        api.cancel()
        wait(for: [unexpected], timeout: 0.3)
        withExtendedLifetime(api) {}
    }
    func testCancellationDuringGenerationSuppressesLateResponse() throws {
        let api = client()
        let generated = expectation(description: "Generation reached")
        MockOllamaProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                return (200, Data("{\"models\":[{\"name\":\"synthetic:latest\"}]}".utf8))
            }
            DispatchQueue.main.async { api.cancel(); generated.fulfill() }
            return (200, Data("{\"response\":\"late synthetic answer\"}".utf8))
        }
        let unexpected = expectation(description: "Late answer must not be published")
        unexpected.isInverted = true
        try api.answer(endpoint: "http://127.0.0.1:11434", model: "synthetic:latest", question: "Synthetic", system: "") { _ in unexpected.fulfill() }
        wait(for: [generated], timeout: 5)
        wait(for: [unexpected], timeout: 0.3)
        withExtendedLifetime(api) {}
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
