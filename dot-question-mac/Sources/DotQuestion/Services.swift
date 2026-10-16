import Foundation
import AppKit
import Vision
import QuestionCore

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ScreenshotService {
    private var process: Process?
    private var directory: URL?
    func capture(rect: CGRect? = nil, completion: @escaping (Result<URL?, Error>) -> Void) {
        guard process == nil else { return }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DotQuestion-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = dir
            let file = dir.appendingPathComponent("capture.png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            if let rect {
                p.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", "-t", "png", file.path]
            } else {
                p.arguments = ["-i", "-s", "-x", "-t", "png", file.path]
            }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] p in
                DispatchQueue.main.async {
                    self?.process = nil
                    if FileManager.default.fileExists(atPath: file.path) {
                        completion(.success(file))
                    } else {
                        self?.cleanup()
                        if p.terminationStatus == 0 || p.terminationStatus == 1 || p.terminationReason == .uncaughtSignal {
                            completion(.success(nil))
                        } else { completion(.failure(AppError(message: "캡처 실패. 화면 기록 권한을 확인하세요."))) }
                    }
                }
            }
            process = p
            try p.run()
        } catch { process = nil; cleanup(); completion(.failure(error)) }
    }
    func cancel() { if process?.isRunning == true { process?.terminate() } }
    func cleanup() { if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil }
    deinit { cancel(); cleanup() }
}

