import CMultitouch
import CoreGraphics
import Foundation

/// Turns raw Magic Mouse touch frames into panning (held keys or a middle-mouse
/// drag) and gesture actions.
///
/// Frames arrive on a MultitouchSupport thread, scroll and click events on the
/// main thread and the watchdog on its own queue, so all state sits behind `lock`.
final class PanEngine {
    static let shared = PanEngine()

    /// Panning stops if no touch frame arrives for this long (device asleep,
    /// disconnected, or the framework stopped reporting).
    private static let frameTimeout = 0.25
    /// Smoothing factor for drag-mode velocity (0...1, higher = snappier).
    private static let velocitySmoothing: CGFloat = 0.35
    /// Drag mode measures speed, not distance, so its threshold is scaled up.
    private static let dragThresholdScale: CGFloat = 4
    /// A held key is released at this fraction of the press threshold, so it
    /// doesn't flicker when your finger sits right on the edge.
    private static let releaseHysteresis: CGFloat = 0.7
    /// Pushing past this multiple of the threshold also holds the fast-pan key.
    private static let fastPanScale: CGFloat = 3
    /// Middle-mouse drag mode: pointer points per full sweep of the mouse surface.
    private static let dragPointsPerSurface: CGFloat = 1500
    /// Middle-mouse joystick mode: pointer points per second per surface-width of push.
    private static let joystickPointsPerSecond: CGFloat = 6000
    /// Right-mouse panning: how far the pointer sits from where the button went
    /// down, in points per surface-width of push past the dead zone.
    private static let anchorPointsPerSurface: CGFloat = 800
    /// Right-mouse panning presses the button only once the pointer would move
    /// this far, so a short push never reaches the game as a right click.
    private static let anchorPressDistance: CGFloat = 6
    /// A Dock gesture this soon after the Magic Mouse was last touched is taken
    /// to come from the mouse; otherwise it came from the trackpad.
    private static let mouseGestureWindow = 0.5

    private let lock = NSLock()
    private let keys = KeyOutput()
    private let mouse = MouseDragOutput()
    private var gestures = GestureDetector()
    private var settings = EngineSettings()
    private var appAllowed = false

    private var engaged = false
    private var origin = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastTimestamp = 0.0
    private var velocity = CGVector.zero
    private var held: Direction = []
    private var fast = false
    private var lastFrameUptime = 0.0
    private var lastEngagedUptime = -Double.infinity
    private var lastMouseTouchUptime = -Double.infinity

    func update(settings newSettings: EngineSettings, appAllowed allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if newSettings != settings || allowed != appAllowed {
            // Let go of everything before switching, so a change of keys or
            // games can't strand a held key or mouse button.
            endGestureLocked()
            gestures.reset()
        }
        settings = newSettings
        appAllowed = allowed
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        endGestureLocked()
        gestures.reset()
    }

    /// A physical left or right click (from the event tap).
    func noteButtonPress() {
        lock.lock(); defer { lock.unlock() }
        gestures.noteButtonPress()
    }

    func handleFrame(_ touches: UnsafePointer<MTTouch>?, count: Int, timestamp: Double, builtIn: Bool) {
        lock.lock(); defer { lock.unlock() }
        lastFrameUptime = uptime()
        if !builtIn && count > 0 { lastMouseTouchUptime = lastFrameUptime }
        guard settings.enabled, appAllowed else {
            endGestureLocked()
            gestures.reset()
            return
        }

        var contacts: [GestureDetector.Contact] = []
        if let touches {
            for i in 0..<count {
                let touch = touches[i]
                guard touch.state == 4 || touch.state == 5 else { continue }
                contacts.append(.init(id: touch.identifier,
                                      point: CGPoint(x: CGFloat(touch.normalized.position.x),
                                                     y: CGFloat(touch.normalized.position.y))))
            }
        }

        let pinchEnabled = settings.action(.pinchIn).kind != .none || settings.action(.pinchOut).kind != .none
        for slot in gestures.process(contacts, time: timestamp, pinchEnabled: pinchEnabled) {
            ActionOutput.perform(settings.action(slot))
        }
        // A pinch owns the touch until the fingers change, so it doesn't also pan.
        guard !gestures.isPinching, contacts.count == settings.fingers else {
            endGestureLocked()
            return
        }

        let n = CGFloat(contacts.count)
        let point = CGPoint(x: contacts.reduce(0) { $0 + $1.point.x } / n,
                            y: contacts.reduce(0) { $0 + $1.point.y } / n)
        if !engaged {
            engaged = true
            origin = point
            lastPoint = point
            lastTimestamp = timestamp
            velocity = .zero
        }
        lastEngagedUptime = uptime()

        let dt = CGFloat(min(max(timestamp - lastTimestamp, 0), 0.05))
        let step = CGVector(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
        if dt > 0 {
            let a = Self.velocitySmoothing
            velocity.dx += a * (step.dx / dt - velocity.dx)
            velocity.dy += a * (step.dy / dt - velocity.dy)
        }
        lastPoint = point
        lastTimestamp = timestamp
        let offset = CGVector(dx: point.x - origin.x, dy: point.y - origin.y)
        let threshold = CGFloat(settings.deadzone)

        if let button = settings.keys.dragButton {
            panMouseLocked(button: button, offset: offset, step: step, dt: dt, threshold: threshold)
        } else {
            let vector = settings.mode == .joystick ? offset : velocity
            let limit = settings.mode == .joystick ? threshold : threshold * Self.dragThresholdScale
            let isFast = max(abs(vector.dx), abs(vector.dy)) > limit * Self.fastPanScale
            setHeldLocked(directions(for: vector, threshold: limit), fast: isFast)
        }
    }

    /// Called every ~50 ms so a vanished device can never leave anything held.
    func watchdog() {
        lock.lock(); defer { lock.unlock() }
        if (engaged || !held.isEmpty || mouse.isDown) && uptime() - lastFrameUptime > Self.frameTimeout {
            endGestureLocked()
            gestures.reset()
        }
    }

    /// Whether a continuous (touch-surface) scroll event should be swallowed,
    /// so the game doesn't also zoom or scroll while you pan or pinch.
    func shouldBlockScroll(momentum: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard settings.blockScroll, settings.enabled, appAllowed else { return false }
        if engaged || gestures.isPinching { return true }
        let since = uptime() - lastEngagedUptime
        return momentum ? since < 3 : since < 0.3
    }

    /// Whether the Dock's gesture events (Mission Control and friends) should
    /// be dropped, so a two-finger double-tap stays in the game. Only gestures
    /// made on the Magic Mouse are dropped; trackpad swipes still reach the Dock.
    func shouldBlockDockGestures() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard settings.blockMissionControl && settings.enabled && appAllowed else { return false }
        return uptime() - lastMouseTouchUptime < Self.mouseGestureWindow
    }

