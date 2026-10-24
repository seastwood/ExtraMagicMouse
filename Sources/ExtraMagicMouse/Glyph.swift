import AppKit

/// The menu bar icon: a Magic Mouse seen from above, with four arrows around a
/// touch point on its upper half (the app icon's mark, simplified to read at 18pt).
/// While off it's the bare outline.
enum Glyph {
    static let mouseSize = NSSize(width: 12, height: 16)
    static let outlineWidth: CGFloat = 1.3
    /// The arrows' centre, from the top of the 18pt canvas.
    static let arrowCentreFromTop: CGFloat = 7.6
    /// Centre to each triangle's tip, the triangle's depth and its base.
    static let arrowReach: CGFloat = 4.1
    static let arrowDepth: CGFloat = 2.2
    static let arrowBase: CGFloat = 3.4
    static let touchRadius: CGFloat = 1.0

    /// Template image; macOS tints it for light and dark menu bars.
    static func menuBarImage(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            draw(in: rect, arrows: active)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "Extra Magic Mouse" : "Extra Magic Mouse (off)"
        return image
    }

    private static func draw(in rect: NSRect, arrows: Bool) {
        let body = NSRect(x: rect.midX - mouseSize.width / 2, y: rect.midY - mouseSize.height / 2,
                          width: mouseSize.width, height: mouseSize.height)
            .insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2)
        let outline = NSBezierPath(roundedRect: body, xRadius: body.width / 2, yRadius: body.width / 2)
        outline.lineWidth = outlineWidth
        outline.stroke()
        guard arrows else { return }

        let centre = NSPoint(x: rect.midX, y: rect.maxY - arrowCentreFromTop)
        for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (-1.0, 0.0), (1.0, 0.0)] as [(CGFloat, CGFloat)] {
            let tip = NSPoint(x: centre.x + dx * arrowReach, y: centre.y + dy * arrowReach)
            let base = NSPoint(x: tip.x - dx * arrowDepth, y: tip.y - dy * arrowDepth)
            let (px, py) = (-dy * arrowBase / 2, dx * arrowBase / 2)  // along the base
            let triangle = NSBezierPath()
            triangle.move(to: tip)
            triangle.line(to: NSPoint(x: base.x + px, y: base.y + py))
            triangle.line(to: NSPoint(x: base.x - px, y: base.y - py))
            triangle.close()
            triangle.fill()
        }
        NSBezierPath(ovalIn: NSRect(x: centre.x - touchRadius, y: centre.y - touchRadius,
                                    width: touchRadius * 2, height: touchRadius * 2)).fill()
    }
}