enum OCRService {
    static func recognize(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<String, Error> {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let supported = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = ["ko-KR", "en-US"].filter { supported.contains($0) }
                guard !request.recognitionLanguages.isEmpty else { throw AppError(message: "이 macOS에서 지원되는 OCR 언어가 없습니다.") }
                let handler = VNImageRequestHandler(url: url, options: [:])
                try handler.perform([request])
                let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRLine(text: candidate.string, bounds: observation.boundingBox)
                }
                let original = lines.map(\.text).joined(separator: "\n")
                guard OCRNumericChoiceNormalizer.needsVerification(lines.map(\.text)) else { return original }
                // Accurate recognition has word-precision boxes, even for a
                // one-character range. Only the fast pass supplies character
                // geometry; its wording is never substituted into the result.
                let verification = VNRecognizeTextRequest()
                verification.recognitionLevel = .fast
                verification.usesLanguageCorrection = false
                do {
                    let languages = try verification.supportedRecognitionLanguages()
                    guard languages.contains("en-US") else {
                        saveNumericDiagnostics(lines, result: original, error: "Fast OCR does not support en-US.")
                        return original
                    }
                    verification.recognitionLanguages = ["en-US"]
                    try handler.perform([verification])
                    let checked = lines.map { line in
                        OCRLine(text: line.text, bounds: line.bounds,
                                verificationGlyphs: verificationGlyphs(for: line, observations: verification.results ?? []))
                    }
                    let normalized = OCRNumericChoiceNormalizer.normalize(checked)
                    saveNumericDiagnostics(checked, result: normalized)
                    return normalized
                } catch {
                    // Optional verification must never turn usable OCR into a failure.
                    saveNumericDiagnostics(lines, result: original, error: error.localizedDescription)
                    return original
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func verificationGlyphs(for line: OCRLine, observations: [VNRecognizedTextObservation]) -> [OCRGlyph] {
        let vicinity = line.bounds.insetBy(dx: -line.bounds.height * 0.5, dy: 0)
        return observations.flatMap { observation -> [OCRGlyph] in
            let box = observation.boundingBox
            let overlap = box.intersection(vicinity)
            guard !overlap.isNull, overlap.height >= min(box.height, line.bounds.height) * 0.5,
                  let candidate = observation.topCandidates(1).first else { return [] }
            let text = candidate.string
            return text.indices.compactMap { index -> OCRGlyph? in
                guard !text[index].isWhitespace,
                      let glyph = try? candidate.boundingBox(for: index..<text.index(after: index)) else { return nil }
                return OCRGlyph(character: text[index], bounds: glyph.boundingBox)
            }
        }.sorted { $0.bounds.minX < $1.bounds.minX }
    }

    private static func saveNumericDiagnostics(_ lines: [OCRLine], result: String, error: String? = nil) {
        // Synthetic CI evidence only. Production captures and recognized text are
        // never persisted by this diagnostic path.
        guard let directory = RuntimeConfiguration.liveDirectory else { return }
        let original = lines.map(\.text).joined(separator: "\n")
        let payload: [String: Any] = ["original": original,
            "normalized": result, "verificationError": error ?? "",
            "decision": result == original ? "unchanged-insufficient-layout-evidence" : "restored-numeric-separators",
            "lines": lines.map { line -> [String: Any] in
                ["text": line.text, "bounds": [line.bounds.minX, line.bounds.minY, line.bounds.width, line.bounds.height],
                 "glyphs": line.verificationGlyphs.map { glyph -> [String: Any] in
                    ["character": String(glyph.character), "x": glyph.bounds.minX,
                     "y": glyph.bounds.minY, "width": glyph.bounds.width, "height": glyph.bounds.height]
                }]
            }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: directory.appendingPathComponent("ocr-numeric-\(UUID().uuidString).json"), options: .atomic)
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class OllamaClient {
    private let delegate = NoRedirectDelegate()
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }
    private lazy var session: URLSession = {
        let config = configuration
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private var task: URLSessionDataTask?
    struct Response: Decodable { let response: String?; let error: String? }
    struct ModelList: Decodable { let models: [ModelInfo] }
    struct ModelInfo: Decodable {
        let name: String
        let remote_model: String?
        let remote_host: String?
    }
    /// Constrain response shape and identifiers, never the correct answer.
    /// null remains available so the model can explicitly decline an answer.
    static func answerSchema(questionPayload: String) -> [String: Any] {
        let payload = questionPayload.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var choice: [String: Any] = ["type": ["string", "null"],
            "description": "Copy the label of the correct choice, not its text. If unknown, use null and explain uncertainty."]
        if let labels = payload?["allowed_choice_labels"] as? [String] {
            choice["enum"] = labels.map { $0 as Any } + [NSNull()]
        }
        var citations: [String: Any] = ["type": "array", "items": ["type": "string"],
            "description": "Only IDs from supplied sources. No URLs or invented citations. Empty array when no sources."]
        if let sources = payload?["sources"] as? [[String: Any]] {
            let ids = sources.compactMap { $0["id"] as? String }
            if ids.isEmpty { citations["maxItems"] = 0 }
            else { citations["items"] = ["type": "string", "enum": ids] }
        }
        return ["type": "object", "additionalProperties": false,
                "required": ["selected_choice", "answer", "explanation", "citations", "uncertainty"],
                "properties": ["selected_choice": choice,
                    "answer": ["type": "string"], "explanation": ["type": "string"],
                    "citations": citations, "uncertainty": ["type": ["string", "null"], "description": "JSON null when confident. A nonempty string only for a genuine unresolved doubt that prevents confirming the answer. Reasoning belongs in explanation, not here."]]]
    }
    private var generation = 0
    func answer(endpoint: String, model: String, question: String, system: String, completion: @escaping (Result<String, Error>) -> Void) throws {
        let url = try LocalEndpoint.generateURL(endpoint)
        let model = try LocalEndpoint.modelName(model)
        let question = try LocalEndpoint.question(question)
        guard question.utf8.count + system.utf8.count <= 14_000 else {
            throw AppError(message: "로컬 모델 문맥 한도 보호를 위해 질문을 줄여 주세요 (UTF-8 합계 14KB 이하).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "format": Self.answerSchema(questionPayload: question),
            "system": system,
            "prompt": question,
            "options": ["temperature": 0.2, "num_predict": 2048, "num_ctx": RuntimeConfiguration.isLiveTest ? 4096 : 16384]
        ])
        generation += 1
        let token = generation
        var tagsURL = url.deletingLastPathComponent().deletingLastPathComponent()
        tagsURL.appendPathComponent("api/tags")
        task = session.dataTask(with: tagsURL) { [weak self] data, response, error in
            guard let self else { return }
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                    throw AppError(message: "로컬 모델 목록을 확인할 수 없습니다. Ollama를 실행하세요.")
                }
                let list = try JSONDecoder().decode(ModelList.self, from: data)
                guard let installed = list.models.first(where: { $0.name == model || $0.name == model + ":latest" }),
                      installed.remote_model == nil, installed.remote_host == nil else {
                    throw AppError(message: "설치된 로컬 모델만 사용할 수 있습니다. 모델 이름을 확인하고 클라우드 모델은 사용하지 마세요.")
                }
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.generate(request, completion: completion)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    completion(.failure(error))
                }
            }
        }
        task?.resume()
    }
    private func generate(_ request: URLRequest, completion: @escaping (Result<String, Error>) -> Void) {
        let token = generation
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result = Result<String, Error> {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse else { throw AppError(message: "서버 응답이 없습니다.") }
                let decoded = data.flatMap { try? JSONDecoder().decode(Response.self, from: $0) }
                guard (200..<300).contains(http.statusCode) else {
                    throw AppError(message: "Ollama 오류 \(http.statusCode): \(decoded?.error ?? "모델 설치와 로컬 서버 상태를 확인하세요.")")
                }
                if let error = decoded?.error { throw AppError(message: error) }
                guard let answer = decoded?.response, !answer.isEmpty else { throw AppError(message: "빈 응답을 받았습니다.") }
                return answer
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                completion(result)
            }
        }
        task?.resume()
    }
    func cancel() { generation += 1; task?.cancel(); task = nil }
    deinit { task?.cancel(); session.invalidateAndCancel() }
}
