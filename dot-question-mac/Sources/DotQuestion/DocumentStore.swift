import Foundation
import PDFKit
import QuestionCore

/// Stores only extracted document text locally, never credentials or model conversations.
/// All snapshots and mutations are synchronized; extraction runs before taking the lock.
final class DocumentStore {
    private struct Archive: Codable {
        let version: Int
        let documents: [StoredDocument]
    }
    private let lock = NSLock()
    private let directory: URL
    private let indexURL: URL
    private var savedDocuments: [StoredDocument] = []
    private var savedLoadError: String?
    private let maximumFileBytes = 20 * 1024 * 1024
    private let maximumCharacters = 2_000_000
    private let maximumLibraryCharacters = 10_000_000

    var documents: [StoredDocument] {
        lock.lock(); defer { lock.unlock() }
        return savedDocuments
    }
    var loadError: String? {
        lock.lock(); defer { lock.unlock() }
        return savedLoadError
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotQuestion", isDirectory: true)
        self.indexURL = self.directory.appendingPathComponent("documents.json")
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let size = try indexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 160 * 1024 * 1024 else { throw AppError(message: "저장된 자료 파일이 허용 크기를 초과했습니다.") }
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: indexURL))
                guard archive.version == 1, archive.documents.count <= 100 else { throw AppError(message: "저장된 자료 형식을 읽을 수 없습니다.") }
                try Self.validate(archive.documents)
                savedDocuments = archive.documents
            }
        } catch {
            // A corrupt/unreadable store is preserved and cannot be silently overwritten.
            savedLoadError = "저장된 자료를 열 수 없습니다. 원본 자료는 변경하지 않았습니다. 앱을 종료한 뒤 Application Support/DotQuestion/documents.json을 확인하세요. (\(error.localizedDescription))"
        }
    }

    @discardableResult
    func importDocument(_ url: URL) throws -> StoredDocument {
        guard url.isFileURL else { throw AppError(message: "Mac에 있는 PDF, TXT, MD 파일을 선택하세요.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ["pdf", "txt", "md", "markdown"].contains(ext) else { throw AppError(message: "PDF, TXT, MD 파일만 지원합니다.") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw AppError(message: "일반 문서 파일을 선택하세요.") }
        guard let bytes = values.fileSize, bytes <= maximumFileBytes else { throw AppError(message: "문서는 파일당 20 MiB 이하여야 합니다. 파일을 나눠서 추가하세요.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileBytes else { throw AppError(message: "문서는 파일당 20 MiB 이하여야 합니다.") }
        let pages: [DocumentPage]
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw AppError(message: "PDF를 읽을 수 없거나 암호로 잠겨 있습니다. 잠금이 없는 PDF를 선택하세요.") }
            guard pdf.pageCount <= 500 else { throw AppError(message: "PDF는 파일당 500쪽 이하여야 합니다. 필요한 부분을 나눠서 추가하세요.") }
            var extracted: [DocumentPage] = []
            var count = 0
            for index in 0..<pdf.pageCount {
                let text = pdf.page(at: index)?.string ?? ""
                count += text.count
                guard count <= maximumCharacters else { throw AppError(message: "추출된 텍스트가 200만 자를 초과했습니다. 문서를 나눠서 추가하세요.") }
                extracted.append(DocumentPage(page: index + 1, text: text))
            }
            pages = extracted
        } else {
            let text: String?
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
            else { text = String(data: data, encoding: .utf8) }
            guard let text, !text.contains("\0") else { throw AppError(message: "텍스트 인코딩을 읽을 수 없습니다. UTF-8 또는 BOM이 있는 UTF-16 TXT/MD 파일로 저장하세요.") }
            guard text.count <= maximumCharacters else { throw AppError(message: "텍스트가 200만 자를 초과했습니다. 문서를 나눠서 추가하세요.") }
            pages = [DocumentPage(text: text)]
        }
        let id = UUID()
        let name = url.lastPathComponent
        let chunks = DocumentChunker.chunks(documentID: id, name: name, pages: pages)
        guard !chunks.isEmpty else { throw AppError(message: "읽을 수 있는 텍스트가 없습니다. 스캔 PDF나 이미지 문서는 먼저 OCR로 텍스트를 추출해야 합니다.") }
        let document = StoredDocument(id: id, name: name, chunks: chunks)
        lock.lock(); defer { lock.unlock() }
        try ensureWritable()
        guard savedDocuments.count < 100 else { throw AppError(message: "자료는 최대 100개입니다. 필요 없는 자료를 삭제한 뒤 추가하세요.") }
        let total = savedDocuments.reduce(0) { $0 + $1.chunks.reduce(0) { $0 + $1.text.count } } + chunks.reduce(0) { $0 + $1.text.count }
        guard total <= maximumLibraryCharacters else { throw AppError(message: "저장 자료가 전체 1,000만 자 한도를 초과합니다. 필요 없는 자료를 삭제하세요.") }
        let updated = savedDocuments + [document]
        try save(updated)
        savedDocuments = updated
        return document
    }

    func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureWritable()
        guard savedDocuments.contains(where: { $0.id == id }) else { return }
        let updated = savedDocuments.filter { $0.id != id }
        try save(updated)
        savedDocuments = updated
    }

    func retrieve(query: String, limit: Int = 6, maxCharacters: Int = 7200) -> [DocumentChunk] {
        DocumentRetriever.retrieve(query: query, documents: documents, limit: limit, maxCharacters: maxCharacters)
    }

    private func ensureWritable() throws {
        if let error = savedLoadError { throw AppError(message: error) }
    }

    private func save(_ documents: [StoredDocument]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(version: 1, documents: documents))
        // Atomic replacement means a failed write cannot publish an in-memory deletion/import.
        try data.write(to: indexURL, options: .atomic)
        // The parent directory is private. Avoid reporting a committed save as failed if chmod fails.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private static func validate(_ documents: [StoredDocument]) throws {
        var ids: Set<UUID> = []
        var sourceIDs: Set<String> = []
        var characters = 0
        for document in documents {
            guard ids.insert(document.id).inserted, !document.name.isEmpty, !document.chunks.isEmpty else {
                throw AppError(message: "자료 색인이 손상되었습니다.")
            }
            for chunk in document.chunks {
                characters += chunk.text.count
                guard chunk.documentID == document.id, chunk.filename == document.name,
                      !chunk.id.isEmpty, sourceIDs.insert(chunk.id).inserted,
                      !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      chunk.text.count <= 1200, chunk.page == nil || (1...500).contains(chunk.page!), characters <= 10_000_000 else {
                    throw AppError(message: "자료 색인이 손상되었거나 허용 크기를 초과했습니다.")
                }
            }
        }
    }
}
