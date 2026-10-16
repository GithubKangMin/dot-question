import AppKit

/// Template images drawn by this app. No Wi-Fi or battery system state is accessed.
enum AnswerStatusIcon {
    static func wifi(bars: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 18), flipped: false) { _ in
            for index in 0..<5 {
                let height = CGFloat(4 + index * 3)
                let rect = NSRect(x: CGFloat(index * 5), y: 1, width: 3, height: height)
                let path = NSBezierPath(roundedRect: rect, xRadius: 0.6, yRadius: 0.6)
                NSColor.black.withAlphaComponent(index < bars ? 1 : 0.22).setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func battery(percent: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 27, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 22, height: 12), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.2; outline.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: 7, width: 2, height: 4), xRadius: 0.5, yRadius: 0.5).fill()
            let width = CGFloat(max(0, min(100, percent))) / 100 * 18
            if width > 0 {
                NSBezierPath(rect: NSRect(x: 3, y: 5, width: width, height: 8)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
