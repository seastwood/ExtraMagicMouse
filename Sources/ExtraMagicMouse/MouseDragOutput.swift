import CoreGraphics

/// Pans by holding the middle or right mouse button and moving the pointer, the
/// way many games let you grab and drag the map.
final class MouseDragOutput {
    /// When the pointer gets this close to the screen edge it hops back to
    /// where the pan started and grabs again, so long pans never run out of room.
    private static let edgeMargin: CGFloat = 40

    private(set) var isDown = false
    /// The button held for this pan; fixed from begin() to end() so a settings
    /// change mid-pan still releases the button that was pressed.
    private var button = CGMouseButton.center
    private var start = CGPoint.zero
    private var location = CGPoint.zero
    private var bounds = CGRect.zero
    private var remainder = CGVector.zero

    func begin(button: CGMouseButton) {
        guard !isDown else { return }
        self.button = button
        start = CGEvent(source: nil)?.location ?? .zero
        bounds = Self.displayBounds(containing: start).insetBy(dx: Self.edgeMargin, dy: Self.edgeMargin)
        if !bounds.contains(start) {
            start = CGPoint(x: min(max(start.x, bounds.minX), bounds.maxX),
                            y: min(max(start.y, bounds.minY), bounds.maxY))
            post(.mouseMoved, at: start)
        }
        location = start
        remainder = .zero
        post(down, at: start)
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
            post(up, at: location)
            post(.mouseMoved, at: start)
            post(down, at: start)
            next = CGPoint(x: start.x + dx, y: start.y + dy)
        }
        post(dragged, at: next, dx: dx, dy: dy)
        location = next
    }

    /// Puts the held pointer `offset` screen points from where the pan began
    /// (y grows downward), kept on screen. Unlike move(by:) it never lets go
    /// and grabs again at the edge, since that would reset the game's anchor.
    func hold(at offset: CGVector) {
        guard isDown else { return }
        let next = CGPoint(x: min(max((start.x + offset.dx).rounded(), bounds.minX), bounds.maxX),
                           y: min(max((start.y + offset.dy).rounded(), bounds.minY), bounds.maxY))
        guard next != location else { return }
        post(dragged, at: next, dx: next.x - location.x, dy: next.y - location.y)
        location = next
    }

    /// Lets go and puts the pointer back where the pan began.
    func end() {
        guard isDown else { return }
        post(up, at: location)
        post(.mouseMoved, at: start)
        isDown = false
    }

    private var down: CGEventType { button == .right ? .rightMouseDown : .otherMouseDown }
    private var dragged: CGEventType { button == .right ? .rightMouseDragged : .otherMouseDragged }
    private var up: CGEventType { button == .right ? .rightMouseUp : .otherMouseUp }

    private func post(_ type: CGEventType, at point: CGPoint, dx: CGFloat = 0, dy: CGFloat = 0) {
        let button: CGMouseButton = type == .mouseMoved ? .left : self.button
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
