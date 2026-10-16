import XCTest
import AppKit
import CoreText
import PDFKit
import Vision
import QuestionCore
@testable import DotQuestion

/// Only generated documents and bitmap images are used. These tests do not open
/// the app, capture the desktop, access HID/clipboard/hotkeys, or contact a model.
final class MacServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotQuestion-SyntheticTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private var storeDirectory: URL { temporaryDirectory.appendingPathComponent("store", isDirectory: true) }

    private func fixture(_ name: String, text: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTextAndMarkdownImportReloadRetrieveAndDeletePreserveOriginals() throws {
        let textURL = try fixture("astronomy.txt", text: "Mars is the red planet. Iron oxide colors its surface.")
        let markdownURL = try fixture("biology.md", text: "# Photosynthesis\nPlants convert sunlight into chemical energy.")
        let originals = try [textURL, markdownURL].map { try Data(contentsOf: $0) }
        let store = DocumentStore(directory: storeDirectory)
        XCTAssertNil(store.loadError)
        let astronomy = try store.importDocument(textURL)
        let biology = try store.importDocument(markdownURL)
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertTrue(astronomy.chunks.allSatisfy { $0.page == nil && $0.filename == "astronomy.txt" })

        let reloaded = DocumentStore(directory: storeDirectory)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.documents.map(\.id), [astronomy.id, biology.id])
        let matches = reloaded.retrieve(query: "What colors the red planet Mars?")
        XCTAssertEqual(matches.first?.documentID, astronomy.id)
        XCTAssertEqual(matches.first?.citationLabel, "astronomy.txt")
        XCTAssertTrue(reloaded.retrieve(query: "unrelatedquasarword").isEmpty)

        try reloaded.remove(astronomy.id)
        let afterDeletion = DocumentStore(directory: storeDirectory)
        XCTAssertEqual(afterDeletion.documents.map(\.id), [biology.id])
        XCTAssertTrue(afterDeletion.retrieve(query: "Mars red planet").isEmpty)
        XCTAssertEqual(try [textURL, markdownURL].map { try Data(contentsOf: $0) }, originals)
        let savedIndex = try String(contentsOf: storeDirectory.appendingPathComponent("documents.json"), encoding: .utf8)
        XCTAssertFalse(savedIndex.contains(temporaryDirectory.path), "Original paths must not be persisted.")
    }

    func testEmbeddedPDFTextPreservesPageCitationsThroughStructuredAnswer() throws {
        let url = temporaryDirectory.appendingPathComponent("planets.pdf")
        try makePDF(pages: ["Mercury is closest to the Sun.", "Mars is the red planet."]).write(to: url)
        let original = try Data(contentsOf: url)
        let store = DocumentStore(directory: storeDirectory)
        let document = try store.importDocument(url)
        XCTAssertEqual(Set(document.chunks.compactMap(\.page)), Set([1, 2]))
        let sources = store.retrieve(query: "Which planet is red? Mars", limit: 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.page, 2)
        XCTAssertEqual(source.citationLabel, "planets.pdf · 2쪽")
        let prompt = try StudyPromptBuilder.build(question: "Which planet is red?\nA. Mars\nB. Mercury", sources: sources, requiresSources: true)
        let response: [String: Any] = ["selected_choice": "A", "answer": "Mars", "explanation": "The supplied page states that Mars is red.", "citations": [source.id], "uncertainty": NSNull()]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: response), encoding: .utf8))
        let answer = try StructuredAnswerParser.parse(json, question: prompt.question, sources: sources)
        XCTAssertTrue(answer.formattedText.contains("planets.pdf · 2쪽"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUTF16WithBOMImportsWithoutCorruptingKorean() throws {
        let url = temporaryDirectory.appendingPathComponent("korean.txt")
        let text = "광합성은 빛 에너지를 화학 에너지로 바꾸는 과정입니다."
        try XCTUnwrap(text.data(using: .utf16)).write(to: url)
        let store = DocumentStore(directory: storeDirectory)
        let document = try store.importDocument(url)
        XCTAssertEqual(document.chunks.map(\.text).joined(), text)
        XCTAssertEqual(store.retrieve(query: "광합성 에너지").first?.documentID, document.id)
    }

    func testCorruptIndexBlocksMutationAndPreservesBytes() throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let indexURL = storeDirectory.appendingPathComponent("documents.json")
        let corrupt = Data("{ synthetic broken archive".utf8)
        try corrupt.write(to: indexURL)
        let store = DocumentStore(directory: storeDirectory)
        XCTAssertNotNil(store.loadError)
        let url = try fixture("valid.txt", text: "A valid synthetic document must not overwrite the corrupt archive.")
        XCTAssertThrowsError(try store.importDocument(url))
        XCTAssertThrowsError(try store.remove(UUID()))
        XCTAssertEqual(try Data(contentsOf: indexURL), corrupt)
        XCTAssertTrue(store.documents.isEmpty)
    }

    func testEmptyUnsupportedAndTextlessPDFDocumentsAreRejected() throws {
        let store = DocumentStore(directory: storeDirectory)
        let empty = try fixture("empty.txt", text: " \n\t")
        let unsupported = try fixture("unsupported.bin", text: "Synthetic content")
        let noTextPDF = temporaryDirectory.appendingPathComponent("blank.pdf")
        try makePDF(pages: [""]).write(to: noTextPDF)
        for url in [empty, unsupported, noTextPDF] {
            XCTAssertThrowsError(try store.importDocument(url), url.lastPathComponent)
        }
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("documents.json").path))
    }

    func testSyntheticEnglishImageOCR() throws {
        let url = try makeOCRImage(lines: ["Which planet is called the Red Planet?", "A. Mars", "B. Venus"])
        let completed = expectation(description: "On-device OCR of generated English question")
        OCRService.recognize(url) { result in
            switch result {
            case .success(let text):
                XCTAssertTrue(text.lowercased().contains("mars"), text)
                XCTAssertTrue(text.lowercased().contains("venus"), text)
                XCTAssertTrue(text.lowercased().contains("planet"), text)
            case .failure(let error): XCTFail("Synthetic OCR failed: \(error.localizedDescription)")
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 30)
    }

    func testSyntheticKoreanImageOCRWhenLanguageSupported() throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard try request.supportedRecognitionLanguages().contains("ko-KR") else {
            throw XCTSkip("Installed Vision runtime does not offer Korean text recognition.")
        }
        let url = try makeOCRImage(lines: ["광합성은 빛 에너지를 사용합니다.", "식물은 산소를 만듭니다."])
        let completed = expectation(description: "On-device OCR of generated Korean text")
        OCRService.recognize(url) { result in
            switch result {
            case .success(let text):
                XCTAssertTrue(text.contains("광합성"), text)
                XCTAssertTrue(text.contains("산소"), text)
            case .failure(let error): XCTFail("Synthetic OCR failed: \(error.localizedDescription)")
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 30)
    }

    func testAnswerIconsRenderDistinctLevelsAndBatteryBounds() throws {
        let wifi = try (1...5).map { try renderedPNG(AnswerStatusIcon.wifi(bars: $0)) }
        XCTAssertEqual(Set(wifi).count, 5)
        let battery = try (1...10).map { try renderedPNG(AnswerStatusIcon.battery(percent: $0 * 10)) }
        XCTAssertEqual(Set(battery).count, 10)
        XCTAssertEqual(try renderedPNG(AnswerStatusIcon.battery(percent: -20)), try renderedPNG(AnswerStatusIcon.battery(percent: 0)))
        XCTAssertEqual(try renderedPNG(AnswerStatusIcon.battery(percent: 120)), try renderedPNG(AnswerStatusIcon.battery(percent: 100)))
        XCTAssertTrue(AnswerStatusIcon.wifi(bars: 2).isTemplate)
        XCTAssertTrue(AnswerStatusIcon.battery(percent: 20).isTemplate)
    }

    func testCharacterFramesRenderDifferentCatAndPikachuMotion() throws {
        var frames: [Data] = []
        for style in [CharacterStatusIcon.Style.cat, .pikachu] {
            let idle = CharacterStatusIcon.image(style: style, active: false)
            let active = CharacterStatusIcon.image(style: style, active: true)
            XCTAssertEqual(idle.size, NSSize(width: 34, height: 22))
            XCTAssertFalse(idle.isTemplate)
            let idleData = try renderedPNG(idle)
            let activeData = try renderedPNG(active)
            XCTAssertNotEqual(idleData, activeData)
            frames.append(contentsOf: [idleData, activeData])
        }
        XCTAssertEqual(Set(frames).count, 4)
    }

    private func makePDF(pages: [String]) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.textPosition = CGPoint(x: 36, y: 720)
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 22)])
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }

    private func makeOCRImage(lines: [String]) throws -> URL {
        let width = 1800, height = 520
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for (index, text) in lines.enumerated() {
            context.textPosition = CGPoint(x: 50, y: height - 100 - index * 110)
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black])
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = temporaryDirectory.appendingPathComponent("synthetic-question-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    private func renderedPNG(_ image: NSImage) throws -> Data {
        let width = Int(image.size.width) * 2, height = Int(image.size.height) * 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        bitmap.size = image.size
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(origin: .zero, size: image.size))
        image.draw(in: CGRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        graphics.flushGraphics()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
