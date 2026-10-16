import Foundation
import AppKit
import Vision
import ImageIO
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
                // Fast Vision may omit short numeric rows entirely. Instead,
                // measure actual separated ink components inside accurate OCR's
                // row bounds. The original recognized characters never change.
                let raster = numericRaster(url)
                let evidence = lines.map { line in
                    raster.map { OCRRasterVerifier.verify(text: line.text, bounds: line.bounds, image: $0) }
                }
                let checked = zip(lines, evidence).map { line, proof in
                    OCRLine(text: line.text, bounds: line.bounds, verificationGlyphs: proof?.glyphs ?? [])
                }
                let normalized = OCRNumericChoiceNormalizer.normalize(checked)
                saveNumericDiagnostics(checked, evidence: evidence, result: normalized, source: url, raster: raster)
                return normalized
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func numericRaster(_ url: URL) -> OCRRasterVerifier.Image? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // Screenshot PNGs are upright. Do not guess a coordinate transform for
        // rotated or mirrored image metadata.
        if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber,
           orientation.intValue != 1 { return nil }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              (1...8192).contains(image.width), (1...8192).contains(image.height),
              image.width * image.height <= 33_554_432 else { return nil }
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 255, count: width * height)
        let rendered = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return OCRRasterVerifier.Image(width: width, height: height, gray: gray)
    }

    private static func saveNumericDiagnostics(_ lines: [OCRLine], evidence: [OCRRasterVerifier.Evidence?],
                                               result: String, source: URL, raster: OCRRasterVerifier.Image?) {
        // This gate also checks GITHUB_ACTIONS. Only synthetic CI captures are
        // copied; production images/text are never persisted by diagnostics.
        guard let directory = RuntimeConfiguration.liveDirectory else { return }
        let id = UUID().uuidString
        let filename = "ocr-numeric-source-\(id).png"
        var sourceFile: String?
        var copyError: String?
        do {
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(filename))
            sourceFile = filename
        } catch { copyError = error.localizedDescription }
        let original = lines.map(\.text).joined(separator: "\n")
        let payload: [String: Any] = ["original": original, "normalized": result,
            "verificationMethod": "measured-raster-components",
            "decision": result == original ? "unchanged-insufficient-layout-evidence" : "restored-numeric-separators",
            "sourcePNG": sourceFile.map { $0 as Any } ?? NSNull(),
            "sourceCopyError": copyError ?? "",
            "pixelWidth": raster.map { $0.width as Any } ?? NSNull(),
            "pixelHeight": raster.map { $0.height as Any } ?? NSNull(),
            "lines": zip(lines, evidence).map { line, proof -> [String: Any] in
                ["text": line.text, "bounds": [line.bounds.minX, line.bounds.minY, line.bounds.width, line.bounds.height],
                 "reason": proof?.reason ?? "raster-unavailable",
                 "glyphs": line.verificationGlyphs.map { glyph -> [String: Any] in
                    ["character": String(glyph.character), "x": glyph.bounds.minX,
                     "y": glyph.bounds.minY, "width": glyph.bounds.width, "height": glyph.bounds.height]
                 }]
            }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: directory.appendingPathComponent("ocr-numeric-\(id).json"), options: .atomic)
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
        config.timeoutIntervalForRequest = RuntimeConfiguration.isLiveTest ? 240 : 120
        config.timeoutIntervalForResource = RuntimeConfiguration.isLiveTest ? 300 : 180
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
                    "answer": ["type": "string", "minLength": 1], "explanation": ["type": "string", "minLength": 1],
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
            "options": ["temperature": 0.2, "num_predict": RuntimeConfiguration.isLiveTest ? 512 : 2048, "num_ctx": RuntimeConfiguration.isLiveTest ? 4096 : 16384]
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
