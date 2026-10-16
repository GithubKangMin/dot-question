import Foundation
import CoreGraphics
import XCTest
@testable import QuestionCore

final class OCRRasterVerifierTests: XCTestCase {
    private let width = 160, height = 340, maskWidth = 56, maskHeight = 37
    // Dark-ink masks measured from the five synthetic hosted-Mac rows in the
    // c1aa407 screenshot. Bit order is row-major, least-significant bit first.
    private let masks: [String] = [
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHAAAAA8AAD+AwAAPwAA/wcAgD8AgAcPAMA7AIADDgDgOADAAQ4AYDgAAAAOAAA4AAAADgAAOAAAAAcAADgAAMADAAA4AAD8AQAAOAAA/AMAADgAAIAHAAA4AAAADgAAOAAAABwAADgAAAAcAAA4AMABHAAAOADAAR4AADgAwAMOAAA4HICPDwAAOBwA/wMAADgcAPwBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADgAAAAAAAD/AQAAeACA/wMAAHwAwIMHAAB+AMABBwAAbgDAAQcAAGcAwAAGAIBnAAAABwCAYwAAAAcAwGEAAIADAMBhAADAAwDgYAAAwAEAcGAAAOAAAHBgAABwAAA4YAAAOAAAHGAAABwAAPz/AwAOAAD8/wMABwAAAPAAgAMAAABgAMD/hwMAYADA/48DAGAAwP+PAQBgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAD+AQDg/wGA/wMA8P8BgIMHAHAAAMABBwBwAADAAQ4AcAAAAAAGAHAAAAAABwBwAAAAgAcAMD8AAOADAPD/AAD8AADw+QEA/AMAcOABAIAHADDAAwAADwAAgAMAAA4AAIADAAAOAACAA+AADgA4gAPAAA4AcIADwAEPAHDAAcDHhwPw8QAA/4MDwH8AAP6AA4A/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcAADAAwCA/wAA4AMAwP8BAPADAODBAwBwAwDggAMAOAMAcAADADwDAHAAAAAcAwBwAAAADgMAOH4AAA4DALj/AAAHAwD49wGAAwMA+MEDgAMDAHiAB8ABAwB4AAfgAAMAeAAH4P8fAHAAB+D/HwBwAAcAgAcAcIAHAAADAODAAwAAAwfA9wEAAAMHgP8AAAADBwB/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAID/BwD4/wGA/wcA+P8BgAMAAADgAYABAAAA4ACAAQAAAOAAgAEAAABwAIABAAAAcADA+QEAADgAwP8DAAA4AMDPBwAAHADAAw8AABwAwAEOAAAOAAAADgAADgAAABwAAAcAAAAcAAAHAMABDgCAAwDAAQ4AwAMAwAMPAMABAIDPhwPgAQAA/4MD4AAAAP6BA/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
    ]
    private let valueStarts = [30, 34, 35, 35, 35]
    private let observedGaps = [9, 8, 9, 8, 9]

