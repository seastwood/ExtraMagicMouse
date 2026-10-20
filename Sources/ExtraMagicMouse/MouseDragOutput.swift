import CoreGraphics

/// Pans by holding the middle mouse button and moving the pointer, the way
/// many games let you grab and drag the map.
final class MouseDragOutput {
    /// When the pointer gets this close to the screen edge it hops back to
    /// where the pan started and grabs again, so long pans never run out of room.
    private static let edgeMargin: CGFloat = 40

    private(set) var isDown = false
    private var start = CGPoint.zero
    private var location = CGPoint.zero
    private var bounds = CGRect.zero
    private var remainder = CGVector.zero

    func begin() {
        guard !isDown else { return }
        start = CGEvent(source: nil)?.location ?? .zero
        bounds = Self.displayBounds(containing: start).insetBy(dx: Self.edgeMargin, dy: Self.edgeMargin)
        if !bounds.contains(start) {
            start = CGPoint(x: min(max(start.x, bounds.minX), bounds.maxX),
                            y: min(max(start.y, bounds.minY), bounds.maxY))
            post(.mouseMoved, at: start)
        }
        location = start
        remainder = .zero
        post(.otherMouseDown, at: start)
        isDown = true
    }

    /// Moves the held pointer by `delta` screen points (y grows downward).
    func move(by delta: CGVector) {
        guard isDown else { return }
        remainder.dx += delta.dx
        remainder.dy += delta.dy
        let dx = remainder.dx.rounded(.towardZero)
        let dy = remainder.dy.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return }
        remainder.dx -= dx
        remainder.dy -= dy

        var next = CGPoint(x: location.x + dx, y: location.y + dy)
        if !bounds.contains(next) {
            post(.otherMouseUp, at: location)
            post(.mouseMoved, at: start)
            post(.otherMouseDown, at: start)
            next = CGPoint(x: start.x + dx, y: start.y + dy)
        }
        post(.otherMouseDragged, at: next, dx: dx, dy: dy)
        location = next
    }

    /// Lets go and puts the pointer back where the pan began.
    func end() {
        guard isDown else { return }
        post(.otherMouseUp, at: location)
        post(.mouseMoved, at: start)
        isDown = false
    }

    private func post(_ type: CGEventType, at point: CGPoint, dx: CGFloat = 0, dy: CGFloat = 0) {
        let button: CGMouseButton = type == .mouseMoved ? .left : .center
        guard let event = CGEvent(mouseEventSource: KeyOutput.source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button)
        else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 {
            return CGDisplayBounds(display)
        }
        return CGDisplayBounds(CGMainDisplayID())
    }
}