    private func panMouseLocked(button: CGMouseButton, offset: CGVector, step: CGVector, dt: CGFloat, threshold: CGFloat) {
        if button == .right {
            anchorPanLocked(offset: offset, threshold: threshold)
            return
        }
        let speed = CGFloat(settings.mousePanSpeed)
        var move: CGVector
        switch settings.mode {
        case .joystick:
            // Like an analog stick: past the dead zone, the further you push the faster it pans.
            func axis(_ v: CGFloat) -> CGFloat { abs(v) <= threshold ? 0 : v - (v > 0 ? threshold : -threshold) }
            let scale = Self.joystickPointsPerSecond * speed * dt
            move = CGVector(dx: axis(offset.dx) * scale, dy: axis(offset.dy) * scale)
        case .drag:
            // Don't grab the map for the tiny wobble of a tap.
            if !mouse.isDown && hypot(offset.dx, offset.dy) < threshold / 2 { return }
            let scale = Self.dragPointsPerSurface * speed
            move = CGVector(dx: step.dx * scale, dy: step.dy * scale)
        }
        if settings.invertX { move.dx = -move.dx }
        if settings.invertY { move.dy = -move.dy }
        guard move.dx != 0 || move.dy != 0 else { return }
        mouse.begin(button: button)
        // Touch y grows away from you; screen y grows downward.
        mouse.move(by: CGVector(dx: move.dx, dy: -move.dy))
    }

    /// Games like C&C Generals scroll while the right button is held, toward the
    /// pointer and faster the further it is from where the button went down. So
    /// the pointer mirrors the push instead of travelling: hold a push and it
    /// stays put, and the map keeps scrolling at that speed. Same in both modes.
    private func anchorPanLocked(offset: CGVector, threshold: CGFloat) {
        let distance = hypot(offset.dx, offset.dy)
        let past = distance <= threshold ? 0 : (distance - threshold) / distance
        let scale = Self.anchorPointsPerSurface * CGFloat(settings.mousePanSpeed) * past
        var target = CGVector(dx: offset.dx * scale, dy: offset.dy * scale)
        if settings.invertX { target.dx = -target.dx }
        if settings.invertY { target.dy = -target.dy }
        if !mouse.isDown && hypot(target.dx, target.dy) < Self.anchorPressDistance { return }
        mouse.begin(button: .right)
        // Touch y grows away from you; screen y grows downward.
        mouse.hold(at: CGVector(dx: target.dx, dy: -target.dy))
    }

    private func directions(for v: CGVector, threshold: CGFloat) -> Direction {
        let dx = settings.invertX ? -v.dx : v.dx
        let dy = settings.invertY ? -v.dy : v.dy
        func limit(_ d: Direction) -> CGFloat {
            held.contains(d) ? threshold * Self.releaseHysteresis : threshold
        }
        var result: Direction = []
        if dx > limit(.right) { result.insert(.right) } else if dx < -limit(.left) { result.insert(.left) }
        if dy > limit(.up) { result.insert(.up) } else if dy < -limit(.down) { result.insert(.down) }
        return result
    }

    private func endGestureLocked() {
        if engaged {
            engaged = false
            lastEngagedUptime = uptime()
        }
        setHeldLocked([], fast: false)
        mouse.end()
    }

    private func setHeldLocked(_ directions: Direction, fast wantFast: Bool) {
        let isFast = wantFast && !directions.isEmpty
        guard directions != held || isFast != fast else { return }
        held = directions
        fast = isFast
        var codes = Set(settings.keys.codes.filter { directions.contains($0.0) }.map { $0.1 })
        let fastAction = settings.action(.fastPan)
        if isFast && fastAction.kind == .key { codes.insert(CGKeyCode(fastAction.keyCode)) }
        keys.hold(codes)
    }

    private func uptime() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

/// C callback handed to MultitouchSupport; it can't capture, so it goes
/// through the shared engine.
let multitouchCallback: MTContactCallbackFunction = { device, touches, count, timestamp, _ in
    PanEngine.shared.handleFrame(touches, count: Int(count), timestamp: timestamp,
                                 builtIn: EMMMultitouchDeviceIsBuiltIn(device))
    return 0
}
