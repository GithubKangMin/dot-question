import Foundation
import QuestionCore

/// Only the official HTTPS endpoint is supported. The key lives in memory only.
final class OpenAIClient {
    private let delegate = NoRedirectDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private var task: URLSessionDataTask?
    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String?; let refusal: String? }
            let message: Message
            let finish_reason: String?
        }
        struct APIError: Decodable { let message: String }
        let choices: [Choice]?
        let error: APIError?
    }
    func answer(key: String, model: String, question: String, system: String, completion: @escaping (Result<String, Error>) -> Void) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = try LocalEndpoint.question(question)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw AppError(message: "앱의 보안 입력칸에 OpenAI API 키를 입력하세요. 채팅으로 보내지 마세요.") }
        guard !model.isEmpty, model.count <= 128 else { throw AppError(message: "API 모델 이름을 입력하세요.") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "store": false, "max_completion_tokens": 2048,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": question]
            ]
        ])
        task = session.dataTask(with: request) { data, response, error in
            let result = Result<String, Error> {
                try Self.decodeResponse(data: data, response: response, error: error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task?.resume()
    }

    /// Pure response handling, shared by the request callback and offline mock tests.
    static func decodeResponse(data: Data?, response: URLResponse?, error: Error?) throws -> String {
        if let error { throw error }
        guard let http = response as? HTTPURLResponse else { throw AppError(message: "API 서버 응답이 없습니다.") }
        let decoded = data.flatMap { try? JSONDecoder().decode(Response.self, from: $0) }
        guard (200..<300).contains(http.statusCode) else {
            // Do not display raw API errors which can contain fragments of credentials.
            let hint: String
            switch http.statusCode {
            case 401: hint = "API 키를 확인하세요."
            case 403: hint = "계정/모델 접근 권한을 확인하세요."
            case 404: hint = "이 계정에서 사용 가능한 Chat Completions 모델명을 확인하세요."
            case 429: hint = "할당량, 결제 또는 요청 한도를 확인하세요."
            default: hint = "공식 API 상태와 모델 호환성을 확인하세요."
            }
            throw AppError(message: "OpenAI API 오류 \(http.statusCode). \(hint)")
        }
        guard let choice = decoded?.choices?.first else { throw AppError(message: "API 응답 형식이 예상과 다릅니다.") }
        let text = choice.message.content ?? choice.message.refusal ?? ""
        guard !text.isEmpty else { throw AppError(message: "응답이 비어 있습니다. 모델과 출력 한도를 확인하세요.") }
        return text + (choice.finish_reason == "length" ? "\n\n[출력 한도로 답변이 잘렸습니다.]" : "")
    }

    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel(); session.invalidateAndCancel() }
}
