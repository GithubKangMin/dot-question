import AppKit

/// Original, locally drawn fan-art shapes. No downloaded artwork or system icons.
enum CharacterStatusIcon {
    enum Style: Int { case off = 0, cat, pikachu }

    static func image(style: Style, active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 34, height: 22), flipped: false) { _ in
            func polygon(_ points: [NSPoint], color: NSColor) {
                let path = NSBezierPath()
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
                path.close(); color.setFill(); path.fill()
            }
            func oval(_ rect: NSRect, color: NSColor) {
                color.setFill(); NSBezierPath(ovalIn: rect).fill()
            }
            if style == .cat {
                NSColor.labelColor.setStroke()
                let tail = NSBezierPath()
                tail.move(to: NSPoint(x: 23, y: 5))
                tail.curve(to: NSPoint(x: active ? 31 : 28, y: active ? 19 : 9),
                           controlPoint1: NSPoint(x: 31, y: 2),
                           controlPoint2: NSPoint(x: active ? 25 : 34, y: 15))
                tail.lineWidth = 2.4; tail.lineCapStyle = .round; tail.stroke()
                oval(NSRect(x: 8, y: 2, width: 17, height: 13), color: .labelColor)
                polygon([NSPoint(x: 7, y: 13), NSPoint(x: 7, y: 21), NSPoint(x: 14, y: 17),
                         NSPoint(x: 19, y: 17), NSPoint(x: 24, y: 21), NSPoint(x: 24, y: 12)], color: .labelColor)
                oval(NSRect(x: 10, y: 10, width: 2, height: 2), color: .windowBackgroundColor)
                oval(NSRect(x: 19, y: 10, width: 2, height: 2), color: .windowBackgroundColor)
            } else if style == .pikachu {
                let yellow = NSColor(calibratedRed: 1, green: 0.79, blue: 0.08, alpha: 1)
                polygon([NSPoint(x: 8, y: 12), NSPoint(x: 5, y: 22), NSPoint(x: 11, y: 20), NSPoint(x: 14, y: 12)], color: yellow)
                polygon([NSPoint(x: 19, y: 12), NSPoint(x: 24, y: 22), NSPoint(x: 27, y: 20), NSPoint(x: 25, y: 11)], color: yellow)
                polygon([NSPoint(x: 5, y: 22), NSPoint(x: 11, y: 20), NSPoint(x: 9, y: 17)], color: .black)
                polygon([NSPoint(x: 24, y: 22), NSPoint(x: 27, y: 20), NSPoint(x: 25, y: 17)], color: .black)
                oval(NSRect(x: 7, y: 2, width: 20, height: 15), color: yellow)
                oval(NSRect(x: 11, y: 10, width: 2.3, height: 2.3), color: .black)
                oval(NSRect(x: 21, y: 10, width: 2.3, height: 2.3), color: .black)
                oval(NSRect(x: 8, y: 6, width: 4, height: 3), color: .systemRed)
                oval(NSRect(x: 23, y: 6, width: 4, height: 3), color: .systemRed)
                polygon([NSPoint(x: 16, y: 7), NSPoint(x: 18, y: 7), NSPoint(x: 17, y: 5)], color: .black)
                if active {
                    for x in [CGFloat(0), CGFloat(29)] {
                        polygon([NSPoint(x: x + 3, y: 17), NSPoint(x: x, y: 10),
                                 NSPoint(x: x + 3, y: 10), NSPoint(x: x + 1, y: 4),
                                 NSPoint(x: x + 5, y: 12), NSPoint(x: x + 2, y: 12)], color: yellow)
                    }
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
