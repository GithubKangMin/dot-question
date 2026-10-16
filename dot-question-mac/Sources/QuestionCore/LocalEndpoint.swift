import Foundation

public enum InputError: LocalizedError {
    case endpoint, model, question
    public var errorDescription: String? {
        switch self {
        case .endpoint: return "주소는 http://localhost:11434, http://127.0.0.1:11434 또는 http://[::1]:11434 형태의 로컬 주소여야 합니다. 경로·인증 정보·쿼리는 허용하지 않습니다."
        case .model: return "모델 이름을 입력하세요. 클라우드 모델은 지원하지 않습니다."
        case .question: return "질문을 입력하세요 (최대 30,000자)."
        }
    }
}

public enum LocalEndpoint {
    public static func generateURL(_ raw: String) throws -> URL {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "http", let host = c.host?.lowercased(),
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/",
              c.port == nil || (1...65535).contains(c.port!) else { throw InputError.endpoint }
        // Pin localhost to a numeric loopback address, avoiding DNS/proxy ambiguity.
        if host == "localhost" { c.host = "127.0.0.1" }
        c.path = "/api/generate"
        guard let url = c.url else { throw InputError.endpoint }
        return url
    }
    public static func modelName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128,
              !name.lowercased().contains("cloud"),
              name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil else { throw InputError.model }
        return name
    }
    public static func question(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 30_000 else { throw InputError.question }
        return value
    }
}
