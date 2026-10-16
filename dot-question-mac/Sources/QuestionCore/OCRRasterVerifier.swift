import Foundation
import CoreGraphics

/// Measures existing ink; it does not recognize or change any character. This
/// intentionally supports only separated ASCII digits/periods on a light field.
public enum OCRRasterVerifier {
    public struct Image {
        public let width: Int
        public let height: Int
        /// One grayscale byte per pixel, row-major from the top-left corner.
        public let gray: [UInt8]
        public init?(width: Int, height: Int, gray: [UInt8]) {
            guard (1...8192).contains(width), (1...8192).contains(height),
                  width * height <= 33_554_432, gray.count == width * height else { return nil }
            self.width = width; self.height = height; self.gray = gray
        }
    }
    public struct Evidence {
        public let glyphs: [OCRGlyph]
        public let reason: String
    }
    private struct Component {
        var left: Int; var top: Int; var right: Int; var bottom: Int
        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
    }
    public static func verify(text: String, bounds: CGRect, image: Image) -> Evidence {
        func reject(_ reason: String) -> Evidence { Evidence(glyphs: [], reason: reason) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Do not attempt signs, units, fractions, touching digits or percent
        // symbols whose connected-component count is not one per character.
        guard text.range(of: #"^(?:10|[1-9])\.[\t ]*[0-9]+(?:\.[0-9]+)?$"#,
                         options: .regularExpression) != nil else { return reject("unsupported-numeric-format") }
        let characters = Array(text.filter { !$0.isWhitespace })
        guard (3...24).contains(characters.count),
              [bounds.minX, bounds.minY, bounds.width, bounds.height, bounds.maxX, bounds.maxY].allSatisfy({ $0.isFinite }),
              bounds.width > 0, bounds.height > 0, bounds.minX >= 0, bounds.minY >= 0,
              bounds.maxX <= 1, bounds.maxY <= 1 else { return reject("invalid-row-bounds") }
        let width = image.width, height = image.height
        let padding = min(8, max(2, Int(ceil(bounds.height * CGFloat(height) * 0.08))))
        let left = Int(floor(bounds.minX * CGFloat(width))) - padding
        let right = Int(ceil(bounds.maxX * CGFloat(width))) + padding
        let top = Int(floor((1 - bounds.maxY) * CGFloat(height))) - padding
        let bottom = Int(ceil((1 - bounds.minY) * CGFloat(height))) + padding
        guard left >= 1, top >= 1, right < width, bottom < height else { return reject("clipped-row") }
        let area = (right - left) * (bottom - top)
        guard area > 0, area <= 2_000_000 else { return reject("row-size-limit") }
        func value(_ x: Int, _ y: Int) -> UInt8 { image.gray[y * width + x] }
        var borderMinimum: UInt8 = 255, borderMaximum: UInt8 = 0
        for x in left..<right {
            for y in [top, bottom - 1] {
                borderMinimum = min(borderMinimum, value(x, y)); borderMaximum = max(borderMaximum, value(x, y))
            }
        }
        for y in top..<bottom {
            for x in [left, right - 1] {
                borderMinimum = min(borderMinimum, value(x, y)); borderMaximum = max(borderMaximum, value(x, y))
            }
        }
        guard borderMinimum >= 235, Int(borderMaximum) - Int(borderMinimum) <= 15 else { return reject("non-light-or-clipped-border") }
        var components: [Component] = []
        var dark = 0, middle = 0, light = 0
        for x in left..<right {
            var first = bottom, last = -1
            for y in top..<bottom {
                let pixel = value(x, y)
                if pixel <= 100 { first = min(first, y); last = max(last, y); dark += 1 }
                else if pixel >= 220 { light += 1 }
                else { middle += 1 }
            }
            if last >= 0 {
                if let index = components.indices.last, components[index].right + 1 == x {
                    components[index].right = x
                    components[index].top = min(components[index].top, first)
                    components[index].bottom = max(components[index].bottom, last)
                } else { components.append(Component(left: x, top: first, right: x, bottom: last)) }
            }
        }
        guard dark >= 20, light * 10 >= area * 6, middle * 100 <= area * 15 else { return reject("insufficient-contrast") }
        // No merging, guessed splits, noise deletion or invented glyph boxes.
        guard components.count == characters.count else { return reject("component-count-\(components.count)-expected-\(characters.count)") }
        let digits = zip(characters, components).filter { $0.0 != "." }.map { $0.1 }
        let heights = digits.map(\.height).sorted()
        let reference = Double(heights[heights.count / 2])
        let baseline = digits.map(\.bottom).max()!
        guard reference >= 8 else { return reject("glyphs-too-small") }
        for (character, component) in zip(characters, components) {
            let w = Double(component.width), h = Double(component.height)
            guard Double(abs(component.bottom - baseline)) <= max(2, reference * 0.15) else { return reject("inconsistent-baseline") }
            if character == "." {
                guard h <= reference * 0.3, w <= reference * 0.3,
                      w >= h * 0.5, w <= h * 2 else { return reject("not-period-shaped") }
            } else {
                guard h >= reference * 0.8, h <= reference * 1.2,
                      w >= reference * 0.15, w <= reference * 1.1 else { return reject("inconsistent-digit-shape") }
            }
        }
        let glyphs = zip(characters, components).map { character, component in
            OCRGlyph(character: character, bounds: CGRect(
                x: CGFloat(component.left) / CGFloat(width),
                y: CGFloat(height - component.bottom - 1) / CGFloat(height),
                width: CGFloat(component.width) / CGFloat(width), height: CGFloat(component.height) / CGFloat(height)))
        }
        return Evidence(glyphs: glyphs, reason: "measured-raster-components")
    }
}
