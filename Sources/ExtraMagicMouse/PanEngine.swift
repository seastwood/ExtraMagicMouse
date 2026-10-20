import CMultitouch
import Foundation

/// Turns raw Magic Mouse touch frames into held direction keys.
///
/// Frames arrive on a MultitouchSupport thread, scroll events on the main
/// thread and the watchdog on its own queue, so all state sits behind `lock`.
final class PanEngine {
    static let shared = PanEngine()

    /// Keys are released if no touch frame arrives for this long (device
    /// asleep, disconnected, or the framework stopped reporting).
    private static let frameTimeout = 0.25
    /// Smoothing factor for drag-mode velocity (0...1, higher = snappier).
    private static let velocitySmoothing: CGFloat = 0.35
    /// Drag mode measures speed, not distance, so its threshold is scaled up.
    private static let dragThresholdScale: CGFloat = 4
    /// A held key is released at this fraction of the press threshold, so it
    /// doesn't flicker when your finger sits right on the edge.
    private static let releaseHysteresis: CGFloat = 0.7

    private let lock = NSLock()
    private let output = KeyOutput()
    private var settings = EngineSettings()
    private var appAllowed = false

    private var engaged = false
    private var origin = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastTimestamp = 0.0
    private var velocity = CGVector.zero
    private var held: Direction = []
    private var lastFrameUptime = 0.0
    private var lastEngagedUptime = -Double.infinity

    func update(settings newSettings: EngineSettings, appAllowed allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if newSettings != settings || allowed != appAllowed {
            // Release with the old key set before switching, so a change from
            // arrows to WASD can't strand a key.
            endGestureLocked()
        }
        settings = newSettings
        appAllowed = allowed
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        endGestureLocked()
    }

    func handleFrame(_ touches: UnsafePointer<MTTouch>?, count: Int, timestamp: Double) {
        lock.lock(); defer { lock.unlock() }
        lastFrameUptime = uptime()
        guard settings.enabled, appAllowed, let touches else {
            endGestureLocked()
            return
        }

        var sumX: CGFloat = 0, sumY: CGFloat = 0, fingers = 0
        for i in 0..<count {
            let touch = touches[i]
            guard touch.state == 4 || touch.state == 5 else { continue }
            sumX += CGFloat(touch.normalized.position.x)
            sumY += CGFloat(touch.normalized.position.y)
            fingers += 1
        }
        guard fingers == settings.fingers else {
            endGestureLocked()
            return
        }

        let point = CGPoint(x: sumX / CGFloat(fingers), y: sumY / CGFloat(fingers))
        if !engaged {
            engaged = true
            origin = point
            lastPoint = point
            lastTimestamp = timestamp
            velocity = .zero
        }
        lastEngagedUptime = uptime()

        let vector: CGVector
        var threshold = CGFloat(settings.deadzone)
        switch settings.mode {
        case .joystick:
            vector = CGVector(dx: point.x - origin.x, dy: point.y - origin.y)
        case .drag:
            let dt = CGFloat(timestamp - lastTimestamp)
            if dt > 0 {
                let a = Self.velocitySmoothing
                velocity.dx += a * ((point.x - lastPoint.x) / dt - velocity.dx)
                velocity.dy += a * ((point.y - lastPoint.y) / dt - velocity.dy)
            }
            lastPoint = point
            lastTimestamp = timestamp
            vector = velocity
            threshold *= Self.dragThresholdScale
        }
        setHeldLocked(directions(for: vector, threshold: threshold))
    }

    /// Called every ~50 ms so a vanished device can never leave a key held.
    func watchdog() {
        lock.lock(); defer { lock.unlock() }
        if (engaged || !held.isEmpty) && uptime() - lastFrameUptime > Self.frameTimeout {
            endGestureLocked()
        }
    }

    /// Whether a continuous (touch-surface) scroll event should be swallowed,
    /// so the game doesn't also zoom or scroll while you pan.
    func shouldBlockScroll(momentum: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard settings.blockScroll, settings.enabled, appAllowed else { return false }
        if engaged { return true }
        let since = uptime() - lastEngagedUptime
        return momentum ? since < 3 : since < 0.3
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
        setHeldLocked([])
    }

    private func setHeldLocked(_ directions: Direction) {
        guard directions != held else { return }
        held = directions
        output.apply(directions, keys: settings.keys)
    }

    private func uptime() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

/// C callback handed to MultitouchSupport; it can't capture, so it goes
/// through the shared engine.
let multitouchCallback: MTContactCallbackFunction = { _, touches, count, timestamp, _ in
    PanEngine.shared.handleFrame(touches, count: Int(count), timestamp: timestamp)
    return 0
}