    private func fixture(targetGap: Int? = nil) -> (image: OCRRasterVerifier.Image, lines: [OCRLine]) {
        var pixels = [UInt8](repeating: 255, count: width * height)
        var lines = [OCRLine(text: "Which number equals 2 + 2?", bounds: CGRect(x: 0.1, y: 0.97, width: 0.5, height: 0.02))]
        for row in masks.indices {
            let bits = Array(Data(base64Encoded: masks[row])!)
            let shift = targetGap.map { observedGaps[row] - $0 } ?? 0
            let top = 20 + row * 55
            for index in 0..<(maskWidth * maskHeight) where bits[index / 8] & (UInt8(1) << (index % 8)) != 0 {
                let x = index % maskWidth
                let shifted = x >= valueStarts[row] ? x - shift : x
                pixels[(top + index / maskWidth) * width + 20 + shifted] = 0
            }
            lines.append(OCRLine(text: "\(row + 1).\(row + 3)", bounds: CGRect(
                x: 20 / CGFloat(width), y: CGFloat(height - top - maskHeight) / CGFloat(height),
                width: CGFloat(maskWidth) / CGFloat(width), height: CGFloat(maskHeight) / CGFloat(height))))
        }
        return (OCRRasterVerifier.Image(width: width, height: height, gray: pixels)!, lines)
    }
    private func checked(_ image: OCRRasterVerifier.Image, lines: [OCRLine]) -> [OCRLine] {
        lines.map { line in
            OCRLine(text: line.text, bounds: line.bounds,
                    verificationGlyphs: OCRRasterVerifier.verify(text: line.text, bounds: line.bounds, image: image).glyphs)
        }
    }
    func testActualScreenshotMasksRecoverFiveOptionsWithMeasuredSpacing() throws {
        let fixture = fixture()
        let lines = checked(fixture.image, lines: fixture.lines)
        let before = [4, 3, 3, 3, 2]
        for row in 0..<5 {
            let proof = OCRRasterVerifier.verify(text: lines[row + 1].text, bounds: lines[row + 1].bounds, image: fixture.image)
            XCTAssertEqual(proof.reason, "measured-raster-components")
            XCTAssertEqual(proof.glyphs.count, 3)
            guard proof.glyphs.count == 3 else { continue }
            XCTAssertEqual((proof.glyphs[1].bounds.minX - proof.glyphs[0].bounds.maxX) * CGFloat(width), CGFloat(before[row]), accuracy: 0.00001)
            XCTAssertEqual((proof.glyphs[2].bounds.minX - proof.glyphs[1].bounds.maxX) * CGFloat(width), CGFloat(observedGaps[row]), accuracy: 0.00001)
        }
        let text = OCRNumericChoiceNormalizer.normalize(lines)
        let prompt = try StudyPromptBuilder.build(question: text, sources: [])
        XCTAssertEqual(prompt.question.choices.map(\.label), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(prompt.question.choices.map(\.text), ["3", "4", "5", "6", "7"])
        XCTAssertEqual(AnswerIndicator(choice: "2", options: prompt.question.choices.map(\.label))?.ordinal, 2)
    }
    func testTightDecimalMasksKeepTheirOriginalTextAndNoChoices() {
        let fixture = fixture(targetGap: 3)
        let lines = checked(fixture.image, lines: fixture.lines)
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.verificationGlyphs.count == 3 })
        let original = fixture.lines.map(\.text).joined(separator: "\n")
        XCTAssertEqual(OCRNumericChoiceNormalizer.normalize(lines), original)
        XCTAssertTrue(MCQParser.parse(original).choices.isEmpty)
    }
    func testTouchingGlyphsAreNeverSplitToMatchRecognizedText() {
        let fixture = fixture(targetGap: 0)
        for line in fixture.lines.dropFirst() {
            let proof = OCRRasterVerifier.verify(text: line.text, bounds: line.bounds, image: fixture.image)
            XCTAssertTrue(proof.glyphs.isEmpty)
            XCTAssertTrue(proof.reason.hasPrefix("component-count-"))
        }
    }
    func testDarkBackgroundAndClippedBoundsAreRejected() {
        let fixture = fixture()
        let inverted = OCRRasterVerifier.Image(width: width, height: height, gray: fixture.image.gray.map { 255 - $0 })!
        let line = fixture.lines[1]
        XCTAssertEqual(OCRRasterVerifier.verify(text: line.text, bounds: line.bounds, image: inverted).reason, "non-light-or-clipped-border")
        let clipped = CGRect(x: 0, y: line.bounds.minY, width: line.bounds.width, height: line.bounds.height)
        XCTAssertEqual(OCRRasterVerifier.verify(text: line.text, bounds: clipped, image: fixture.image).reason, "clipped-row")
    }
    func testNoiseComponentsAreNotDeletedAndTallPunctuationIsRejected() {
        let fixture = fixture()
        let line = fixture.lines[1]
        var noise = fixture.image.gray
        noise[22 * width + 21] = 0
        let noisy = OCRRasterVerifier.Image(width: width, height: height, gray: noise)!
        XCTAssertTrue(OCRRasterVerifier.verify(text: line.text, bounds: line.bounds, image: noisy).reason.hasPrefix("component-count-"))
        var tall = fixture.image.gray
        for y in 35...45 { for x in 38...40 { tall[y * width + x] = 0 } }
        let malformed = OCRRasterVerifier.Image(width: width, height: height, gray: tall)!
        XCTAssertEqual(OCRRasterVerifier.verify(text: line.text, bounds: line.bounds, image: malformed).reason, "not-period-shaped")
    }
    func testSignsUnitsAndAmbiguousFormatsRemainUnsupported() {
        let fixture = fixture()
        let bounds = fixture.lines[1].bounds
        for text in ["1.-3", "1.3%", "1.3 cm", "1.3/4", "1.", "1.3.4.5", "11.3", "A.3"] {
            XCTAssertEqual(OCRRasterVerifier.verify(text: text, bounds: bounds, image: fixture.image).reason, "unsupported-numeric-format", text)
        }
    }
    func testMalformedRasterSizesAndNonfiniteBoundsFailClosed() {
        XCTAssertNil(OCRRasterVerifier.Image(width: 0, height: 1, gray: []))
        XCTAssertNil(OCRRasterVerifier.Image(width: 10, height: 10, gray: [255]))
        XCTAssertNil(OCRRasterVerifier.Image(width: Int.max, height: Int.max, gray: []))
        let fixture = fixture()
        let proof = OCRRasterVerifier.verify(text: "1.3", bounds: CGRect(x: CGFloat.nan, y: 0.2, width: 0.2, height: 0.1), image: fixture.image)
        XCTAssertTrue(proof.glyphs.isEmpty)
    }
}
