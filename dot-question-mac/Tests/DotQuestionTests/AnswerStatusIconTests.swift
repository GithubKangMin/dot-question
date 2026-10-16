import AppKit
import XCTest
@testable import DotQuestion

/// Raster tests of application-owned images only; no desktop/menu-bar capture.
final class AnswerStatusIconTests: XCTestCase {
    func testAllSixWifiLevelsHaveTheSameSizeAndFiveVisibleBarPositions() throws {
        var images: [Data] = []
        var baseline: NSBitmapImageRep?
        for level in 0...5 {
            let image = AnswerStatusIcon.wifi(bars: level)
            XCTAssertEqual(image.size, NSSize(width: 26, height: 18))
            XCTAssertTrue(image.isTemplate)
            let bitmap = try raster(image)
            images.append(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
            if level == 0 { baseline = bitmap }
            let idle = try XCTUnwrap(baseline)
            // Sample the middle of each bar at 2x, summing vertically to avoid
            // bitmap coordinate orientation assumptions. Every idle bar is visible.
            for bar in 0..<5 {
                let x = bar * 10 + 3
                let idleAlpha = alphaColumn(idle, x: x)
                let activeAlpha = alphaColumn(bitmap, x: x)
                XCTAssertGreaterThan(idleAlpha, 0, "Idle must retain bar \(bar + 1).")
                if bar < level { XCTAssertGreaterThan(activeAlpha, idleAlpha * 3) }
                else { XCTAssertEqual(activeAlpha, idleAlpha, accuracy: 0.001) }
            }
            // All fully covered pixels have identical positions at every level.
            // Active/idle antialiasing may differ only at the rounded edges.
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let idleAlpha = idle.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if idleAlpha > 0.1 { XCTAssertGreaterThan(alpha, 0.1) }
                    if alpha > 0.5 { XCTAssertGreaterThan(idleAlpha, 0.1) }
                }
            }
        }
        XCTAssertEqual(Set(images).count, 6, "Zero and all five filled levels must be distinct.")
        XCTAssertEqual(AnswerStatusIcon.wifiStatusItemLength, 34)
    }

    func testWifiRendererClampsCountsWithoutChangingGeometry() throws {
        func png(_ bars: Int) throws -> Data {
            try XCTUnwrap(raster(AnswerStatusIcon.wifi(bars: bars)).representation(using: .png, properties: [:]))
        }
        XCTAssertEqual(try png(-3), try png(0))
        XCTAssertEqual(try png(8), try png(5))
    }

    private func alphaColumn(_ bitmap: NSBitmapImageRep, x: Int) -> CGFloat {
        (0..<bitmap.pixelsHigh).reduce(0) { $0 + (bitmap.colorAt(x: x, y: $1)?.alphaComponent ?? 0) }
    }

    private func raster(_ image: NSImage) throws -> NSBitmapImageRep {
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
        return bitmap
    }
}
